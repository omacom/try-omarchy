#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: register-native-battery-module.sh --root ROOT --work WORK --spec SPEC --pacman-config CONFIG

Packages the in-repo try-omarchy-battery DKMS sources as a reproducible pacman
package, installs it into the staged root (the DKMS transaction hook builds the
module against the pinned kernel), and stages the archive for the guest's
immutable local repository.
USAGE
}

fail() {
  echo "register-native-battery-module: $*" >&2
  exit 1
}

root=""
work=""
spec=""
pacman_config=""

while (($#)); do
  case "$1" in
    --root)
      root=${2:-}
      shift 2
      ;;
    --work)
      work=${2:-}
      shift 2
      ;;
    --spec)
      spec=${2:-}
      shift 2
      ;;
    --pacman-config)
      pacman_config=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ $root == /* && -d $root ]] || fail "--root must be an absolute staged root"
case "$root" in
  /|/bin|/boot|/etc|/home|/opt|/root|/usr|/var)
    fail "refusing unsafe root: $root"
    ;;
esac
[[ $work == /* && -d $work ]] || fail "--work must be an absolute directory"
[[ -f $spec ]] || fail "spec not found: $spec"
[[ -f $pacman_config ]] || fail "pacman config not found: $pacman_config"
root=$(cd "$root" && pwd -P)
work=$(cd "$work" && pwd -P)
case "$root" in
  /|/bin|/boot|/etc|/home|/opt|/root|/usr|/var)
    fail "refusing canonical unsafe root: $root"
    ;;
esac
[[ $root != "$work" && $work != "$root/"* ]] || fail "work directory must be outside the staged root"
[[ $root != *$'\n'* && $work != *$'\n'* ]] || fail "root and work paths cannot contain newlines"

for command in bsdtar find gzip install mount pacman python3 sha256sum sort tar touch umount zstd; do
  command -v "$command" >/dev/null || fail "$command is required"
done

guest_dir=$(cd "$(dirname "$0")/.." && pwd -P)
module_dir="$guest_dir/native-module/try-omarchy-battery"
for file in try-omarchy-battery.c Makefile dkms.conf; do
  [[ -f $module_dir/$file && ! -L $module_dir/$file ]] ||
    fail "module source is missing or unsafe: $file"
done

mapfile -t metadata < <(python3 - "$spec" <<'PY'
import json
import pathlib
import sys

spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
battery = spec["supplyChain"]["tryOmarchyBattery"]
print(battery["version"])
print(battery["pkgrel"])
print(battery["license"])
print(spec["image"]["sourceDateEpoch"])
PY
)
(( ${#metadata[@]} == 4 )) || fail "could not read the battery module contract"
version=${metadata[0]}
pkgrel=${metadata[1]}
license=${metadata[2]}
source_date_epoch=${metadata[3]}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid module version"
[[ $pkgrel =~ ^[1-9][0-9]*$ ]] || fail "invalid module pkgrel"
[[ $source_date_epoch =~ ^[0-9]+$ ]] || fail "invalid source date epoch"
grep -q "PACKAGE_VERSION=\"$version\"" "$module_dir/dkms.conf" ||
  fail "dkms.conf version does not match the spec pin"

package_name=try-omarchy-battery-dkms
package_version="$version-$pkgrel"
stage=$(mktemp -d "$work/battery-module.XXXXXX")
package_root="$stage/root"
source_target="usr/src/try-omarchy-battery-$version"
install -d -m 0755 "$package_root/$source_target"
for file in try-omarchy-battery.c Makefile dkms.conf; do
  install -m 0644 "$module_dir/$file" "$package_root/$source_target/$file"
done

installed_size=$(find "$package_root" -type f -exec wc -c {} + | awk 'END {print $1}')
cat >"$package_root/.PKGINFO" <<PKGINFO
pkgname = $package_name
pkgbase = $package_name
xdata = pkgtype=pkg
pkgver = $package_version
pkgdesc = Mirror the host Mac battery as guest BAT0/ADP0 (DKMS)
url = https://github.com/NimbleAINinja/try-omarchy
builddate = $source_date_epoch
packager = Try Omarchy reproducible guest builder
size = $installed_size
arch = aarch64
license = $license
depend = dkms
PKGINFO
chmod 0644 "$package_root/.PKGINFO"

find "$package_root" -exec touch -h -d "@$source_date_epoch" {} +
(
  cd "$package_root"
  LC_ALL=C find . -mindepth 1 ! -name .MTREE -print0 |
    LC_ALL=C sort -z |
    bsdtar -cnf - \
      --format=mtree \
      --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
      --no-recursion \
      --null \
      --files-from - |
    gzip -n -9 >.MTREE
)
chmod 0644 "$package_root/.MTREE"

package_archive="$stage/$package_name-$package_version-aarch64.pkg.tar.zst"
tar \
  --sort=name \
  --mtime="@$source_date_epoch" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --format=gnu \
  -C "$package_root" \
  -cf - .PKGINFO .MTREE usr |
  zstd --force --quiet -12 --threads=1 -o "$package_archive"

archive_query=$(pacman --config "$pacman_config" -Qp "$package_archive")
[[ $archive_query == "$package_name $package_version" ]] ||
  fail "battery module package identity mismatch: $archive_query"
# This is the first transaction whose hooks actually run programs inside the
# staged root: the DKMS hook compiles the module and mkinitcpio inspects the
# system. pacstrap has already torn down its own mounts, so give the hooks the
# API filesystems arch-chroot would have given them. Without this the hooks'
# `>/dev/null` materializes a stray regular file in the shipped rootfs and
# mkinitcpio aborts with "/proc must be mounted!".
api_mounts=()
unmount_api_filesystems() {
  local index
  for (( index = ${#api_mounts[@]} - 1; index >= 0; index-- )); do
    umount --recursive "${api_mounts[index]}" ||
      fail "could not unmount ${api_mounts[index]} from the staged root"
  done
  api_mounts=()
}
for directory in proc sys dev run; do
  [[ -d $root/$directory && ! -L $root/$directory ]] ||
    fail "staged root is missing its /$directory mount point"
done
trap 'unmount_api_filesystems' EXIT
mount -t proc -o nosuid,noexec,nodev proc "$root/proc"
api_mounts+=("$root/proc")
mount -t sysfs -o nosuid,noexec,nodev,ro sys "$root/sys"
api_mounts+=("$root/sys")
mount -t devtmpfs -o mode=0755,nosuid udev "$root/dev"
api_mounts+=("$root/dev")
mount -t tmpfs -o mode=0755,nosuid,nodev run "$root/run"
api_mounts+=("$root/run")

pacman \
  --noconfirm \
  --config "$pacman_config" \
  --root "$root" \
  --dbpath "$root/var/lib/pacman" \
  --logfile "$root/var/log/pacman.log" \
  -U "$package_archive"

unmount_api_filesystems
trap - EXIT

query=$(pacman --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" -Q "$package_name")
[[ $query == "$package_name $package_version" ]] ||
  fail "battery module package was not installed: $query"
pacman --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" -Qkk "$package_name" >/dev/null ||
  fail "installed battery module package failed its ownership check"

# The DKMS transaction hook must have produced the module for the pinned
# kernel. An empty glob here means the hook did not run or the compile failed.
built_module=$(find "$root/usr/lib/modules" -path '*/updates/dkms/try_omarchy_battery.ko*' -print -quit)
[[ -n $built_module ]] || fail "DKMS did not build try_omarchy_battery.ko"

repo_dir="$root/usr/share/try-omarchy/repo"
install -d -m 0755 "$repo_dir"
repo_archive="$repo_dir/$(basename "$package_archive")"
[[ ! -L $repo_archive ]] || fail "refusing symlinked immutable repository archive"
install -m 0644 "$package_archive" "$repo_archive"

echo "Registered $query and built $(basename "$built_module")"
