#!/bin/bash
#
# Builds the guest: the try-omarchy integration package, then the factory
# disk with that package installed. Both run in the privileged ARM64 builder.
#
#   guest/build.sh [--output DIR]
#
# Output defaults to dist/guest: the factory files plus packages/.

set -euo pipefail

guest_dir=$(cd "$(dirname "$0")" && pwd)
output="$guest_dir/../dist/guest"
case ${1:-} in
  --output) output=${2:?}; shift 2 ;;
  '') ;;
  *) echo "Usage: guest/build.sh [--output DIR]" >&2; exit 64 ;;
esac
(($# == 0)) || { echo "Usage: guest/build.sh [--output DIR]" >&2; exit 64; }

mkdir -p "$output"
output=$(cd "$output" && pwd)
rm -rf "$output/packages"
"$guest_dir/package/build.sh" --output "$output/packages"
shopt -s nullglob
packages=("$output"/packages/try-omarchy-*.pkg.tar.zst)
((${#packages[@]} == 1)) || { echo "guest/build.sh: expected one try-omarchy package" >&2; exit 1; }
"$guest_dir/factory/build-container.sh" --output "$output" --package "${packages[0]}"
