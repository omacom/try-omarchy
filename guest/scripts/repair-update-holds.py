#!/usr/bin/env python3
"""Repair package holds in an existing Try Omarchy guest without upgrading it."""

import argparse
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import tempfile


HOLDS = ("linux-aarch64", "linux-aarch64-headers", "hyprland", "aquamarine", "hyprtoolkit")
CONFIGS = ("usr/share/try-omarchy/pacman.conf", "etc/pacman.conf")


def add_holds(text):
    lines = text.splitlines(keepends=True)
    section = None
    options = []
    directives = []
    present = set()
    for index, line in enumerate(lines):
        content = line.split("#", 1)[0].strip()
        if content.startswith("[") and content.endswith("]"):
            section = content[1:-1]
            if section == "options":
                options.append(index)
        elif section == "options" and re.match(r"IgnorePkg\s*=", content):
            directives.append(index)
            present.update(content.split("=", 1)[1].split())
    if len(options) != 1:
        raise ValueError("expected exactly one [options] section")
    missing = [name for name in HOLDS if name not in present]
    if not missing:
        return text
    if directives:
        index = directives[0]
        line = lines[index]
        body = line.rstrip("\r\n")
        ending = line[len(body):]
        value, marker, comment = body.partition("#")
        lines[index] = value.rstrip() + " " + " ".join(missing)
        if marker:
            lines[index] += " " + marker + comment
        lines[index] += ending
    else:
        index = options[0]
        ending = "\r\n" if lines[index].endswith("\r\n") else "\n"
        if not lines[index].endswith("\n"):
            lines[index] += ending
        lines.insert(index + 1, "IgnorePkg = " + " ".join(missing) + ending)
    return "".join(lines)


def replace_file(path, content):
    info = path.stat()
    fd, name = tempfile.mkstemp(prefix=".try-omarchy-holds-", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
            if os.geteuid() == 0:
                os.fchown(stream.fileno(), info.st_uid, info.st_gid)
            os.fchmod(stream.fileno(), stat.S_IMODE(info.st_mode))
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def repair(root, apply=False):
    plans = []
    for relative in CONFIGS:
        path = root / relative
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"missing or symlinked configuration: /{relative}")
        before = path.read_bytes()
        after = add_holds(before.decode("utf-8")).encode("utf-8")
        plans.append((path, before, after))
        print(f"/{relative}: {'already correct' if before == after else 'add missing compatibility holds'}")
    changes = [plan for plan in plans if plan[1] != plan[2]]
    if not changes:
        print("Both configurations already contain the required holds; nothing changed.")
        return
    if not apply:
        print("Required holds: " + " ".join(HOLDS))
        print("Preview only. Run with sudo and --apply to save both configurations.")
        return

    # Cooperate with pacman so a package transaction cannot overlap the repair.
    lock = root / "var/lib/pacman/db.lck"
    fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    try:
        for path, before, _ in plans:
            if path.read_bytes() != before:
                raise ValueError("configuration changed during repair; retry when the updater is closed")
        backup_root = root / "var/lib/try-omarchy"
        backup_root.mkdir(parents=True, exist_ok=True)
        backup = Path(tempfile.mkdtemp(prefix="update-holds-backup.", dir=backup_root))
        for path, _, _ in plans:
            destination = backup / path.relative_to(root)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)
        print(f"Previous configurations retained in {backup}")
        written = []
        try:
            for path, before, after in changes:
                replace_file(path, after)
                written.append((path, before))
        except OSError:
            for path, before in reversed(written):
                replace_file(path, before)
            raise
        print("Guest update holds repaired. Retry Omarchy Update.")
    finally:
        lock.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="back up and update both configurations")
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() != "aarch64":
        parser.error("run this command inside the Try Omarchy ARM guest")
    if "omarchy.qemu_virgl=1" not in Path("/proc/cmdline").read_text().split():
        parser.error("this guest does not have the Try Omarchy boot marker")
    if args.apply and os.geteuid() != 0:
        parser.error("--apply requires sudo")
    try:
        repair(Path("/"), args.apply)
    except (OSError, ValueError) as error:
        parser.exit(1, f"repair-update-holds: {error}\nNo packages were installed or upgraded. Close the updater before retrying; do not remove an active pacman lock.\n")


if __name__ == "__main__":
    main()
