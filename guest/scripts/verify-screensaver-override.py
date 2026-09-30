#!/usr/bin/env python3

"""Limit the native override to cursor restoration and reliable effect input/lifetime."""

from __future__ import annotations

import argparse
from pathlib import Path


UPSTREAM_CURSOR_RESTORE = (
    "  hyprctl eval 'hl.config({ cursor = { invisible = false } })' &>/dev/null "
    "|| hyprctl keyword cursor:invisible false &>/dev/null || true"
)
NATIVE_CURSOR_RESTORE = (
    "  /usr/local/bin/omarchy-native-cursor-restore 2>/dev/null || true"
)
UPSTREAM_INPUT = "  ttfx -i ~/.config/omarchy/branding/screensaver.txt "
NATIVE_INPUT = (
    '  ttfx <<< "$(/usr/local/bin/omarchy-native-screensaver-text '
    '~/.config/omarchy/branding/screensaver.txt)" '
)
UPSTREAM_EFFECT_LOOP = '  while pgrep -t "${tty#/dev/}" -x ttfx >/dev/null; do'
NATIVE_EFFECT_LOOP = (
    '  # Input preparation can outlast a process-name probe. Track this launch so\n'
    '  # another effect cannot start while its terminal-sized text is being read.\n'
    '  effect_pid=$!\n  while kill -0 "$effect_pid" 2>/dev/null; do'
)
UPSTREAM_LOOP_END = '  done\ndone\n'
NATIVE_LOOP_END = '  done\n  wait "$effect_pid" || sleep 1\ndone\n'


def expected_override(upstream: str) -> str:
    for original, replacement in (
        (UPSTREAM_CURSOR_RESTORE, NATIVE_CURSOR_RESTORE),
        (UPSTREAM_INPUT, NATIVE_INPUT),
        (UPSTREAM_EFFECT_LOOP, NATIVE_EFFECT_LOOP),
        (UPSTREAM_LOOP_END, NATIVE_LOOP_END),
    ):
        if upstream.count(original) != 1:
            raise ValueError("pinned upstream screensaver changed; review the native override")
        upstream = upstream.replace(original, replacement)
    return upstream


def read(path: Path, label: str) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise SystemExit(f"verify-screensaver-override: cannot read {label}: {error}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--override", required=True, type=Path)
    args = parser.parse_args()

    upstream = read(args.source, "pinned upstream screensaver")
    native = read(args.override, "native screensaver override")
    try:
        expected = expected_override(upstream)
    except ValueError as error:
        raise SystemExit(f"verify-screensaver-override: {error}")
    if native != expected:
        raise SystemExit(
            "verify-screensaver-override: native screensaver must differ from pinned "
            "upstream only at cursor restoration and effect input/lifetime"
        )


if __name__ == "__main__":
    main()
