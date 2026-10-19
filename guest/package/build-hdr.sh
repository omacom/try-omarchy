#!/bin/bash
# Build the pinned Hyprland HDR companion using the normal ARM64 builder.
set -euo pipefail
package_dir=$(cd "$(dirname "$0")" && pwd)
output=""
[[ $# == 2 && $1 == --output ]] || { echo 'Usage: build-hdr.sh --output DIR' >&2; exit 64; }
output=$2
mkdir -p "$output/hdr-packages"
output=$(cd "$output" && pwd)
builder_image=${GUEST_HDR_BUILDER_IMAGE:-${GUEST_BUILDER_IMAGE:-try-omarchy-guest-builder}}
if command -v sha256sum >/dev/null 2>&1; then
  checksum=(sha256sum)
else
  checksum=(shasum -a 256)
fi
write_contract() {
  local archive name version
  local archives=("$output/hdr-packages/"hyprland-*.pkg.tar.zst)
  ((${#archives[@]} == 1)) || { echo 'HDR: expected one built compositor' >&2; exit 1; }
  name=$(basename "${archives[0]}")
  version=${name#hyprland-}; version=${version%-aarch64.pkg.tar.zst}
  printf 'hyprland %s\n' "$version" > "$output/hdr-packages/version"
  (cd "$output/hdr-packages" && "${checksum[@]}" hyprland-*.pkg.tar.zst version > SHA256SUMS)
}
cache_key=$(python3 - "$package_dir/hdr-hyprland" "$(docker image inspect --format '{{.Id}}' "$builder_image")" <<'HASH'
import hashlib, pathlib, sys
h=hashlib.sha256(sys.argv[2].encode())
for p in sorted(pathlib.Path(sys.argv[1]).iterdir()):
    if p.is_file(): h.update(p.name.encode()); h.update(p.read_bytes())
print(h.hexdigest())
HASH
)
cache="$package_dir/../../.build/hdr-hyprland/$cache_key"
if [[ ${OMARCHY_FORCE_BUILD:-0} != 1 && -f $cache/SHA256SUMS ]] &&
  (cd "$cache" && "${checksum[@]}" -c SHA256SUMS >/dev/null); then
  install -m0644 "$cache/"* "$output/hdr-packages/"
  write_contract
  exit 0
fi
docker run --rm --platform linux/arm64 --entrypoint /bin/bash \
  -v "$package_dir/hdr-hyprland:/recipe:ro" -v "$output/hdr-packages:/output" \
  "$builder_image" -c '
    set -euo pipefail
    install -d /hdrbuild
    cp -a /recipe/. /hdrbuild/
    cd /hdrbuild
    if ! grep -q "^\[omarchy\]" /etc/pacman.conf; then
      printf "\n[omarchy]\nServer = https://pkgs.omarchy.org/edge/\$arch\n" >> /etc/pacman.conf
    fi
    pacman-key --populate omarchy >/dev/null
    source PKGBUILD
    pacman -Syu --needed --noconfirm "${depends[@]}" "${makedepends[@]}"
    id builder >/dev/null 2>&1 || useradd -m builder
    chown -R builder:builder /hdrbuild
    runuser -u builder -- env PKGEXT=.pkg.tar.zst CMAKE_BUILD_PARALLEL_LEVEL=4 MAKEFLAGS=-j4 makepkg --nodeps --noconfirm
    install -m0644 hyprland-*.pkg.tar.zst /output/
  '

write_contract
mkdir -p "$cache"
install -m0644 "$output/hdr-packages/"* "$cache/"
