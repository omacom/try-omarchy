#!/usr/bin/env python3
"""Expose signed cached packages at their reviewed lock versions to the builder."""

import argparse
import json
import os
from pathlib import Path
import subprocess


def reviewed_packages(packages, build_packages):
    result = dict(packages)
    for name, version in build_packages.items():
        if name in result and result[name] != version:
            raise ValueError(f"conflicting factory and build package pins: {name}")
        result[name] = version
    return result


def select_archives(cache, packages, required):
    selected = []
    for name, version in sorted(packages.items()):
        matches = []
        for spelling in {version, version.split(":", 1)[-1]}:
            for architecture in ("aarch64", "any"):
                for compression in ("xz", "zst"):
                    archive = cache / f"{name}-{spelling}-{architecture}.pkg.tar.{compression}"
                    signature = Path(str(archive) + ".sig")
                    if archive.is_file() and signature.is_file():
                        if archive.is_symlink() or signature.is_symlink():
                            raise ValueError(f"symlinked cached package: {name}")
                        matches.append(archive)
        if len(matches) > 1:
            raise ValueError(f"ambiguous cached package: {name}")
        if matches:
            selected.append((name, version, matches[0]))
        elif name in required:
            raise ValueError(f"required signed cache pin is missing: {name}={version}")
    return selected


def prepare(cache, destination, packages, required):
    archives = select_archives(cache, packages, required)
    for name, version, archive in archives:
        subprocess.run(["pacman-key", "--verify", str(archive) + ".sig", str(archive)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        metadata = subprocess.check_output(["bsdtar", "-xOf", str(archive), ".PKGINFO"], text=True)
        fields = metadata.splitlines()
        if (f"pkgname = {name}" not in fields or f"pkgver = {version}" not in fields
                or not ({"arch = aarch64", "arch = any"} & set(fields))):
            raise ValueError(f"cached archive does not match the lock identity: {name}")
        os.link(archive, destination / archive.name)
        os.link(str(archive) + ".sig", destination / (archive.name + ".sig"))
    if archives:
        subprocess.run(["repo-add", "--quiet", str(destination / "try-omarchy-pinned-cache.db.tar.gz"),
                        *[str(destination / archive.name) for _, _, archive in archives]], check=True)
    print(f"Prepared {len(archives)} verified locked packages from the builder cache")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output-repo", type=Path, required=True)
    args = parser.parse_args()
    spec = json.loads(args.spec.read_text())
    packages = json.loads(args.lock.read_text())["packages"]
    required = spec["inputs"].get("packageCachePins", [])
    if required != sorted(set(required)) or not set(required) <= packages.keys():
        parser.error("packageCachePins must be sorted unique names in the transaction lock")
    packages = reviewed_packages(packages, spec["supplyChain"]["hyprland"]["buildPackages"])
    prepare(args.cache, args.output_repo, packages, required)


if __name__ == "__main__":
    main()
