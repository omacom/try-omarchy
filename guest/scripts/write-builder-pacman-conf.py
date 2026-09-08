#!/usr/bin/env python3
"""Derive the disposable factory builder pacman.conf from the guest config.

Guest IgnorePkg holds (kernel / Hyprland / aquamarine) stay in the reviewed
guest file. The builder config must:
  - expose ABI pins rebuilt from reviewed upstream source + Arch PKGBUILD
  - omit those pin names from IgnorePkg so pacstrap can install them once
  - keep optional signed packageCachePins ahead of rolling mirrors

[try-omarchy-abi-pins] is unsigned because repo-add writes an unsigned database
for the just-built package. Origin is the reproducible rebuild, not TrustAll.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path


SECTION_RE = re.compile(r"^\[([A-Za-z0-9@._+-]+)\]$")


def fail(message: str) -> None:
    raise SystemExit(f"write-builder-pacman-conf: {message}")


def load_abi_pins(spec: dict, lock_packages: dict[str, str]) -> list[dict]:
    pins = spec.get("inputs", {}).get("abiPackagePins", [])
    if not isinstance(pins, list):
        fail("inputs.abiPackagePins must be a list")
    names = [pin.get("name") for pin in pins]
    if names != sorted(set(names)):
        fail("abiPackagePins names must be sorted and unique")
    supply = spec.get("supplyChain", {})
    resolved = []
    for pin in pins:
        if not isinstance(pin, dict):
            fail("abiPackagePins entries must be objects")
        required = {"name", "version"}
        if set(pin) != required:
            fail(f"abiPackagePins entry keys must be exactly {sorted(required)}")
        name = pin["name"]
        version = pin["version"]
        if not re.fullmatch(r"[a-z0-9@._+-]+", name or ""):
            fail(f"invalid abi package name: {name}")
        if not re.fullmatch(r"[A-Za-z0-9_.+:~-]+", version or ""):
            fail(f"invalid abi package version: {version}")
        if name not in {"aquamarine", "hyprtoolkit"}:
            fail(f"unsupported abi pin: {name}")
        component = supply.get(name)
        if not isinstance(component, dict):
            fail(f"abi pin {name} is missing supplyChain.{name}")
        expected = f"{component.get('version')}-{component.get('pkgrel')}"
        if version != expected:
            fail(f"abi pin {name} version {version} does not match supply chain {expected}")
        locked = lock_packages.get(name)
        if locked != version:
            fail(f"abi package {name} version {version} does not match lock {locked}")
        resolved.append(pin)
    return resolved


def ensure_abi_repo(pins: list[dict], repo_dir: Path) -> None:
    if not pins:
        return
    if not repo_dir.is_dir():
        fail(f"abi pin repository is missing: {repo_dir}")
    archives = []
    for pin in pins:
        matches = sorted(repo_dir.glob(f"{pin['name']}-{pin['version']}-*.pkg.tar.zst"))
        matches = [path for path in matches if path.is_file() and not path.is_symlink()]
        if len(matches) != 1:
            fail(f"expected exactly one rebuilt archive for {pin['name']}={pin['version']}")
        archives.append(matches[0])
    database = repo_dir / "try-omarchy-abi-pins.db.tar.gz"
    if database.exists():
        return
    subprocess.run(
        ["repo-add", str(database), *map(str, archives)],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def strip_ignore_pkg(line: str, drop: set[str]) -> str | None:
    if not line.startswith("IgnorePkg"):
        return line
    _, _, value = line.partition("=")
    packages = [pkg for pkg in value.split() if pkg not in drop]
    if not packages:
        return None
    return "IgnorePkg = " + " ".join(packages)


def write_builder_config(
    *,
    guest_config: Path,
    output: Path,
    package_cache: Path | None,
    disable_sandbox: bool,
    abi_repo: Path | None,
    pinned_cache_repo: Path | None,
    drop_ignore: set[str],
) -> None:
    lines = guest_config.read_text().splitlines()
    options_sections = 0
    abi_inserted = pinned_inserted = False
    out: list[str] = []

    for line in lines:
        section = SECTION_RE.fullmatch(line)
        if section and section.group(1) != "options":
            if abi_repo is not None and not abi_inserted:
                out.extend(
                    [
                        "[try-omarchy-abi-pins]",
                        "SigLevel = Optional TrustAll",
                        f"Server = file://{abi_repo}",
                        "",
                    ]
                )
                abi_inserted = True
            if pinned_cache_repo is not None and not pinned_inserted:
                out.extend(
                    [
                        "[try-omarchy-pinned-cache]",
                        "SigLevel = Required DatabaseOptional",
                        f"Server = file://{pinned_cache_repo}",
                        "",
                    ]
                )
                pinned_inserted = True

        rewritten = strip_ignore_pkg(line, drop_ignore)
        if rewritten is None:
            continue
        out.append(rewritten)

        if line == "[options]":
            options_sections += 1
            if package_cache is not None:
                out.append(f"CacheDir = {package_cache}")
            if disable_sandbox:
                out.append("DisableSandbox")

    if options_sections != 1:
        fail("guest pacman configuration must contain one [options] section")
    if abi_repo is not None and not abi_inserted:
        fail("guest pacman configuration has no repository section for abi pins")
    if pinned_cache_repo is not None and not pinned_inserted:
        fail("guest pacman configuration has no repository section for cache pins")

    output.write_text("\n".join(out).rstrip() + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", required=True, type=Path)
    parser.add_argument("--guest-dir", required=True, type=Path)
    parser.add_argument("--guest-config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--package-lock", required=True, type=Path)
    parser.add_argument("--abi-repo", type=Path)
    parser.add_argument("--pinned-cache-repo", type=Path)
    parser.add_argument("--package-cache", type=Path)
    parser.add_argument("--disable-sandbox", action="store_true")
    args = parser.parse_args()

    spec = json.loads(args.spec.read_text())
    lock_packages = json.loads(args.package_lock.read_text())["packages"]
    pins = load_abi_pins(spec, lock_packages)

    abi_repo = args.abi_repo
    if pins:
        if abi_repo is None:
            fail("--abi-repo is required when abiPackagePins are declared")
        ensure_abi_repo(pins, abi_repo)
    elif abi_repo is not None:
        fail("--abi-repo was provided without abiPackagePins")

    write_builder_config(
        guest_config=args.guest_config,
        output=args.output,
        package_cache=args.package_cache,
        disable_sandbox=args.disable_sandbox,
        abi_repo=abi_repo if pins else None,
        pinned_cache_repo=args.pinned_cache_repo,
        drop_ignore={pin["name"] for pin in pins},
    )


if __name__ == "__main__":
    main()
