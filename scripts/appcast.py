#!/usr/bin/env python3
"""Sign a release's DMG as an update and write the appcast that offers it."""

from __future__ import annotations

import argparse
import base64
import binascii
from email.utils import formatdate
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
from xml.etree import ElementTree


RELEASES = "https://github.com/omacom/try-omarchy/releases"
FEED_URL = f"{RELEASES}/latest/download/appcast.xml"
KEYCHAIN_ACCOUNT = "try-omarchy"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ElementTree.register_namespace("sparkle", SPARKLE)


def sparkle(name: str) -> str:
    return f"{{{SPARKLE}}}{name}"


def app_info(app: Path) -> dict:
    return plistlib.loads((app / "Contents/Info.plist").read_bytes())


def public_key(info: dict) -> str | None:
    """The key the app accepts updates from; None for a build without updates."""
    feed, key = info.get("SUFeedURL"), info.get("SUPublicEDKey")
    if not feed and not key:
        return None
    if feed != FEED_URL:
        raise ValueError(f"the app's update feed is {feed!r}, not {FEED_URL}")
    try:
        valid = len(base64.b64decode(key or "", validate=True)) == 32
    except (binascii.Error, ValueError):
        valid = False
    if not valid:
        raise ValueError("the app's SUPublicEDKey is not an Ed25519 public key")
    return key


def sign(root: Path, dmg: Path) -> str:
    tool = root / "macos/.build/artifacts/sparkle/Sparkle/bin/sign_update"
    key_file = os.environ.get("RELEASE_UPDATE_KEY_FILE")
    key = ["--ed-key-file", key_file] if key_file else ["--account", KEYCHAIN_ACCOUNT]
    return subprocess.check_output([str(tool), *key, "-p", str(dmg)], text=True).strip()


def check_signature(key: str, signature: str, dmg: Path) -> None:
    verifier = Path(__file__).with_name("verify-update-signature.swift")
    result = subprocess.run(["xcrun", "swift", str(verifier), key, signature, str(dmg)])
    if result.returncode != 0:
        raise ValueError("the update's signature does not match the app's SUPublicEDKey; installed apps would refuse it")


def fields(info: dict, tag: str, dmg: Path) -> dict[str, str]:
    return {
        "version": info["CFBundleVersion"],
        "shortVersionString": info["CFBundleShortVersionString"],
        "minimumSystemVersion": info["LSMinimumSystemVersion"],
        "link": f"{RELEASES}/tag/{tag}",
        "url": f"{RELEASES}/download/{tag}/{dmg.name}",
        "length": str(dmg.stat().st_size),
    }


def write(path: Path, expected: dict[str, str], signature: str) -> None:
    feed = ElementTree.Element("rss", {"version": "2.0"})
    channel = ElementTree.SubElement(feed, "channel")
    ElementTree.SubElement(channel, "title").text = "Try Omarchy"
    item = ElementTree.SubElement(channel, "item")
    ElementTree.SubElement(item, "title").text = f"Try Omarchy {expected['shortVersionString']}"
    ElementTree.SubElement(item, "pubDate").text = formatdate(usegmt=True)
    ElementTree.SubElement(item, "link").text = expected["link"]
    for name in ("version", "shortVersionString", "minimumSystemVersion"):
        ElementTree.SubElement(item, sparkle(name)).text = expected[name]
    ElementTree.SubElement(item, "enclosure", {
        "url": expected["url"], "length": expected["length"], "type": "application/octet-stream",
        sparkle("edSignature"): signature,
    })
    ElementTree.indent(feed)
    ElementTree.ElementTree(feed).write(path, encoding="utf-8", xml_declaration=True)


def verify(path: Path, app: Path, dmg: Path, tag: str) -> None:
    """The appcast offers exactly this DMG as this release, signed for installed apps."""
    info = app_info(app)
    key = public_key(info)
    if key is None:
        if path.exists():
            raise ValueError(f"the app takes no updates, so {path} is from another build; delete it")
        return
    try:
        items = ElementTree.parse(path).findall("./channel/item")
        item, = items
        enclosure = item.find("enclosure")
        found = {name: item.findtext(sparkle(name)) for name in ("version", "shortVersionString", "minimumSystemVersion")}
        found |= {"link": item.findtext("link"), "url": enclosure.get("url"), "length": enclosure.get("length")}
        signature = enclosure.get(sparkle("edSignature")) or ""
        # Sparkle prefers a version on the enclosure over the item's.
        if set(enclosure.attrib) != {"url", "length", "type", sparkle("edSignature")}:
            raise ValueError("unexpected enclosure attributes")
    except (OSError, ElementTree.ParseError, ValueError, AttributeError) as error:
        raise ValueError(f"the release has no valid appcast; run make release ({error})") from error
    expected = fields(info, tag, dmg)
    wrong = [name for name in expected if found[name] != expected[name]]
    if wrong:
        raise ValueError(f"the appcast does not describe {dmg.name} of {tag}: {', '.join(wrong)}")
    check_signature(key, signature, dmg)


def create(root: Path, path: Path, app: Path, dmg: Path, tag: str) -> bool:
    """Returns False, leaving no appcast, for an app that takes no updates."""
    path.unlink(missing_ok=True)
    info = app_info(app)
    if public_key(info) is None:
        return False
    write(path, fields(info, tag, dmg), sign(root, dmg))
    verify(path, app, dmg, tag)
    return True


def check_signing_key(root: Path) -> None:
    """Fails before a long build when the key cannot sign what it will produce."""
    key = public_key(plistlib.loads((root / "macos/Info.plist").read_bytes()))
    if key is None:
        return
    subprocess.run(["swift", "package", "--disable-sandbox", "resolve"], cwd=root / "macos", check=True)
    with tempfile.NamedTemporaryFile() as sample:
        sample.write(os.urandom(64))
        sample.flush()
        check_signature(key, sign(root, Path(sample.name)), Path(sample.name))


def main() -> None:
    """make package: the release build's appcast, as make release writes it."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--check-key", action="store_true", help="only check that the update key can sign")
    arguments = parser.parse_args()
    root = arguments.root.resolve()
    if arguments.check_key:
        check_signing_key(root)
        return
    app = root / "dist/release.noindex/Try Omarchy.app"
    tag = app_info(app)["TryOmarchyBuildDescribe"]
    if create(root, root / "dist/appcast.xml", app, root / "dist/TryOmarchy.dmg", tag):
        print("Signed the DMG as an update: dist/appcast.xml", flush=True)
    else:
        print("This build takes no app updates; no appcast", flush=True)


def check_build_number(root: Path, tag: str, tags: list[str]) -> None:
    """Sparkle compares CFBundleVersion, the commit count, so an app would never
    see a release whose count is not higher than every earlier one's."""
    def git(*arguments: str) -> str:
        return subprocess.check_output(["git", "-C", str(root), *arguments], text=True).strip()

    if git("rev-parse", "--is-shallow-repository") == "true":
        raise ValueError("a shallow clone has no reliable build number; run git fetch --unshallow")
    build = int(git("rev-list", "--count", "HEAD"))
    for earlier in tags:
        if earlier != tag and re.fullmatch(r"v\d+\.\d+\.\d+", earlier):
            count = int(git("rev-list", "--count", earlier))
            if count >= build:
                raise ValueError(f"build {build} is not newer than {earlier}'s build {count}; release from main")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(f"appcast: command failed with exit status {error.returncode}", file=sys.stderr)
        raise SystemExit(1)
    except (OSError, ValueError, KeyError) as error:
        print(f"appcast: {error}", file=sys.stderr)
        raise SystemExit(1)
