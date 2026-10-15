#!/bin/bash
#
# Builds the try-omarchy pacman package with makepkg in the upstream builder
# image (guest/upstream/Containerfile).
#
#   guest/package/build.sh [--output DIR]
#
# Output defaults to dist/upstream-guest/packages.

set -euo pipefail

fail() {
  echo "try-omarchy-package: $*" >&2
  exit 1
}

package_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$package_dir/../.." && pwd)
output="$repo_dir/dist/upstream-guest/packages"

while (($#)); do
  case $1 in
    --output) output=${2:?}; shift 2 ;;
    -h | --help) sed -n '2,8p' "$0"; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done

command -v docker >/dev/null || fail "docker is required"
mkdir -p "$output"
output=$(cd "$output" && pwd)
builder_image=try-omarchy-upstream-builder
docker build --quiet --platform linux/arm64 -f "$repo_dir/guest/upstream/Containerfile" -t "$builder_image" "$repo_dir" >/dev/null

# makepkg refuses root: build as an unprivileged user from a copy of the
# recipe, with the battery module and license beside it as the PKGBUILD expects.
docker run --rm --platform linux/arm64 --entrypoint /bin/bash \
  -v "$repo_dir:/workspace:ro" -v "$output:/output" "$builder_image" -c '
    set -euo pipefail
    useradd -m builder
    install -d -o builder /build/guest/package /build/guest/native-module
    cp -r --preserve=mode,timestamps /workspace/guest/package/try-omarchy /build/guest/package/
    cp -r --preserve=mode,timestamps /workspace/guest/native-module/try-omarchy-battery /build/guest/native-module/
    cp /workspace/LICENSE /build/LICENSE
    chown -R builder /build
    cd /build/guest/package/try-omarchy
    # libfakeroot reports "payload not recognized" for the xattr calls some
    # container filesystems make; the package contents are unaffected.
    runuser -u builder -- env PKGEXT=.pkg.tar.zst makepkg --nodeps --force --noconfirm 2>&1 | grep -v "libfakeroot internal error" >&2
    rm -f /output/try-omarchy-*.pkg.tar.zst
    install -m 0644 try-omarchy-*.pkg.tar.zst /output/
    ls try-omarchy-*.pkg.tar.zst
  '
