#!/bin/bash
#
# Builds the upstream-shell factory image in a privileged ARM64 container.
#
#   guest/factory/build-container.sh [--output DIR] [--package FILE]... [--size-gib N]
#
# Output defaults to dist/guest. The package cache lives in a
# project-scoped Docker volume so repeated builds reuse downloads.

set -euo pipefail

fail() {
  echo "guest-build: $*" >&2
  exit 1
}

upstream_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$upstream_dir/../.." && pwd)
output="$repo_dir/dist/guest"
packages=()
build_args=()

while (($#)); do
  case $1 in
    --output) output=${2:?}; shift 2 ;;
    --package) packages+=("${2:?}"); shift 2 ;;
    --size-gib) build_args+=(--size-gib "${2:?}"); shift 2 ;;
    -h | --help) sed -n '2,9p' "$0"; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done

command -v docker >/dev/null || fail "docker is required"
mkdir -p "$output"
output=$(cd "$output" && pwd)

package_mounts=()
for package in ${packages[@]+"${packages[@]}"}; do
  [[ -f $package ]] || fail "package not found: $package"
  package=$(cd "$(dirname "$package")" && pwd)/$(basename "$package")
  name=$(basename "$package")
  package_mounts+=(-v "$package:/packages/$name:ro")
  build_args+=(--package "/packages/$name")
done

repo_checksum=$(printf '%s' "$repo_dir" | cksum)
work_volume="try-omarchy-upstream-work-${repo_checksum%% *}"
# GUEST_BUILDER_IMAGE names an already built builder image (CI restores one
# from its cache); otherwise the Containerfile is built here.
builder_image=${GUEST_BUILDER_IMAGE:-try-omarchy-guest-builder}

[[ -n ${GUEST_BUILDER_IMAGE:-} ]] ||
  docker build --platform linux/arm64 -f "$upstream_dir/Containerfile" -t "$builder_image" "$repo_dir"
docker volume create --label dev.tryomarchy.role=upstream-work "$work_volume" >/dev/null
docker run --rm --platform linux/arm64 --privileged \
  -v "$repo_dir:/workspace:ro" \
  -v "$output:/output" \
  -v "$work_volume:/work" \
  ${package_mounts[@]+"${package_mounts[@]}"} \
  "$builder_image" \
  --output /output --work /work ${build_args[@]+"${build_args[@]}"}
