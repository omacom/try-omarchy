#!/usr/bin/env python3
"""Derive the disposable factory builder pacman.conf from the guest config.

Guest IgnorePkg holds apply to updates of an installed system. Omit them from
an empty-root factory transaction, whose versions are checked against the lock.
Keep optional signed packageCachePins ahead of rolling mirrors and use the
selected ARM mirror without changing the installed guest mirrors.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


SECTION_RE = re.compile(r"^\[([A-Za-z0-9@._+-]+)\]$")


def fail(message: str) -> None:
    raise SystemExit(f"write-builder-pacman-conf: {message}")


def write_builder_config(
    *,
    guest_config: Path,
    output: Path,
    package_cache: Path | None,
    disable_sandbox: bool,
    pinned_cache_repo: Path | None,
    repository_mirrors: list[str] | None = None,
) -> None:
    lines = guest_config.read_text().splitlines()
    options_sections = 0
    pinned_inserted = False
    out: list[str] = []
    repository = None

    for line in lines:
        section = SECTION_RE.fullmatch(line)
        if section:
            repository = section.group(1)
        # Local package repositories live in private build directories, so the
        # downloader must keep the invoking builder user's access to them.
        if repository_mirrors and line.startswith("DownloadUser"):
            continue
        if (
            repository_mirrors
            and repository in {"core", "extra", "alarm", "aur"}
            and line.startswith("Include =")
        ):
            out.extend(f"Server = {mirror}/$repo" for mirror in repository_mirrors)
            continue
        if section and section.group(1) != "options":
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

        if repository == "options" and re.match(r"^\s*IgnorePkg\s*=", line):
            continue
        out.append(line)

        if line == "[options]":
            options_sections += 1
            if package_cache is not None:
                out.append(f"CacheDir = {package_cache}")
            if disable_sandbox:
                out.append("DisableSandbox")

    if options_sections != 1:
        fail("guest pacman configuration must contain one [options] section")
    if pinned_cache_repo is not None and not pinned_inserted:
        fail("guest pacman configuration has no repository section for cache pins")

    output.write_text("\n".join(out).rstrip() + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", required=True, type=Path)
    parser.add_argument("--guest-config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pinned-cache-repo", type=Path)
    parser.add_argument("--package-cache", type=Path)
    parser.add_argument("--disable-sandbox", action="store_true")
    args = parser.parse_args()

    spec = json.loads(args.spec.read_text())
    repository_mirrors = spec.get("inputs", {}).get("packageRepositoryMirrors")
    if repository_mirrors is not None and (
        not isinstance(repository_mirrors, list)
        or not repository_mirrors
        or any(
            not isinstance(mirror, str)
            or not re.fullmatch(r"https://[a-z0-9.-]+/aarch64", mirror)
            for mirror in repository_mirrors
        )
    ):
        fail("packageRepositoryMirrors must contain HTTPS ARM mirror URLs")

    write_builder_config(
        guest_config=args.guest_config,
        output=args.output,
        package_cache=args.package_cache,
        disable_sandbox=args.disable_sandbox,
        pinned_cache_repo=args.pinned_cache_repo,
        repository_mirrors=repository_mirrors,
    )


if __name__ == "__main__":
    main()
