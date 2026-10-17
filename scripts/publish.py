#!/usr/bin/env python3
"""Push the built release's tag and attach its assets to a GitHub draft release."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys

from release import VERSION, git, release_assets, verify_release_artifacts


REPOSITORY = "omacom/try-omarchy"


def gh(*arguments: str) -> str:
    return subprocess.check_output(["gh", *arguments], text=True, stderr=subprocess.PIPE).strip()


def built_tag(root: Path) -> str:
    app = root / "dist/release.noindex/Try Omarchy.app"
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise ValueError(f"no release build to publish; run make release first ({error})") from error
    tag = info.get("TryOmarchyBuildDescribe", "")
    if not VERSION.fullmatch(tag) or not tag.startswith("v"):
        raise ValueError(f"the built app is not a release build ({tag or 'no version'}); run make release")
    return tag


def push_tag(root: Path, tag: str) -> None:
    """The release must point at the commit that was built, so the tag is
    pushed before GitHub could create one from the draft's target branch."""
    try:
        local = git(root, "rev-parse", f"refs/tags/{tag}^{{commit}}")
    except subprocess.CalledProcessError:
        raise ValueError(f"the local tag {tag} is missing; the build cannot be matched to a commit") from None
    # An annotated tag is listed twice; its peeled `^{}` line names the commit.
    refs = dict(reversed(line.split("\t")) for line in
                git(root, "ls-remote", "--tags", "origin").splitlines())
    published = refs.get(f"refs/tags/{tag}^{{}}", refs.get(f"refs/tags/{tag}"))
    if published is None:
        print(f"Pushing {tag}", flush=True)
        subprocess.run(["git", "-C", str(root), "push", "origin", f"refs/tags/{tag}"], check=True)
    elif published != local:
        raise ValueError(f"origin's {tag} points at {published[:12]}, not the built commit {local[:12]}")
    else:
        print(f"{tag} is already on origin", flush=True)


def find_release(tag: str) -> dict | None:
    pages = gh("api", "--paginate", "--slurp", f"repos/{REPOSITORY}/releases")
    releases = [release for page in json.loads(pages) for release in page]
    tagged = [release for release in releases if release["tag_name"] == tag]
    if tagged:
        return tagged[0]
    # A draft created on GitHub before its tag existed: same title, no tag yet.
    untagged = [release for release in releases
                if release["draft"] and not release["tag_name"] and release["name"] == tag]
    if len(untagged) > 1:
        raise ValueError(f"several untagged drafts are named {tag}; delete the extras")
    if untagged:
        draft = untagged[0]
        print(f"Selecting {tag} on the draft named {tag}", flush=True)
        gh("api", "-X", "PATCH", f"repos/{REPOSITORY}/releases/{draft['id']}", "-f", f"tag_name={tag}")
        draft["tag_name"] = tag
        return draft
    return None


def publish(root: Path) -> None:
    tag = built_tag(root)
    verify_release_artifacts(root, tag)
    assets = [str(path) for path in release_assets(root)]
    push_tag(root, tag)
    release = find_release(tag)
    if release is None:
        print(f"Creating a draft release for {tag}", flush=True)
        gh("release", "create", tag, "--repo", REPOSITORY, "--draft", "--verify-tag", "--title", tag, *assets)
    elif not release["draft"]:
        raise ValueError(f"{tag} is already published; its assets are left unchanged")
    else:
        print(f"Uploading to the draft release for {tag}", flush=True)
        gh("release", "upload", tag, "--repo", REPOSITORY, "--clobber", *assets)
    for asset in assets:
        print(f"  {Path(asset).name}", flush=True)
    url = gh("release", "view", tag, "--repo", REPOSITORY, "--json", "url", "--jq", ".url")
    print(f"Draft ready: {url}", flush=True)
    print("Review the notes and publish it on GitHub; the app downloads the image only once it is published.", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    args = parser.parse_args()
    publish(args.root.resolve())


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        detail = error.stderr.strip() if isinstance(error.stderr, str) else ""
        print(f"publish: {detail or f'command failed with exit status {error.returncode}'}", file=sys.stderr)
        raise SystemExit(1)
    except (ValueError, OSError) as error:
        print(f"publish: {error}", file=sys.stderr)
        raise SystemExit(1)
