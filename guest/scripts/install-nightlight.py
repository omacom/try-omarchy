#!/usr/bin/env python3
"""Preview or install the pinned night-light fix in an existing guest."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile


GUEST = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("/"), help=argparse.SUPPRESS)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    if args.apply and root == Path("/") and os.geteuid() != 0:
        parser.error("installation requires root")

    spec = json.loads((GUEST / "spec.json").read_text())
    backport = next(item for item in spec["authenticity"]["backports"] if item["id"] == "virgl-nightlight")
    targets = {
        "bin/omarchy-toggle-nightlight": "usr/bin/omarchy-toggle-nightlight",
        "shell/plugins/services/nightlight/Service.qml": "usr/share/omarchy/shell/plugins/services/nightlight/Service.qml",
    }
    assets = ["usr/local/bin/omarchy-native-nightlight", "usr/local/share/try-omarchy/nightlight.frag"]

    # Refuse unknown versions and user edits before writing any installed file.
    states = []
    for item in backport["targets"]:
        relative = targets[item["path"]]
        path = root / relative
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
            parser.error(f"missing or unsafe installed target: {relative}")
        actual = digest(path)
        if actual not in (item["beforeSha256"], item["afterSha256"]):
            parser.error(f"unsupported version or local changes: {relative}")
        states.append(actual == item["afterSha256"])
    if any(states) and not all(states):
        parser.error("partially installed backport; restore its backup before retrying")
    for relative in assets:
        path = root / relative
        if not path.resolve().is_relative_to(root) or path.is_symlink():
            parser.error(f"unsafe installed asset: {relative}")
        if path.exists() and (not path.is_file() or digest(path) != digest(GUEST / "native-overlay" / relative)):
            parser.error(f"local changes in night-light asset: {relative}")

    with tempfile.TemporaryDirectory(prefix="try-omarchy-nightlight-") as temporary:
        stage = Path(temporary)
        omarchy = stage / "usr/share/omarchy"
        for source, destination in targets.items():
            path = omarchy / source
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / destination, path)
        if not all(states):
            module_spec = importlib.util.spec_from_file_location("backports", GUEST / "scripts/apply-omarchy-backports.py")
            module = importlib.util.module_from_spec(module_spec)
            module_spec.loader.exec_module(module)
            module.apply_backport(GUEST, stage, omarchy, backport)
        prepared = {destination: omarchy / source for source, destination in targets.items()}
        prepared.update({relative: GUEST / "native-overlay" / relative for relative in assets})
        changes = {relative: source for relative, source in prepared.items()
                   if not (root / relative).exists() or digest(root / relative) != digest(source)}
        if not changes:
            print("Night-light integration is already installed.")
            return
        print("Files to install:\n" + "\n".join(changes))
        if not args.apply:
            print("Preview only. Run with --apply to install.")
            return

        backup_parent = root / "var/lib/try-omarchy"
        backup_parent.mkdir(parents=True, exist_ok=True)
        backup = Path(tempfile.mkdtemp(prefix="nightlight-backup.", dir=backup_parent))
        created = []
        for relative in changes:
            destination = root / relative
            if destination.exists():
                saved = backup / relative
                saved.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(destination, saved)
            else:
                created.append(relative)
        (backup / "created-files.json").write_text(json.dumps(created, indent=2) + "\n")
        changed = []
        try:
            for relative, source in changes.items():
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                # Replace complete files; never expose a half-written command/QML.
                with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
                    staging_file = Path(output.name)
                try:
                    shutil.copy2(source, staging_file)
                    staging_file.replace(destination)
                finally:
                    staging_file.unlink(missing_ok=True)
                changed.append(relative)
        except BaseException:
            for relative in reversed(changed):
                if relative in created:
                    (root / relative).unlink()
                else:
                    shutil.copy2(backup / relative, root / relative)
            raise
        print(f"Installed. Backup: {backup}")
        print("As your desktop user, run: omarchy restart shell")


if __name__ == "__main__":
    main()
