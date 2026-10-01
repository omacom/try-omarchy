#!/usr/bin/env python3
"""Consent-gated, recoverable file fixes; no packages, PAM, or service changes."""

import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

FILES = {
    "omarchy-native-clipboard-bridge": "usr/local/bin/omarchy-native-clipboard-bridge",
    "omarchy-screensaver": "usr/bin/omarchy-screensaver",
    "omarchy-native-screensaver-text": "usr/local/bin/omarchy-native-screensaver-text",
    "omarchy-native-cursor-restore": "usr/local/bin/omarchy-native-cursor-restore",
}
PREVIOUS = {
    "omarchy-native-clipboard-bridge": "03e3c6cf56f04c98434c32c7a4dd45a5ef1ab6dbcb4a76afbd186085c1d37bd5",
    "omarchy-screensaver": "34c480f6eaabef574b700aa7b023b2048eaf4400cfdf6e04227e642c02191ed2",
}
INVENTORY = {*FILES, "migrate.py", "try-omarchy-migrate-alacritty"}
STATE = "var/lib/try-omarchy/boot-fixes"
WRAPPER = "usr/local/bin/alacritty"
BACKUP = "usr/local/bin/.alacritty.try-omarchy-software-backup"
TARGETS = {*FILES.values(), WRAPPER, BACKUP}
COMPONENTS = ("clipboard", "screensaver", "alacritty")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def bundle_manifest(payload, create=False):
    files = {name: digest((payload / name).read_bytes()) for name in sorted(INVENTORY)}
    value = {"schema": 1, "files": files,
             "identity": digest(json.dumps(files, sort_keys=True).encode())}
    if create:
        (payload / "fixes.json").write_text(json.dumps(value, sort_keys=True) + "\n")
    elif json.loads((payload / "fixes.json").read_text()) != value:
        raise RuntimeError("Boot fix payload verification failed")
    return value


def protected(path, root, uid):
    """Reject symlinked, shared, or untrusted destinations, including parents."""
    for entry in (path, *path.parents):
        if entry == root.parent:
            break
        if entry.is_symlink():
            raise RuntimeError("Unsafe boot fix destination")
        if entry.exists():
            info = entry.stat()
            if info.st_uid != uid or info.st_mode & 0o022:
                raise RuntimeError("Unprotected boot fix destination")
            if entry != path and not stat.S_ISDIR(info.st_mode):
                raise RuntimeError("Invalid boot fix directory")


def snapshot(path, root, uid):
    protected(path, root, uid)
    if not path.exists():
        return None
    info = path.stat()
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 262144
            or info.st_mode & 0o7000):
        raise RuntimeError("Unsupported boot fix file")
    return {"data": base64.b64encode(path.read_bytes()).decode(),
            "mode": stat.S_IMODE(info.st_mode), "uid": info.st_uid, "gid": info.st_gid}


def replacement(data, uid, gid):
    return {"data": base64.b64encode(data).decode(), "mode": 0o755, "uid": uid, "gid": gid}


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def make_directory(path, mode):
    missing = []
    current = path
    while not current.exists():
        missing.append(current)
        current = current.parent
    for directory in reversed(missing):
        directory.mkdir(mode=mode if directory == path else 0o755)
        sync_directory(directory)
        sync_directory(directory.parent)


def write_file(path, value, root, uid):
    protected(path, root, uid)
    if value is None:
        path.unlink(missing_ok=True)
    else:
        make_directory(path.parent, 0o755)
        fd, temporary = tempfile.mkstemp(prefix=".try-omarchy-fix-", dir=path.parent)
        try:
            with os.fdopen(fd, "wb") as output:
                output.write(base64.b64decode(value["data"], validate=True))
                os.fchown(output.fileno(), value["uid"], value["gid"])
                os.fchmod(output.fileno(), value["mode"])
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    if path.parent.exists():
        sync_directory(path.parent)


def journal_path(root, uid):
    path = root / STATE / "journal.json"
    protected(path, root, uid)
    make_directory(path.parent, 0o700)
    return path


def recover(root, uid, fallback=None):
    path = journal_path(root, uid)
    if not path.exists():
        if fallback is None:
            return
        changes = fallback
    else:
        if path.stat().st_size > 2097152:
            raise RuntimeError("Oversized boot fix journal")
        if not path.is_file() or path.stat().st_nlink != 1:
            raise RuntimeError("Unsafe boot fix journal")
        changes = json.loads(path.read_text())
    if (not isinstance(changes, list) or len(changes) > len(TARGETS)
            or any(not isinstance(c, dict) or set(c) != {"path", "before", "after"}
                   or c["path"] not in TARGETS for c in changes)
            or len({c["path"] for c in changes}) != len(changes)):
        raise RuntimeError("Invalid boot fix journal")
    for change in changes:
        for value in (change["before"], change["after"]):
            if value is None:
                continue
            if (not isinstance(value, dict) or set(value) != {"data", "mode", "uid", "gid"}
                    or value["uid"] != uid or not isinstance(value["gid"], int) or value["gid"] < 0
                    or not isinstance(value["mode"], int) or not 0 <= value["mode"] <= 0o777
                    or value["mode"] & 0o022 or not isinstance(value["data"], str)
                    or len(base64.b64decode(value["data"], validate=True)) > 262144):
                raise RuntimeError("Invalid boot fix backup")
    # Preflight every path before restoring any. Never overwrite later edits.
    for change in changes:
        current = snapshot(root / change["path"], root, uid)
        if current not in (change["before"], change["after"]):
            raise RuntimeError("Boot fix recovery conflicts with a changed file")
    for change in reversed(changes):
        write_file(root / change["path"], change["before"], root, uid)
        if snapshot(root / change["path"], root, uid) != change["before"]:
            raise RuntimeError("Boot fix recovery verification failed")
    write_file(path, None, root, uid)


