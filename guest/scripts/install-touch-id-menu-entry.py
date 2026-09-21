#!/usr/bin/env python3
"""Install the Try Omarchy Touch ID row into one user's menu extension."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import secrets
import stat


ENTRY_ID = '"setup.security.touch-id"'
ENTRY = (
    '  // Try Omarchy host integration.\n'
    '  "setup.security.touch-id": {"icon":"󰈷","label":"Touch ID for sudo",'
    '"when":"[[ -x /usr/local/bin/try-omarchy-touch-id ]]",'
    '"checked":"/usr/local/bin/try-omarchy-touch-id status --quiet",'
    '"action":"omarchy-launch-floating-terminal-with-presentation '
    '/usr/local/bin/try-omarchy-touch-id"},\n'
)
MAXIMUM_BYTES = 256 * 1024


def fail(message: str) -> None:
    raise SystemExit(f"install-touch-id-menu-entry: {message}")


def install(path: Path, previous_entry: str | None = None) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        info = path.stat(follow_symlinks=False)
    except FileNotFoundError:
        data = b"{\n}\n"
        mode = 0o644
    else:
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            fail("menu extension is not a safe user-owned regular file")
        mode = stat.S_IMODE(info.st_mode)
        data = path.read_bytes()
        if len(data) > MAXIMUM_BYTES:
            fail("menu extension is unexpectedly large")

    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        fail("menu extension is not UTF-8")
    if ENTRY_ID in text and (previous_entry is None or text.count(previous_entry) != 1):
        return

    opening = text.find("{")
    if opening < 0 or text[:opening].strip():
        fail("menu extension does not start with a JSONC object")
    if text.rstrip()[-1:] != "}":
        fail("menu extension is not a JSONC object")
    if ENTRY_ID in text:
        updated = text.replace(previous_entry, ENTRY, 1)
    else:
        updated = text[: opening + 1] + "\n" + ENTRY + text[opening + 1 :]

    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    temporary = f".{path.name}.{secrets.token_hex(8)}"
    descriptor = -1
    try:
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            mode,
            dir_fd=directory,
        )
        payload = updated.encode("utf-8")
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                fail("menu extension stopped accepting data")
            offset += written
        os.fchmod(descriptor, mode)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(temporary, path.name, src_dir_fd=directory, dst_dir_fd=directory)
        os.fsync(directory)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass
        os.close(directory)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    if not args.path.is_absolute():
        fail("menu extension path must be absolute")
    install(args.path)


if __name__ == "__main__":
    main()
