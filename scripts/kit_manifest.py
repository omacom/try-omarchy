#!/usr/bin/env python3
"""Write or check the kit's manifest: its version, run-mode protocol and build date."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import re
import sys


FORMAT = 1
DEVELOPMENT = "development"
RELEASE = re.compile(r"v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})")
PROTOCOL_SOURCE = "macos/Sources/TryOmarchyKitClient/VMRunProtocol.swift"
CAPABILITIES = ["native-exports"]
CAPABILITY = re.compile(r"[a-z][a-z0-9-]{0,63}")
DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")


def kit_version(describe: str | None) -> str:
    return describe if describe and RELEASE.fullmatch(describe) else DEVELOPMENT


def run_protocol_version(root: Path) -> int:
    source = (root / PROTOCOL_SOURCE).read_text(encoding="utf-8")
    found = re.findall(r"^    public static let version = ([1-9][0-9]*)$", source, re.M)
    if len(found) != 1:
        raise ValueError(f"cannot find the run-mode protocol version in {PROTOCOL_SOURCE}")
    return int(found[0])


def manifest(version: str, protocol: int, built: datetime) -> dict:
    return {
        "format": FORMAT,
        "version": version,
        "runProtocolVersion": protocol,
        "buildDate": built.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "capabilities": CAPABILITIES,
    }


def validate(value: object) -> dict:
    if not isinstance(value, dict):
        raise ValueError("the kit manifest is not an object")
    version, protocol, built = value.get("version"), value.get("runProtocolVersion"), value.get("buildDate")
    if (value.get("format") != FORMAT or type(value.get("format")) is not int
            or not isinstance(version, str) or not (version == DEVELOPMENT or RELEASE.fullmatch(version))
            or type(protocol) is not int or protocol < 1
            or not isinstance(built, str) or not DATE.fullmatch(built)):
        raise ValueError("the kit manifest is invalid")
    capabilities = value.get("capabilities", [])
    if (not isinstance(capabilities, list) or len(set(map(str, capabilities))) != len(capabilities)
            or not all(isinstance(name, str) and CAPABILITY.fullmatch(name) for name in capabilities)):
        raise ValueError("the kit manifest's capabilities are invalid")
    return value


def read(path: Path) -> dict:
    return validate(json.loads(path.read_text(encoding="utf-8")))


def check(root: Path, path: Path) -> dict:
    """A built kit's manifest, which must speak this checkout's run-mode protocol."""
    value = read(path)
    if value["runProtocolVersion"] != run_protocol_version(root):
        raise ValueError(f"{path} names run-mode protocol {value['runProtocolVersion']}, "
                         f"not {run_protocol_version(root)}")
    return value


def write(root: Path, app: Path, output: Path, built: datetime | None = None) -> dict:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    value = manifest(kit_version(info.get("TryOmarchyBuildDescribe")), run_protocol_version(root),
                     built or datetime.now(timezone.utc))
    output.write_text(json.dumps(validate(value), indent=2) + "\n", encoding="utf-8")
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--app", type=Path, help="the app the kit is derived from")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", type=Path, help="a built kit's kit.json to validate instead")
    args = parser.parse_args()
    if args.check:
        value = check(args.root, args.check)
    elif args.app and args.output:
        value = write(args.root, args.app, args.output)
    else:
        parser.error("give --app and --output, or --check")
    print(f"[kit] Version {value['version']}, run-mode protocol {value['runProtocolVersion']}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"kit-manifest: {error}", file=sys.stderr)
        raise SystemExit(1)
