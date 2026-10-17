#!/usr/bin/env python3
"""Say whether Omarchy's edge repository moved since the factory was built.

The factory installs whatever Omarchy's edge repositories serve when it is
built and records the [omarchy] database it used (dist/guest/factory.json)
and every installed package (dist/guest/packages.txt). This downloads the
current [omarchy] database (about 50 KB), compares it with the recorded one,
and names the installed packages with newer versions upstream. It only
informs: a failed check or an outdated factory never fails the build.
`make refresh` rebuilds the factory from the latest upstream.

--check is the strict form `make release` uses to decide whether the cached
factory can ship: it compares every repository database the factory installed
from and the Node.js release it bundles, and exits 0 only when all of them
match what upstream serves now.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

DATABASE_URL = "https://pkgs.omarchy.org/edge/aarch64/omarchy.db"
# The repositories of build-image.sh, by name.
REPOSITORY_URLS = {
    "omarchy": DATABASE_URL,
    **{name: f"https://arm-mirror.omarchy.org/aarch64/{name}/{name}.db" for name in ("core", "extra", "alarm", "aur")},
}
NODE_INDEX_URL = "https://nodejs.org/dist/latest/SHASUMS256.txt"
# Shown first when they change: what a user notices.
KEY_PACKAGES = ("omarchy-dev", "omarchy-settings-dev", "linux-omarchy", "hyprland", "quickshell", "mesa")
STALE_AFTER_DAYS = 7


def age_text(seconds: float) -> str:
    minutes = int(seconds // 60)
    if minutes < 1:
        return "under a minute"
    if minutes < 60:
        return f"{minutes} min"
    hours, minutes = divmod(minutes, 60)
    if hours < 24:
        return f"{hours} h {minutes} min" if minutes else f"{hours} h"
    days, hours = divmod(hours, 24)
    return f"{days} d {hours} h" if hours else f"{days} d"


def read_versions(text: str) -> dict[str, str]:
    versions = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) == 2:
            versions[fields[0]] = fields[1]
    return versions


def database_versions(data: bytes) -> dict[str, str]:
    """name -> version from a pacman sync database (desc files in a tarball)."""
    entries: dict[str, str] = {}

    def add(desc: str) -> None:
        fields: dict[str, str] = {}
        key = None
        for line in desc.splitlines():
            if line.startswith("%") and line.endswith("%"):
                key = line.strip("%")
            elif key and line:
                fields.setdefault(key, line)
        if "NAME" in fields and "VERSION" in fields:
            entries[fields["NAME"]] = fields["VERSION"]

    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
            for member in archive:
                if member.isfile() and member.name.endswith("/desc"):
                    handle = archive.extractfile(member)
                    if handle:
                        add(handle.read().decode("utf-8", "replace"))
        return entries
    except (tarfile.TarError, OSError, EOFError):
        pass
    # Python without the archive's compression: the system tar reads it.
    with tempfile.TemporaryDirectory() as directory:
        database = Path(directory) / "omarchy.db"
        database.write_bytes(data)
        listing = subprocess.run(["tar", "-tf", str(database)], capture_output=True, text=True, check=True)
        for name in listing.stdout.splitlines():
            if name.endswith("/desc"):
                desc = subprocess.run(["tar", "-xOf", str(database), name], capture_output=True, check=True)
                add(desc.stdout.decode("utf-8", "replace"))
    return entries


def fetch(url: str, timeout: float) -> bytes:
    # pkgs.omarchy.org refuses Python's default user agent.
    request = urllib.request.Request(url, headers={"User-Agent": "try-omarchy-factory-freshness"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read(64 * 1024 * 1024)


def latest_node(index: str) -> tuple[str, str] | None:
    """(file, sha256) of the linux-arm64 tarball, as build-image.sh picks it."""
    for line in index.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[1].startswith("node-v") and fields[1].endswith("-linux-arm64.tar.gz"):
            return fields[1], fields[0]
    return None


def check(root: Path, urls: dict[str, str], node_index_url: str, timeout: float) -> list[str]:
    """Why the factory is not current with upstream; empty when it is."""
    try:
        factory = json.loads((root / "dist/guest/factory.json").read_text())
    except (OSError, ValueError):
        return ["no factory has been built"]
    recorded = factory.get("repositories") if isinstance(factory.get("repositories"), dict) else {}
    reasons = []
    for name, url in urls.items():
        if name not in recorded:
            reasons.append(f"the factory does not record the [{name}] database it was built from")
            continue
        try:
            current = hashlib.sha256(fetch(url, timeout)).hexdigest()
        except (OSError, ValueError) as error:
            reasons.append(f"could not check [{name}]: {error}")
            continue
        if current != recorded[name]:
            reasons.append(f"[{name}] changed since the factory was built")
    node = factory.get("node") if isinstance(factory.get("node"), dict) else {}
    try:
        latest = latest_node(fetch(node_index_url, timeout).decode("utf-8", "replace"))
    except (OSError, ValueError) as error:
        reasons.append(f"could not check the latest Node.js release: {error}")
    else:
        if latest is None:
            reasons.append("could not find the latest Node.js linux-arm64 release")
        elif latest != (node.get("file"), node.get("sha256")):
            reasons.append(f"Node.js {latest[0]} replaced {node.get('file', 'the bundled release')}")
    return reasons


def report(root: Path, url: str, now: datetime, timeout: float) -> list[str]:
    guest = root / "dist/guest"
    try:
        factory = json.loads((guest / "factory.json").read_text())
        built = datetime.strptime(factory["built"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (OSError, ValueError, KeyError, TypeError):
        return []  # no factory yet; the build reports that itself
    age = age_text((now - built).total_seconds())
    stale = (now - built).days >= STALE_AFTER_DAYS
    summary = f"Omarchy {factory.get('omarchy', '?')}, kernel {factory.get('kernel', '?')}"

    try:
        data = fetch(url, timeout)
    except (OSError, ValueError) as error:
        lines = [f"[factory] Built {age} ago ({summary}); could not check Omarchy edge: {error}"]
        if stale:
            lines.append("[factory] Run `make refresh` to build it from the latest Omarchy.")
        return lines

    if hashlib.sha256(data).hexdigest() == factory.get("omarchy_db_sha256"):
        return [f"[factory] Up to date with Omarchy edge (built {age} ago; {summary})."]

    try:
        upstream = database_versions(data)
    except (subprocess.CalledProcessError, OSError) as error:
        return [f"[factory] Omarchy edge changed since the factory was built {age} ago "
                f"(could not read the new index: {error}). Run `make refresh` for the latest."]
    try:
        installed = read_versions((guest / "packages.txt").read_text())
    except OSError:
        installed = {}
    changed = {name: (installed[name], version) for name, version in upstream.items()
               if name in installed and installed[name] != version}
    if not changed:
        return [f"[factory] Omarchy edge changed since the factory was built {age} ago, "
                f"but no package the factory installed has a new version ({summary})."]
    ordered = [name for name in KEY_PACKAGES if name in changed]
    ordered += sorted(name for name in changed if name not in KEY_PACKAGES)
    shown = ", ".join(f"{name} {changed[name][0]} -> {changed[name][1]}" for name in ordered[:5])
    more = f", and {len(ordered) - 5} more" if len(ordered) > 5 else ""
    return [
        f"[factory] Omarchy edge moved since the factory was built {age} ago: "
        f"{len(changed)} installed package{'s' if len(changed) != 1 else ''} newer upstream ({shown}{more}).",
        "[factory] New VMs start older and catch up with `omarchy update`. "
        "Run `make refresh` to build the factory from the latest Omarchy.",
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--check", action="store_true",
                        help="exit 1 unless every upstream input matches the factory")
    args = parser.parse_args()
    if args.check:
        reasons = check(args.root, REPOSITORY_URLS, NODE_INDEX_URL, timeout=30)
        for reason in reasons:
            print(f"[factory] {reason[0].upper()}{reason[1:]}.")
        if not reasons:
            print("[factory] Current with upstream: every repository and the Node.js release match.")
        return 1 if reasons else 0
    url = os.environ.get("OMARCHY_FRESHNESS_URL", DATABASE_URL)
    for line in report(args.root, url, datetime.now(timezone.utc), timeout=5):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
