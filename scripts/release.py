#!/usr/bin/env python3
"""Choose a release version, build its components, tag, and package locally."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

from app_version import build_version


VERSION = re.compile(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def git(root: Path, *arguments: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(root), *arguments], text=True, stderr=subprocess.PIPE,
    ).strip()


def clean_head(root: Path, expected: str | None = None) -> str:
    head = git(root, "rev-parse", "HEAD")
    if git(root, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("commit or remove local changes, including untracked files, before releasing")
    if expected is not None and head != expected:
        raise ValueError("HEAD changed during the release; retry from the intended commit")
    return head


def release_tags(root: Path, *arguments: str) -> list[str]:
    return [tag for tag in git(root, "tag", "--list", *arguments).splitlines()
            if tag.startswith("v") and VERSION.fullmatch(tag)]


def version_numbers(tag: str) -> tuple[int, ...]:
    return tuple(int(number) for number in tag.removeprefix("v").split("."))


def choose_version(root: Path, requested: str) -> str:
    if not requested:
        if not sys.stdin.isatty():
            raise ValueError("no interactive terminal; use make release VERSION=vX.Y.Z")
        tags = release_tags(root)
        current = release_tags(root, "--points-at", "HEAD")
        if len(current) > 1:
            raise ValueError("HEAD has multiple release tags; keep one unambiguous release version")
        latest = max(tags, key=version_numbers) if tags else None
        if latest:
            print(f"Latest local release tag: {latest}", flush=True)
        try:
            if current:
                print(f"HEAD is already tagged {current[0]}; Enter rebuilds that release.", flush=True)
                requested = input(f"Release tag [{current[0]}]: ").strip() or current[0]
            else:
                major, minor, patch = version_numbers(latest or "v0.0.0")
                if not latest:
                    print("No local release tags; increments start from v0.0.0.", flush=True)
                choices = {
                    "patch": f"v{major}.{minor}.{patch + 1}",
                    "minor": f"v{major}.{minor + 1}.0",
                    "major": f"v{major + 1}.0.0",
                }
                for number, (kind, tag) in enumerate(choices.items(), start=1):
                    print(f"  {number}) {kind.capitalize()} — {tag}", flush=True)
                while not requested:
                    choice = input("Select patch/minor/major (1–3), or type vX.Y.Z: ").strip()
                    kind = {"1": "patch", "2": "minor", "3": "major"}.get(
                        choice, choice.lower(),
                    )
                    if kind in choices:
                        requested = choices[kind]
                    else:
                        requested = choice
                    if not requested:
                        print("Select a release version; there is no default.", flush=True)
        except EOFError:
            raise ValueError("version prompt cancelled; use make release VERSION=vX.Y.Z") from None
    if not VERSION.fullmatch(requested):
        raise ValueError("VERSION must be x.y.z or vx.y.z, without leading zeros")
    return "v" + requested.removeprefix("v")


def validate_tag(root: Path, tag: str, head: str) -> bool:
    """Return whether this exact release can be rebuilt without creating a tag."""
    tags = release_tags(root)
    current = release_tags(root, "--points-at", head)
    if tag in tags and git(root, "rev-parse", f"refs/tags/{tag}^{{commit}}") != head:
        raise ValueError(f"{tag} already belongs to another commit; choose a new version")
    if current and current != [tag]:
        raise ValueError(f"this commit is already tagged {', '.join(current)}; rebuild that version")
    if tag in tags:
        return True
    if tags and version_numbers(tag) <= max(map(version_numbers, tags)):
        raise ValueError("choose a version newer than the latest local release tag")
    return False


def verify_release_artifacts(root: Path, tag: str) -> None:
    app = root / "dist/release.noindex/Try Omarchy.app"
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise ValueError(f"could not verify built app version: {error}") from error

    version = tag.removeprefix("v")
    if (info.get("CFBundleShortVersionString") != version
            or info.get("TryOmarchyBuildDescribe") != tag):
        raise ValueError(f"built app version does not match {tag}")

    dmg = root / "dist" / f"TryOmarchy-{tag}.dmg"
    if not dmg.is_file():
        raise ValueError(f"release DMG was not produced: {dmg}")


def release(root: Path, make: str) -> None:
    identity = os.environ.get("RELEASE_SIGN_IDENTITY", "")
    profile = os.environ.get("RELEASE_NOTARY_PROFILE", "")
    if not identity.startswith("Developer ID Application:") or not profile.strip():
        raise ValueError("release signing requires a Developer ID Application identity and notary profile")
    head = clean_head(root)
    tag = choose_version(root, os.environ.get("VERSION", ""))
    reusing = validate_tag(root, tag, head)
    if sys.stdin.isatty():
        action = "Rebuild release" if reusing else "Create release"
        try:
            answer = input(f"{action} {tag} from commit {head[:12]}? [y/N]: ").strip().lower()
        except EOFError:
            answer = ""
        if answer not in ("y", "yes"):
            raise ValueError("release cancelled; no builds or tag changes were made")
    clean_head(root, head)
    print(f"Preparing {tag} from {head[:12]}", flush=True)
    subprocess.run([make, "--no-print-directory", "-C", str(root), "guest", "runtime"], check=True)
    clean_head(root, head)
    if validate_tag(root, tag, head):
        print(f"Reusing {tag}", flush=True)
    else:
        git(root, "tag", "-a", tag, "-m", tag, head)
        print(f"Created local tag {tag}", flush=True)
    try:
        version = build_version(root)
        if not version or version["TryOmarchyBuildDescribe"] != tag:
            raise ValueError(f"app version does not resolve to {tag}; check the tags on HEAD")
        subprocess.run([
            str(root / "macos/build-app.sh"), "--configuration", "production", "--dmg",
            "--guest-dir", str(root / "dist/guest"),
            "--sign-identity", identity, "--notarize-profile", profile,
        ], cwd=root, check=True)
        verify_release_artifacts(root, tag)
        clean_head(root, head)
    except (ValueError, OSError, subprocess.CalledProcessError, KeyboardInterrupt):
        print(f"Local tag {tag} remains. Retry with make release VERSION={tag}", file=sys.stderr)
        raise
    print(f"Release DMG: {root / 'dist' / f'TryOmarchy-{tag}.dmg'}", flush=True)
    print(f"After verifying it, push the tag: git push origin {tag}", flush=True)
    print("Then create the GitHub release and upload the DMG.", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--make", default=os.environ.get("RELEASE_MAKE", "make"))
    args = parser.parse_args()
    release(args.root.resolve(), args.make)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        detail = error.stderr.strip() if isinstance(error.stderr, str) else ""
        print(f"release: {detail or f'command failed with exit status {error.returncode}'}", file=sys.stderr)
        raise SystemExit(1)
    except (ValueError, OSError) as error:
        print(f"release: {error}", file=sys.stderr)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print("release: cancelled", file=sys.stderr)
        raise SystemExit(130)