def plan(payload, root, uid, cmdline):
    changes = []
    outcomes = {}
    for component, names in (("clipboard", ["omarchy-native-clipboard-bridge"]),
                              ("screensaver", ["omarchy-native-screensaver-text",
                                               "omarchy-native-cursor-restore", "omarchy-screensaver"])):
        caller = root / FILES[names[-1]]
        if not caller.exists() and not caller.is_symlink():
            outcomes[component] = "current"
            continue
        group = []
        try:
            for name in names:
                before = snapshot(root / FILES[name], root, uid)
                source = (payload / name).read_bytes()
                if before is not None:
                    content = base64.b64decode(before["data"])
                    if content != source and digest(content) != PREVIOUS.get(name):
                        raise RuntimeError("Customized native helper")
                after = replacement(source, uid, before["gid"] if before else os.getgid())
                if before != after:
                    group.append({"path": FILES[name], "before": before, "after": after})
            changes.extend(group)
            outcomes[component] = "pending" if group else "current"
        except (OSError, RuntimeError):
            outcomes[component] = "preserved"

    # The extensionless helper needs an explicit loader.
    from importlib.machinery import SourceFileLoader
    spec = importlib.util.spec_from_loader("alacritty_fix", SourceFileLoader("alacritty_fix", str(payload / "try-omarchy-migrate-alacritty")))
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    try:
        before = snapshot(root / WRAPPER, root, uid)
        if before is None:
            outcomes["alacritty"] = "current"
        elif digest(base64.b64decode(before["data"])) != helper.WRAPPER_SHA256:
            outcomes["alacritty"] = "preserved"
        elif os.access(root / "usr/bin/alacritty", os.X_OK) and helper.MARKER not in cmdline.split():
            outcomes["alacritty"] = "unavailable"
        elif (root / BACKUP).exists() or (root / BACKUP).is_symlink():
            outcomes["alacritty"] = "preserved"
        else:
            protected(root / BACKUP, root, uid)
            changes.extend([{"path": BACKUP, "before": None, "after": before},
                            {"path": WRAPPER, "before": before, "after": None}])
            outcomes["alacritty"] = "pending"
    except (OSError, RuntimeError):
        outcomes["alacritty"] = "preserved"
    return changes, outcomes


def migrate(payload, root, approved, cmdline, emit=lambda _: None, uid=None):
    uid = os.getuid() if uid is None else uid
    identity = bundle_manifest(payload)["identity"]
    def report(state, outcomes):
        value = {"schema": 1, "type": "boot-fixes", "identity": identity,
                 "state": state, "components": outcomes}
        emit(value)
        return value
    try:
        recover(root, uid)
    except (OSError, RuntimeError, ValueError, KeyError):
        return report("recovery-required", dict.fromkeys(COMPONENTS, "pending"))
    changes, outcomes = plan(payload, root, uid, cmdline)
    if not changes:
        return report("complete", outcomes)
    if not approved:
        return report("skipped", outcomes)
    report("running", outcomes)
    path = journal_path(root, uid)
    try:
        # Persist all original bytes/metadata before touching any managed file.
        data = json.dumps(changes, sort_keys=True).encode()
        write_file(path, {"data": base64.b64encode(data).decode(), "mode": 0o600,
                          "uid": uid, "gid": os.getgid()}, root, uid)
        for change in changes:
            target = root / change["path"]
            if snapshot(target, root, uid) != change["before"]:
                raise RuntimeError("Boot fix file changed after review")
            write_file(target, change["after"], root, uid)
        for change in changes:
            if snapshot(root / change["path"], root, uid) != change["after"]:
                raise RuntimeError("Boot fix verification failed")
        # Keep a root-private copy for inspection/manual recovery after success.
        fd, backup = tempfile.mkstemp(prefix="backup-", suffix=".json", dir=path.parent)
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        # Unlinking the journal is the durable commit. Before it, recovery
        # restores the entire file group, including when consent was skipped.
        write_file(path, None, root, uid)
    except (OSError, RuntimeError, ValueError):
        try:
            # If the commit unlink succeeded but its directory flush failed,
            # the originals are still available in memory and retained backup.
            recover(root, uid, fallback=changes)
        except (OSError, RuntimeError, ValueError, KeyError):
            return report("recovery-required", outcomes)
        return report("failed", outcomes)
    return report("complete", {k: "applied" if v == "pending" else v for k, v in outcomes.items()})


def boot(payload):
    def emit(value):
        print("Try Omarchy boot fixes: " + json.dumps(value), flush=True)
        try:
            fd = os.open("/dev/virtio-ports/dev.tryomarchy.settings", os.O_WRONLY | os.O_NONBLOCK)
            try:
                os.write(fd, json.dumps(value, separators=(",", ":")).encode() + b"\n")
            finally:
                os.close(fd)
        except OSError:
            pass  # A missing host listener never grants consent or changes success.
    try:
        cmdline = Path("/proc/cmdline").read_text()
        identity = bundle_manifest(payload)["identity"]
        approved = f"tryomarchy.fixes={identity}" in cmdline.split()
        return migrate(payload, Path("/"), approved, cmdline, emit, uid=0)
    except (OSError, RuntimeError, ValueError):
        print("Try Omarchy boot fixes could not be checked; no update was authorized", flush=True)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--manifest":
        bundle_manifest(Path(sys.argv[2]), create=True)
    else:
        raise SystemExit("This runner is invoked by the app's boot settings payload")
