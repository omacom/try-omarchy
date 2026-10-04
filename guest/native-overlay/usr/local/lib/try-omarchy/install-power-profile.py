#!/usr/bin/python3 -I
"""Apply reviewed macOS power and battery presentation to matching guests."""

import hashlib
import json
import os
from pathlib import Path
import tempfile


TARGETS = {
    "usr/bin/omarchy-powerprofiles-list",
    "usr/bin/omarchy-powerprofiles-set",
    "usr/share/omarchy/shell/plugins/panels/power/Panel.qml",
    "usr/share/omarchy/shell/plugins/panels/power/Model.js",
    "usr/share/omarchy/shell/plugins/menu/Menu.qml",
}


def install(root, hooks):
    for hook in hooks:
        relative = hook["path"]
        if relative not in TARGETS:
            raise ValueError("unexpected power profile target")
        target = root / relative
        if target.is_symlink() or not target.is_file():
            continue
        # Do not follow a parent symlink outside the guest root in staged installs.
        if not target.resolve().is_relative_to(root.resolve()):
            raise ValueError("power profile target escapes guest root")
        source = target.read_bytes()
        digest = hashlib.sha256(source).hexdigest()
        if digest == hook["afterSha256"]:
            continue
        version = next((candidate for candidate in [hook, *hook.get("previousVersions", [])]
                        if digest == candidate["beforeSha256"]), None)
        if version is None:
            print(f"Keeping unrecognized {relative}; power profile hook not installed.", flush=True)
            continue
        result = source.decode()
        for before, after in version["replacements"]:
            if result.count(before) != 1:
                raise ValueError("power profile preimage mismatch")
            result = result.replace(before, after)
        data = result.encode()
        if hashlib.sha256(data).hexdigest() != hook["afterSha256"]:
            raise ValueError("power profile postimage mismatch")
        descriptor, temporary = tempfile.mkstemp(prefix=".power-profile-", dir=target.parent)
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
    hooks = json.loads(Path("/usr/local/share/try-omarchy/power-profile-hooks.json").read_text())
    install(Path("/"), hooks)
