#!/bin/bash
#
# Builds the try-omarchy package from this tree and, with --base, from another
# revision, then installs, upgrades and removes them in the guest builder
# image against Omarchy's live repositories (guest/tests/package-install.sh).
#
#   guest/tests/package-check.sh [--base REV] [--cache DIR]
#
# --base REV   also build REV's package and test the upgrade from it; the
#              version must go up when the package's files differ from REV's
# --cache DIR  pacman package cache to reuse between runs
#
# GUEST_BUILDER_IMAGE names an already built builder image (see
# guest/package/build.sh).

set -euo pipefail

fail() {
  echo "package-check: $*" >&2
  exit 1
}

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
base=""
cache=""
while (($#)); do
  case $1 in
    --base) base=${2:?}; shift 2 ;;
    --cache) cache=${2:?}; shift 2 ;;
    -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done

command -v docker >/dev/null || fail "docker is required"
builder_image=${GUEST_BUILDER_IMAGE:-try-omarchy-guest-builder}
if [[ -z ${GUEST_BUILDER_IMAGE:-} ]]; then
  docker build --quiet --platform linux/arm64 -f "$repo_dir/guest/factory/Containerfile" -t "$builder_image" "$repo_dir" >/dev/null
fi
export GUEST_BUILDER_IMAGE=$builder_image

work=$(mktemp -d "${TMPDIR:-/tmp}/package-check.XXXXXX")
cleanup() {
  [[ -z $base ]] || git -C "$repo_dir" worktree remove --force "$work/base-tree" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

echo "==> Building this tree's package"
"$repo_dir/guest/package/build.sh" --output "$work/new" >/dev/null

mounts=(-v "$work/new:/packages/new:ro")
arguments=(/packages/new/try-omarchy-*.pkg.tar.zst)
changed=0
if [[ -n $base ]]; then
  git -C "$repo_dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null || fail "unknown revision: $base"
  if git -C "$repo_dir" cat-file -e "$base:guest/package/try-omarchy/PKGBUILD" 2>/dev/null; then
    echo "==> Building $base's package"
    git -C "$repo_dir" worktree add --detach --quiet "$work/base-tree" "$base"
    # The base's recipe, packed by this tree's build script (an older one may
    # not run on this host).
    cp "$repo_dir/guest/package/build.sh" "$work/base-tree/guest/package/build.sh"
    "$work/base-tree/guest/package/build.sh" --output "$work/base" >/dev/null
    mounts+=(-v "$work/base:/packages/base:ro")
    arguments+=(/packages/base/try-omarchy-*.pkg.tar.zst)
    git -C "$repo_dir" diff --quiet "$base" -- guest/package/try-omarchy LICENSE || changed=1
  else
    echo "==> $base has no guest package; testing a fresh install only"
  fi
fi
if [[ -n $cache ]]; then
  mkdir -p "$cache"
  mounts+=(-v "$(cd "$cache" && pwd):/var/cache/pacman/pkg")
fi

echo "==> Installing in the builder image"
docker run --rm --platform linux/arm64 --entrypoint /bin/bash -e "PACKAGE_CHANGED=$changed" \
  -v "$repo_dir/guest/tests:/tests:ro" "${mounts[@]}" "$builder_image" \
  -c "/tests/package-install.sh ${arguments[*]}"
