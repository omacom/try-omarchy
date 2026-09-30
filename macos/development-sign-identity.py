#!/usr/bin/env python3
"""Resolve the actual certificate before fingerprinting a development build."""

import re
import subprocess
import sys


def resolve(requested: str) -> str:
    if requested != "auto":
        return requested
    result = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning"],
        check=True, capture_output=True, text=True,
    )
    identities = re.findall(r'^\s*\d+\) ([0-9A-Fa-f]{40}) "([^"]+)"', result.stdout, re.M)
    for prefix in ("Apple Development:", "Developer ID Application:"):
        matches = sorted({digest for digest, name in identities if name.startswith(prefix)})
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            raise ValueError(
                f"multiple {prefix} certificates; set DEVELOPMENT_SIGN_IDENTITY "
                "to the certificate name or SHA-1 fingerprint to keep using the same identity"
            )
    raise ValueError(
        "no signing certificate found; create an Apple Development certificate in Xcode "
        "to retain privacy grants, or explicitly set DEVELOPMENT_SIGN_IDENTITY=- "
        "for an ad-hoc build that requires renewed grants after rebuilds"
    )


if __name__ == "__main__":
    try:
        print(resolve(sys.argv[1] if len(sys.argv) > 1 else "auto"))
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        sys.exit(f"development signing: {error}")
