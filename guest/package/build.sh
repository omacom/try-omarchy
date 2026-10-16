#!/bin/bash
#
# Builds the try-omarchy pacman package with makepkg in the upstream builder
# image (guest/factory/Containerfile).
#
#   guest/package/build.sh [--output DIR]
#
# Output defaults to dist/guest/packages.

set -euo pipefail

fail() {
  echo "try-omarchy-package: $*" >&2
  exit 1
}

package_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$package_dir/../.." && pwd)
output="$repo_dir/dist/guest/packages"

while (($#)); do
  case $1 in
    --output) output=${2:?}; shift 2 ;;
    -h | --help) sed -n '2,8p' "$0"; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done

command -v docker >/dev/null || fail "docker is required"
command -v git >/dev/null || fail "git is required"
mkdir -p "$output"
output=$(cd "$output" && pwd)
# GUEST_BUILDER_IMAGE names an already built builder image (CI restores one
# from its cache); otherwise the Containerfile is built here.
builder_image=${GUEST_BUILDER_IMAGE:-try-omarchy-guest-builder}
[[ -n ${GUEST_BUILDER_IMAGE:-} ]] ||
  docker build --quiet --platform linux/arm64 -f "$repo_dir/guest/factory/Containerfile" -t "$builder_image" "$repo_dir" >/dev/null

# The recipe goes in as an archive of the files git knows about (tracked, or
# new and not ignored), so caches and other local files never reach the
# package. The repository license sits beside the PKGBUILD.
# macOS's bsdtar also needs telling to leave out its AppleDouble metadata;
# GNU tar (a Linux builder) has no such option.
tar_flags=(--no-xattrs)
tar --version 2>/dev/null | grep -q 'GNU tar' || tar_flags+=(--no-mac-metadata)
recipe=$(mktemp -d "${TMPDIR:-/tmp}/try-omarchy-package.XXXXXX")
trap 'rm -rf "$recipe"' EXIT
(
  cd "$package_dir/try-omarchy"
  git ls-files -z --cached --others --exclude-standard -- . |
    while IFS= read -r -d '' file; do if [[ -e $file ]]; then printf '%s\0' "$file"; fi; done |
    COPYFILE_DISABLE=1 tar -c "${tar_flags[@]}" --null -T - -f "$recipe/recipe.tar"
)
COPYFILE_DISABLE=1 tar -r "${tar_flags[@]}" -f "$recipe/recipe.tar" -C "$repo_dir" LICENSE

# makepkg refuses root: build as an unprivileged user from a copy of the recipe.
docker run --rm -i --platform linux/arm64 --entrypoint /bin/bash \
  -v "$output:/output" "$builder_image" -c '
    set -euo pipefail
    useradd -m builder
    install -d -o builder /build/try-omarchy
    tar -x -C /build/try-omarchy --no-same-owner
    chown -R builder /build
    cd /build/try-omarchy
    # libfakeroot reports "payload not recognized" for the xattr calls some
    # container filesystems make; the package contents are unaffected.
    runuser -u builder -- env PKGEXT=.pkg.tar.zst makepkg --nodeps --force --noconfirm 2>&1 | grep -v "libfakeroot internal error" >&2
    rm -f /output/try-omarchy-*.pkg.tar.zst
    install -m 0644 try-omarchy-*.pkg.tar.zst /output/
    ls try-omarchy-*.pkg.tar.zst
  ' <"$recipe/recipe.tar"
