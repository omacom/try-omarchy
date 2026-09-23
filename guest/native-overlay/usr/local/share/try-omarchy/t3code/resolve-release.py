#!/usr/bin/env python3
"""Validate GitHub's stable release metadata before generating shell inputs."""
import json
import re
import sys


def resolve(release):
    if release.get('draft') is not False or release.get('prerelease') is not False:
        raise ValueError('expected a published stable release')
    tag = release.get('tag_name', '')
    if not isinstance(tag, str) or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag):
        raise ValueError('invalid stable version')
    version = tag[1:]
    name = f'T3-Code-{version}-arm64.AppImage'
    assets = [a for a in release.get('assets', []) if a.get('name') == name]
    if len(assets) != 1:
        raise ValueError('release must contain exactly one ARM64 Electron AppImage')
    asset = assets[0]
    url = f'https://github.com/pingdotgg/t3code/releases/download/{tag}/{name}'
    if asset.get('browser_download_url') != url:
        raise ValueError('unexpected ARM64 download URL')
    digest = asset.get('digest', '')
    if not isinstance(digest, str) or not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
        raise ValueError('release is missing its GitHub SHA-256 digest')
    return version, url, digest.removeprefix('sha256:')


if __name__ == '__main__':
    try:
        print('\n'.join(resolve(json.load(sys.stdin))))
    except (ValueError, TypeError, AttributeError) as error:
        sys.exit(f'T3 Code release metadata rejected: {error}')
