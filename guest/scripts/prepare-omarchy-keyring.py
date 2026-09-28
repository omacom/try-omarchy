#!/usr/bin/env python3
"""Retain the reviewed bootstrap keyring package in the local guest repository."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def prepare(guest, destination):
    pin = json.loads((guest / "spec.json").read_text())["supplyChain"]["omarchyKeyring"]
    if pin["filename"] != f"omarchy-keyring-{pin['version']}-any.pkg.tar.zst" or "/" in pin["filename"]:
        raise ValueError("invalid Omarchy keyring package filename")
    if pin["url"] != "https://pkgs.omarchy.org/aarch64/" + pin["filename"]:
        raise ValueError("unexpected Omarchy keyring package source")
    destination.mkdir(parents=True, exist_ok=True)
    output = destination / pin["filename"]
    with tempfile.TemporaryDirectory() as temporary:
        archive = Path(temporary) / pin["filename"]
        subprocess.run(["curl", "--fail", "--silent", "--show-error", "--location",
                        "--max-time", "60", pin["url"], "--output", str(archive)], check=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != pin["sha256"]:
            raise ValueError("Omarchy keyring package checksum mismatch")
        metadata = subprocess.check_output(["tar", "-xOf", str(archive), ".PKGINFO"]).decode()
        for field in ("pkgname = omarchy-keyring", f"pkgver = {pin['version']}", "arch = any"):
            if field not in metadata.splitlines():
                raise ValueError("Omarchy keyring package identity mismatch")
        for name in ("omarchy.gpg", "omarchy-trusted", "omarchy-revoked"):
            contents = subprocess.check_output(["tar", "-xOf", str(archive),
                                                f"usr/share/pacman/keyrings/{name}"])
            if contents != (guest / "keys" / name).read_bytes():
                raise ValueError(f"Omarchy keyring differs from reviewed key material: {name}")
        output.write_bytes(archive.read_bytes())
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--guest-dir", type=Path, required=True)
    parser.add_argument("--output-repo", type=Path, required=True)
    args = parser.parse_args()
    print(prepare(args.guest_dir, args.output_repo))


if __name__ == "__main__":
    main()
