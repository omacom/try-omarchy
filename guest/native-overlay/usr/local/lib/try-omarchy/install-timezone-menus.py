#!/usr/bin/python3 -I
"""Install the reviewed timezone hooks on matching older guest commands only."""

import hashlib
import json
import os
from pathlib import Path
import tempfile


def install(root, hooks):
    for hook in hooks:
        relative = hook["path"]
        if relative not in ("usr/bin/omarchy-provision-owner", "usr/bin/omarchy-menu-timezone"):
            raise ValueError("unexpected timezone hook target")
        target = root / relative
        if target.is_symlink() or not target.is_file():
            continue
        source = target.read_bytes()
        digest = hashlib.sha256(source).hexdigest()
        if digest == hook["afterSha256"]:
            continue
        if digest != hook["beforeSha256"]:
            print(f"Keeping unrecognized {relative}; timezone menu hook not installed.", flush=True)
            continue
        result = source.decode()
        for before, after in hook["replacements"]:
            if result.count(before) != 1:
                raise ValueError("timezone hook preimage mismatch")
            result = result.replace(before, after)
        data = result.encode()
        if hashlib.sha256(data).hexdigest() != hook["afterSha256"]:
            raise ValueError("timezone hook postimage mismatch")
        descriptor, temporary = tempfile.mkstemp(prefix=".timezone-", dir=target.parent)
        try:
            with os.fdopen(descriptor, "wb") as output:
                output.write(data)
                os.fchmod(output.fileno(), target.stat().st_mode & 0o777)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


if __name__ == "__main__":
    hooks = json.loads(Path("/usr/local/share/try-omarchy/timezone-menu-hooks.json").read_text())
    install(Path("/"), hooks)
