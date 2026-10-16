#!/bin/bash
#
# Builds the guest: the try-omarchy integration package, then the factory
# disk with that package installed. Both run in the privileged ARM64 builder.
# --factory-only builds the disk with the package already in DIR/packages
# (make guest builds the package as its own cached step).
#
#   guest/build.sh [--factory-only] [--output DIR]
#
# Output defaults to dist/guest: the factory files plus packages/.

set -euo pipefail

guest_dir=$(cd "$(dirname "$0")" && pwd)
output="$guest_dir/../dist/guest"
factory_only=0
while (($#)); do
  case $1 in
    --factory-only) factory_only=1; shift ;;
    --output) output=${2:?}; shift 2 ;;
    *) echo "Usage: guest/build.sh [--factory-only] [--output DIR]" >&2; exit 64 ;;
  esac
done

mkdir -p "$output"
output=$(cd "$output" && pwd)
if ((!factory_only)); then
  rm -rf "$output/packages"
  "$guest_dir/package/build.sh" --output "$output/packages"
fi
shopt -s nullglob
packages=("$output"/packages/try-omarchy-*.pkg.tar.zst)
((${#packages[@]} == 1)) || { echo "guest/build.sh: expected one try-omarchy package" >&2; exit 1; }
"$guest_dir/factory/build-container.sh" --output "$output" --package "${packages[0]}"
