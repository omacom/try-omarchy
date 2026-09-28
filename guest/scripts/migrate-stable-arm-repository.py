#!/usr/bin/env python3
"""Preview or migrate an existing Try Omarchy guest to signed stable ARM packages."""

import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile

GUEST = Path(__file__).resolve().parents[1]
CONFIGS = ("usr/share/try-omarchy/pacman.conf", "etc/pacman.conf")
LEGACY = "https://pkgs.omarchy.org/$arch"
STABLE = "https://pkgs.omarchy.org/stable/$arch"
SIGNATURE_POLICY = "Required DatabaseOptional TrustedOnly"
REPO = "usr/share/try-omarchy/repo"
DATABASE = REPO + "/try-omarchy.db.tar.gz"
DENYLIST = "usr/local/share/try-omarchy/aarch64-unavailable-packages"


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), GUEST / "scripts" / f"{name}.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def regular(root, relative, optional=False):
    path = root / relative
    for parent in (path, *path.parents):
        if parent == root:
            break
        if parent.is_symlink():
            raise ValueError(f"symlinked migration path: {relative}")
    if not path.is_file() and not (optional and not path.exists()):
        raise ValueError(f"missing or non-regular migration file: {relative}")
    return path


def update_config(text):
    lines = text.splitlines(keepends=True)
    sections = []
    section = None
    servers = []
    signatures = []
    for index, line in enumerate(lines):
        content = line.split("#", 1)[0].strip()
        if content.startswith("[") and content.endswith("]"):
            section = content[1:-1]
            if section == "omarchy":
                sections.append(index)
        elif section == "omarchy" and "=" in content:
            key, value = map(str.strip, content.split("=", 1))
            if key == "Server":
                servers.append((index, value))
            elif key == "SigLevel":
                signatures.append(index)
            elif key in {"Include", "CacheServer", "Usage"}:
                raise ValueError(f"custom [omarchy] {key} requires manual review")
    if len(sections) != 1 or len(servers) != 1 or len(signatures) > 1:
        raise ValueError("expected one [omarchy] section with one Server and at most one SigLevel")
    server_index, url = servers[0]
    if url not in {LEGACY, STABLE}:
        raise ValueError("custom Omarchy repository/channel requires manual review")

    def replace(index, value):
        line = lines[index]
        body = line.rstrip("\r\n")
        ending = line[len(body):]
        indentation = re.match(r"\s*", body).group()
        _, marker, comment = body.partition("#")
        lines[index] = indentation + value + (" #" + comment if marker else "") + ending

    replace(server_index, "Server = " + STABLE)
    if signatures:
        replace(signatures[0], "SigLevel = " + SIGNATURE_POLICY)
    else:
        index = sections[0]
        ending = "\r\n" if lines[index].endswith("\r\n") else "\n"
        if not lines[index].endswith("\n"):
            lines[index] += ending
        lines.insert(index + 1, "SigLevel = " + SIGNATURE_POLICY + ending)
    return "".join(lines)


