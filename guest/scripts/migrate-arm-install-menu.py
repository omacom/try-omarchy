#!/usr/bin/env python3
"""Preview or explicitly apply the ARM Install-menu repair to an existing guest."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("/"))
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    guest = Path(__file__).resolve().parents[1]
    menu = root / "usr/share/omarchy/default/omarchy/omarchy-menu.jsonc"
    if menu.is_symlink() or not menu.is_file():
        parser.error("expected a regular Omarchy menu file")
    before = menu.read_bytes()
    text = before.decode()
    old_line = next((line for line in text.splitlines() if '"install.service.bitwarden"' in line), None)
    if old_line is None:
        parser.error("Bitwarden menu entry is missing")
    entry = json.loads("{" + old_line.strip().rstrip(",") + "}")
    entry["install.service.bitwarden"]["when"] = "! omarchy-pkg-present bitwarden && ! omarchy-pkg-present bitwarden-bin"
    entry["install.service.bitwarden"]["action"] = "omarchy-launch-floating-terminal-with-presentation omarchy-install-service-bitwarden"
    new_line = "  " + json.dumps(entry, ensure_ascii=False, separators=(",", ":"))[1:-1] + ","
    after = text.replace(old_line, new_line).encode()
    spec = json.loads((guest / "spec.json").read_text())
    backport = next(b for b in spec["authenticity"]["backports"] if b["id"] == "vivaldi-menu-entries")
    known = {backport["targets"][0]["beforeSha256"], backport["targets"][0]["afterSha256"],
             "78d817a76be7ce7d204e15c2617df72f897efe90e22f9af4e255bdf17fbfbedb"}
    known.add("65ebf3b389ae09b53b40754b840b6fa29cd9d845f56249fa83840e1bcd164a5c")
    if digest(before) not in known:
        parser.error("menu has unrecognized changes; existing files have been kept")
    changes = [(menu, after, 0o644)]
    for relative in ("usr/local/bin/omarchy-install-service-bitwarden",
                     "usr/local/share/try-omarchy/aarch64-unavailable-packages"):
        source = guest / "native-overlay" / relative
        destination = root / relative
        if destination.is_symlink():
            parser.error(f"refusing symlink: {destination}")
        data = source.read_bytes()
        if destination.exists() and destination.read_bytes() != data:
            if relative.endswith("aarch64-unavailable-packages"):
                existing = destination.read_text()
                entries = dict(line.split("\t") for line in existing.splitlines()
                               if line and not line.startswith("#"))
                additions = []
                for package, name in (("hermes-desktop", "Hermes Desktop"), ("ollama", "Ollama"),
                                      ("ollama-cuda", "Ollama"), ("ollama-rocm", "Ollama"),
                                      ("t3code-bin", "T3 Code")):
                    if package in entries and entries[package] != name:
                        parser.error(f"unrecognized refusal entry: {package}")
                    if package not in entries:
                        additions.append(f"{package}\t{name}\n")
                data = (existing.rstrip("\n") + "\n" + "".join(additions)).encode()
            else:
                parser.error(f"unrecognized existing file: {destination}")
        changes.append((destination, data, source.stat().st_mode & 0o777))
    for command in ("omarchy-pkg-add", "omarchy-pkg-aur-add"):
        path = root / "usr/bin" / command
        if not path.is_file() or b"omarchy-pkg-refuse-aarch64-unavailable" not in path.read_bytes():
            parser.error(f"{command} lacks the existing ARM refusal integration")
    changes = [(p, d, m) for p, d, m in changes if not p.exists() or p.read_bytes() != d]
    for path, _, _ in changes:
        print(f"{path}: update")
    if not changes:
        print("ARM Install-menu repair is already applied.")
        return
    if not args.apply:
        print("Preview only. Re-run with --apply to update these files.")
        return
    if root == Path("/") and os.geteuid() != 0:
        parser.error("--apply requires root")
    backup_parent = root / "var/lib/try-omarchy"
    backup_parent.mkdir(parents=True, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix="arm-install-menu-backup.", dir=backup_parent))
    for path, _, _ in changes:
        if path.exists():
            saved = backup / path.relative_to(root)
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, saved)
    for path, data, mode in changes:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".arm-install-menu-")
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, path)
    print(f"Previous files retained in {backup}")
    print("Close and reopen the Omarchy menu to use the repaired install actions.")


if __name__ == "__main__":
    main()
