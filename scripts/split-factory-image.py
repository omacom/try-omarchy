#!/usr/bin/env python3
"""Split the compressed factory into release assets and write the app's download manifest.

GitHub release assets must stay under 2 GiB, so the image is published as
consecutive byte ranges with their own digests. The app downloads them into
one file and checks every part and the whole image
(macos/Sources/OmarchyVMHelper/FactoryImageDownload.swift).
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit

# Well under GitHub's 2 GiB asset limit; a damaged part costs at most this much
# to download again.
PART_BYTES = 1 << 30
DIGEST = re.compile(r"[0-9a-f]{64}")
CHUNK = 8 << 20


def split(image: Path, factory: dict, base_url: str, output: Path, part_bytes: int) -> dict:
    url = urlsplit(base_url)
    loopback = url.scheme == "http" and url.hostname in ("127.0.0.1", "localhost")
    if not (url.scheme == "https" or loopback) or not url.hostname or not base_url.endswith("/"):
        raise ValueError("the download URL must be an https:// folder URL ending in /")
    identity = factory["disk"]["sha256"]
    expected = factory["compressed"]["sha256"]
    if not DIGEST.fullmatch(identity) or not DIGEST.fullmatch(expected):
        raise ValueError("factory.json has no valid digests")
    if part_bytes <= 0:
        raise ValueError("the part size must be positive")

    output.mkdir(parents=True, exist_ok=True)
    for stale in output.glob(f"{image.name}.*"):
        stale.unlink()
    whole = hashlib.sha256()
    parts = []
    with image.open("rb") as source:
        while True:
            name = f"{image.name}.{len(parts) + 1:03d}"
            digest = hashlib.sha256()
            written = 0
            with (output / name).open("wb") as target:
                while written < part_bytes:
                    data = source.read(min(CHUNK, part_bytes - written))
                    if not data:
                        break
                    target.write(data)
                    digest.update(data)
                    whole.update(data)
                    written += len(data)
            if written == 0:
                (output / name).unlink()
                break
            parts.append({"url": base_url + name, "bytes": written, "sha256": digest.hexdigest()})
            if written < part_bytes:
                break
    if not parts:
        raise ValueError(f"{image} is empty")
    if whole.hexdigest() != expected:
        raise ValueError(f"{image} does not match factory.json; rebuild the guest")
    if len(parts) > 64:
        raise ValueError("the image needs more than 64 parts; raise the part size")
    return {
        "format": 1,
        "kind": "try-omarchy-factory-download",
        "identity": identity,
        "image": {"bytes": sum(part["bytes"] for part in parts), "sha256": expected},
        "parts": parts,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--guest-dir", required=True, type=Path)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--output", required=True, type=Path, help="folder for the release assets")
    parser.add_argument("--manifest", required=True, type=Path, help="download.json to write")
    parser.add_argument("--part-bytes", type=int, default=PART_BYTES)
    args = parser.parse_args()
    factory = json.loads((args.guest_dir / "factory.json").read_text())
    image = args.guest_dir / factory["compressed"]["path"]
    if "/" in factory["compressed"]["path"] or not image.is_file() or image.is_symlink():
        raise ValueError(f"the compressed factory is missing or unsafe: {image}")
    manifest = split(image, factory, args.base_url, args.output, args.part_bytes)
    args.manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    for part in manifest["parts"]:
        print(f"[factory] {part['url'].rsplit('/', 1)[1]}: {part['bytes']} bytes", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"split-factory-image: {error}", file=sys.stderr)
        raise SystemExit(1)
