#!/bin/bash
#
# Stages the edk2 UEFI firmware that upstream-shell VMs boot through, taken
# from the same pinned QEMU source archive as the runtime
# (build-qemu-gpu-runtime.sh): pc-bios/edk2-aarch64-code.fd.bz2 and its
# license. Output: macos/.build/firmware/.
#
#   macos/stage-uefi-firmware.sh [--archive-dir DIR]

set -euo pipefail

die() {
  echo "stage-uefi-firmware: $*" >&2
  exit 1
}

native_dir=$(cd "$(dirname "$0")" && pwd)
output="$native_dir/.build/firmware"
archive_cache=""
case ${1:-} in
  --archive-dir) archive_cache=${2:?}; shift 2 ;;
  '') ;;
  *) die "usage: $0 [--archive-dir DIR]" ;;
esac

# Keep in step with build-qemu-gpu-runtime.sh.
qemu_commit=$(sed -n 's/^qemu_commit=\([0-9a-f]\{40\}\)$/\1/p' "$native_dir/build-qemu-gpu-runtime.sh")
qemu_sha256=$(sed -n 's/^qemu_sha256=\([0-9a-f]\{64\}\)$/\1/p' "$native_dir/build-qemu-gpu-runtime.sh")
[[ -n $qemu_commit && -n $qemu_sha256 ]] || die "cannot read the pinned QEMU source from build-qemu-gpu-runtime.sh"
archive_name="qemu-$qemu_commit.tar.gz"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
archive="$scratch/$archive_name"
if [[ -n $archive_cache && -f $archive_cache/$archive_name ]]; then
  cp "$archive_cache/$archive_name" "$archive"
else
  curl -fsSL "https://gitlab.com/qemu-project/qemu/-/archive/$qemu_commit/$archive_name" -o "$archive"
fi
[[ $(shasum -a 256 "$archive" | cut -d' ' -f1) == "$qemu_sha256" ]] || die "the QEMU source archive does not match its pin"

tar -xzf "$archive" -C "$scratch" "qemu-$qemu_commit/pc-bios/edk2-aarch64-code.fd.bz2" "qemu-$qemu_commit/pc-bios/edk2-licenses.txt"
mkdir -p "$output"
bunzip2 -c "$scratch/qemu-$qemu_commit/pc-bios/edk2-aarch64-code.fd.bz2" >"$output/edk2-aarch64-code.fd.partial"
[[ $(stat -f %z "$output/edk2-aarch64-code.fd.partial") == 67108864 ]] || die "the firmware is not a 64 MiB flash image"
mv -f "$output/edk2-aarch64-code.fd.partial" "$output/edk2-aarch64-code.fd"
install -m 0644 "$scratch/qemu-$qemu_commit/pc-bios/edk2-licenses.txt" "$output/edk2-licenses.txt"
chmod 0644 "$output/edk2-aarch64-code.fd"
(cd "$output" && shasum -a 256 edk2-aarch64-code.fd edk2-licenses.txt >SHA256SUMS)
echo "UEFI firmware staged in $output"