def plan(root):
    plans = []

    def add(relative, content, optional=False):
        path = regular(root, relative, optional)
        plans.append((path, path.read_bytes() if path.exists() else None, content))

    for relative in CONFIGS:
        path = regular(root, relative)
        add(relative, update_config(path.read_bytes().decode()).encode())
    path = regular(root, DENYLIST, optional=True)
    if path.exists():
        content = path.read_bytes().decode()
        add(DENYLIST, "".join(line for line in content.splitlines(keepends=True)
                               if line.split("\t", 1)[0] != "cursor-bin").encode())
    elif any(os.path.lexists(root / directory / "omarchy-pkg-refuse-aarch64-unavailable")
             for directory in ("usr/local/bin", "usr/bin")):
        raise ValueError("unavailable-app helper is installed but its package list is missing")
    spec = json.loads((GUEST / "spec.json").read_text())
    backport = next(item for item in spec["authenticity"]["backports"]
                    if item["id"] == "stable-arm-package-channel")
    applier = module("apply-omarchy-backports")
    with tempfile.TemporaryDirectory() as temporary:
        staged = Path(temporary)
        omarchy = staged / "usr/share/omarchy"
        pending = []
        for target in backport["targets"]:
            relative = "usr/" + target["path"]
            original = regular(root, relative)
            data = original.read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            if digest == target["afterSha256"]:
                add(relative, data)
                continue
            if digest != target["beforeSha256"]:
                raise ValueError(f"modified or unsupported Omarchy command: {relative}")
            destination = omarchy / target["path"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            pending.append(target)
        # The reviewed patch is one transaction; mixed old/new commands require review.
        if pending and len(pending) != len(backport["targets"]):
            raise ValueError("partially migrated channel commands require manual review")
        if pending:
            applier.apply_backport(GUEST, staged, omarchy, backport)
            for target in pending:
                add("usr/" + target["path"], (omarchy / target["path"]).read_bytes())
    return plans


def portable_database(data):
    # Older local databases carry filesystem-specific flags such as nocow.
    # repo-add extracts them on /tmp, which may not support those flags.
    output = io.BytesIO()
    with tarfile.open(fileobj=io.BytesIO(data)) as source, \
            tarfile.open(fileobj=output, mode="w:gz") as destination:
        for member in source:
            member.pax_headers.pop("SCHILY.fflags", None)
            destination.addfile(member, source.extractfile(member) if member.isfile() else None)
    return output.getvalue()


def verify_repository_records(before, after, version):
    def records(data):
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            return {member.name: archive.extractfile(member).read()
                    for member in archive if member.isfile()}

    original, updated = records(before), records(after)
    if any(updated.get(name) != content for name, content in original.items()
           if not name.startswith("omarchy-keyring-")):
        raise ValueError("local repository update changed or lost an existing package record")
    if f"omarchy-keyring-{version}/desc" not in updated:
        raise ValueError("local repository update omitted the reviewed keyring")


def keyring_plans(root):
    pin = json.loads((GUEST / "spec.json").read_text())["supplyChain"]["omarchyKeyring"]
    archive_path = regular(root, REPO + "/" + pin["filename"], optional=True)
    database = regular(root, DATABASE)
    sync = regular(root, "var/lib/pacman/sync/try-omarchy.db", optional=True)
    link = root / REPO / "try-omarchy.db"
    if not link.is_symlink() or os.readlink(link) != "try-omarchy.db.tar.gz":
        raise ValueError("unexpected local repository database link")
    # A prior successful migration needs no download or repository rewrite.
    if archive_path.exists() and hashlib.sha256(archive_path.read_bytes()).hexdigest() == pin["sha256"]:
        listing = subprocess.check_output(["tar", "-tf", str(database)], text=True)
        if f"omarchy-keyring-{pin['version']}/desc" in listing.splitlines():
            return []
    before = database.read_bytes()
    with tempfile.TemporaryDirectory() as temporary:
        staged = Path(temporary)
        archive = module("prepare-omarchy-keyring").prepare(GUEST, staged)
        staged_db = staged / "try-omarchy.db.tar.gz"
        staged_db.write_bytes(portable_database(before))
        subprocess.run(["repo-add", "--quiet", str(staged_db), str(archive)], check=True)
        verify_repository_records(before, staged_db.read_bytes(), pin["version"])
        return [(archive_path, archive_path.read_bytes() if archive_path.exists() else None, archive.read_bytes()),
                (database, before, staged_db.read_bytes()),
                (sync, sync.read_bytes() if sync.exists() else None, staged_db.read_bytes())]


def replace_file(path, content):
    info = path.stat() if path.exists() else None
    fd, name = tempfile.mkstemp(prefix=".stable-arm-", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), stat.S_IMODE(info.st_mode) if info else 0o644)
            if info and os.geteuid() == 0:
                os.fchown(stream.fileno(), info.st_uid, info.st_gid)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def apply_plans(root, plans):
    changes = [(path, before, after) for path, before, after in plans if before != after]
    if not changes:
        print("Already migrated; nothing changed.")
        return
    lock = root / "var/lib/pacman/db.lck"
    descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(descriptor)
    try:
        for path, before, _ in plans:
            regular(root, path.relative_to(root).as_posix(), optional=before is None)
            if (path.read_bytes() if path.exists() else None) != before:
                raise ValueError("migration input changed; close the updater and retry")
        store = root / "var/lib/try-omarchy"
        store.mkdir(parents=True, exist_ok=True)
        backup = Path(tempfile.mkdtemp(prefix="stable-arm-backup.", dir=store))
        manifest = []
        for path, before, _ in changes:
            relative = path.relative_to(root)
            manifest.append({"path": str(relative), "existed": before is not None})
            if before is not None:
                destination = backup / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, destination)
        (backup / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"Previous files retained in {backup}")
        written = []
        try:
            for path, before, after in changes:
                replace_file(path, after)
                written.append((path, before))
        except OSError:
            for path, before in reversed(written):
                if before is None:
                    path.unlink()
                else:
                    replace_file(path, before)
            raise
    finally:
        lock.unlink()


def migrate(root, apply=False):
    plans = plan(root)
    for path, before, after in plans:
        print(f"/{path.relative_to(root)}: {'unchanged' if before == after else 'update'}")
    if not apply:
        print("Apply also retains the reviewed keyring in the local repository. No packages are installed.")
        print("Preview only. Run with sudo and --apply to back up and migrate.")
        return
    plans.extend(keyring_plans(root))
    apply_plans(root, plans)
    print("Run Omarchy Update before installing apps, to refresh databases and update packages together.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() != "aarch64":
        parser.error("run inside the Try Omarchy ARM guest from the complete source checkout")
    if "omarchy.qemu_virgl=1" not in Path("/proc/cmdline").read_text().split():
        parser.error("this guest does not have the Try Omarchy boot marker")
    if args.apply and os.geteuid() != 0:
        parser.error("--apply requires sudo")
    try:
        if args.apply:
            pin = json.loads((GUEST / "spec.json").read_text())["supplyChain"]["omarchyKeyring"]
            installed = subprocess.check_output(["pacman", "-Q", "omarchy-keyring"], text=True).strip()
            if installed != "omarchy-keyring " + pin["version"]:
                raise ValueError("the installed keyring version requires manual review")
            subprocess.run(["pacman-key", "--list-keys", "40DFB630FF42BCFFB047046CF0134EE680CAC571"],
                           check=True, stdout=subprocess.DEVNULL)
        migrate(Path("/"), args.apply)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"stable-arm-migration: {error}\nNo package upgrade was requested.\n")


if __name__ == "__main__":
    main()
