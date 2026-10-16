#!/bin/bash
#
# Unpacks the Omarchy the factory installs today (omarchy-dev and
# omarchy-settings-dev from the aarch64 edge repository) into DIR, for the
# package's upstream contract tests (guest/package/tests/test_upstream.py).
#
#   guest/tests/fetch-upstream.sh DIR
#
# Each archive must match the SHA-256 the repository database lists, and its
# signature must verify against the reviewed Omarchy key (guest/keys) when
# gpgv is installed. DIR/versions.txt records what was unpacked.

set -euo pipefail

fail() {
  echo "fetch-upstream: $*" >&2
  exit 1
}

(($# == 1)) || fail "usage: fetch-upstream.sh DIR"
for tool in curl tar zstd; do
  command -v "$tool" >/dev/null || fail "$tool is required"
done
repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
repository=https://pkgs.omarchy.org/edge/aarch64
out=$1
mkdir -p "$out"
work=$(mktemp -d "${TMPDIR:-/tmp}/fetch-upstream.XXXXXX")
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 3 -o "$work/omarchy.db" "$repository/omarchy.db"
mkdir "$work/db"
zstd -dc "$work/omarchy.db" | tar -x -C "$work/db"

keyring=""
if command -v gpgv >/dev/null && command -v gpg >/dev/null; then
  keyring=$work/omarchy-keyring.gpg
  gpg --dearmor <"$repo_dir/guest/keys/omarchy.gpg" >"$keyring"
fi

field() { # desc-file field
  awk -v f="%$2%" '$0 == f { getline; print; exit }' "$1"
}

: >"$out/versions.txt"
for name in omarchy-dev omarchy-settings-dev; do
  desc=""
  for candidate in "$work/db/$name"-[0-9]*/desc; do
    [[ $(field "$candidate" NAME) == "$name" ]] && desc=$candidate
  done
  [[ -n $desc ]] || fail "$name is not in the repository"
  file=$(field "$desc" FILENAME)
  sha=$(field "$desc" SHA256SUM)
  [[ $file =~ ^[A-Za-z0-9._+-]+\.pkg\.tar\.zst$ && $sha =~ ^[0-9a-f]{64}$ ]] || fail "$name: bad repository entry"
  curl -fsSL --retry 3 -o "$work/$file" "$repository/$file"
  actual=$(shasum -a 256 "$work/$file" | cut -d' ' -f1)
  [[ $actual == "$sha" ]] || fail "$file does not match the repository's checksum"
  if [[ -n $keyring ]]; then
    curl -fsSL --retry 3 -o "$work/$file.sig" "$repository/$file.sig"
    gpgv --quiet --keyring "$keyring" "$work/$file.sig" "$work/$file" 2>/dev/null ||
      fail "$file is not signed by the reviewed Omarchy key"
  fi
  zstd -dc "$work/$file" | tar -x -C "$out" --exclude='.PKGINFO' --exclude='.BUILDINFO' --exclude='.MTREE' --exclude='.INSTALL'
  printf '%s %s\n' "$name" "$(field "$desc" VERSION)" >>"$out/versions.txt"
done
cat "$out/versions.txt"
