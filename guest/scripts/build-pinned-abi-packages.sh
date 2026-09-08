#!/bin/bash

# Rebuild the compatible aquamarine/Hyprtoolkit pair from verified source.
# Packages are exposed only through the disposable factory repository.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: build-pinned-abi-packages.sh --spec FILE --guest-dir DIR --output-repo DIR [--work DIR]
USAGE
}

fail() {
  echo "build-pinned-abi-packages: $*" >&2
  exit 1
}

spec=""
guest_dir=""
output_repo=""
work=""

while (($#)); do
  case "$1" in
    --spec)
      spec=${2:-}
      shift 2
      ;;
    --guest-dir)
      guest_dir=${2:-}
      shift 2
      ;;
    --output-repo)
      output_repo=${2:-}
      shift 2
      ;;
    --work)
      work=${2:-}
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

[[ -f $spec ]] || fail "spec not found: $spec"
[[ -d $guest_dir ]] || fail "guest directory not found: $guest_dir"
[[ -n $output_repo ]] || fail "--output-repo is required"
[[ $(uname -s) == Linux && $(uname -m) == aarch64 ]] \
  || fail "ABI pins must be built natively on aarch64 Linux"
(( EUID == 0 )) || fail "run as root so build dependencies can be installed"
for command in curl install makepkg pacman python3 repo-add runuser sha256sum tar useradd zstd; do
  command -v "$command" >/dev/null || fail "$command is required"
done

verify_file() {
  local expected=$1
  local path=$2
  printf '%s  %s\n' "$expected" "$path" | sha256sum -c - >/dev/null
}

if [[ -z $work ]]; then
  work=$(mktemp -d)
  chmod 0755 "$work"
  cleanup_work=1
else
  [[ $work == /* && -d $work ]] || fail "--work must be an absolute directory"
  cleanup_work=0
fi
stage=""
added_build_user=0
cleanup() {
  if (( added_build_user )); then
    userdel abi-build >/dev/null 2>&1 || true
  fi
  if [[ -n $stage && -d $stage && $stage == "$work/"abi-package.* ]]; then
    rm -rf -- "$stage"
  fi
  if (( cleanup_work )); then
    rm -rf -- "$work"
  fi
}
trap cleanup EXIT
install -d -m 0755 "$output_repo"
[[ -z $(ls -A "$output_repo") ]] || fail "output repository must be empty"

# Install build dependencies before either ABI pin. Hyprtoolkit then builds
# against our verified aquamarine, never the incompatible mirror package.
pacman -S --needed --noconfirm \
  base-devel cmake hyprutils hyprwayland-scanner libdisplay-info libdrm libglvnd \
  libinput mesa pixman seatd systemd-libs wayland wayland-protocols \
  cairo glib2 hyprgraphics hyprlang iniparser libxkbcommon pango >/dev/null

for name in aquamarine hyprtoolkit; do
  case "$name" in
    aquamarine) expected_version=0.14.0; expected_pkgrel=2 ;;
    hyprtoolkit) expected_version=0.5.4; expected_pkgrel=6.1 ;;
  esac
mapfile -t metadata < <(python3 - "$spec" "$guest_dir" "$name" <<'PY'
import json
import pathlib
import sys

spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
guest = pathlib.Path(sys.argv[2]).resolve(strict=True)
pins = spec.get("inputs", {}).get("abiPackagePins")
if pins != [{"name": "aquamarine", "version": "0.14.0-2"}, {"name": "hyprtoolkit", "version": "0.5.4-6.1"}]:
    raise SystemExit("abiPackagePins must contain the reviewed compatible pair")
component = spec["supplyChain"][sys.argv[3]]
required = (
    "version",
    "pkgrel",
    "repository",
    "url",
    "sha256",
    "pkgbuild",
    "pkgbuildSha256",
    "packagingRepository",
    "packagingCommit",
    "license",
    "binarySha256",
)
if set(component) != set(required):
    raise SystemExit("ABI component keys are not the reviewed set")
pkgbuild = pathlib.PurePosixPath(component["pkgbuild"])
if pkgbuild.is_absolute() or any(part in {"", ".", ".."} for part in pkgbuild.parts):
    raise SystemExit("ABI PKGBUILD path escapes the guest directory")
candidate = (guest / pathlib.Path(*pkgbuild.parts)).resolve(strict=True)
if candidate == guest or guest not in candidate.parents or not candidate.is_file():
    raise SystemExit("ABI PKGBUILD path is invalid")
print(component["version"])
print(component["pkgrel"])
print(component["repository"])
print(component["url"])
print(component["sha256"])
print(candidate)
print(component["pkgbuildSha256"])
print(component["packagingRepository"])
print(component["packagingCommit"])
print(component["license"])
print(component["binarySha256"])
print(spec["image"]["sourceDateEpoch"])
PY
) || fail "could not read pinned ABI metadata"
(( ${#metadata[@]} == 12 )) || fail "pinned ABI metadata is incomplete"

version=${metadata[0]}
pkgrel=${metadata[1]}
repository=${metadata[2]}
url=${metadata[3]}
sha256=${metadata[4]}
pkgbuild_path=${metadata[5]}
pkgbuild_sha256=${metadata[6]}
packaging_repository=${metadata[7]}
packaging_commit=${metadata[8]}
license=${metadata[9]}
binary_sha256=${metadata[10]}
source_date_epoch=${metadata[11]}

[[ $version == "$expected_version" ]] || fail "unexpected ABI component version: $version"
[[ $pkgrel == "$expected_pkgrel" ]] || fail "unexpected ABI component pkgrel: $pkgrel"
[[ $repository == "https://github.com/hyprwm/$name" ]] || fail "unexpected ABI component repository"
[[ $url == "$repository/archive/v$version/$name-$version.tar.gz" ]] ||
  fail "ABI source URL does not match the pinned release"
[[ $packaging_repository == "https://gitlab.archlinux.org/archlinux/packaging/packages/$name.git" ]] ||
  fail "unexpected ABI component packaging repository"
[[ $packaging_commit =~ ^[0-9a-f]{40}$ ]] || fail "invalid ABI packaging commit"
[[ $license == BSD-3-Clause ]] || fail "unexpected ABI component license: $license"
[[ $source_date_epoch =~ ^[0-9]+$ && $source_date_epoch -gt 0 ]] || fail "invalid source date epoch"
for digest in "$sha256" "$pkgbuild_sha256" "$binary_sha256"; do
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || fail "invalid ABI content digest"
done
[[ ! -L $pkgbuild_path ]] || fail "refusing symlinked ABI PKGBUILD"

verify_file "$pkgbuild_sha256" "$pkgbuild_path" || fail "ABI PKGBUILD digest mismatch"
grep -F "sha256sums=('$sha256')" "$pkgbuild_path" >/dev/null ||
  fail "ABI PKGBUILD does not pin the reviewed source digest"
grep -F "pkgver=$version" "$pkgbuild_path" >/dev/null || fail "ABI PKGBUILD version mismatch"
grep -F "pkgrel=$pkgrel" "$pkgbuild_path" >/dev/null || fail "ABI PKGBUILD pkgrel mismatch"

cache_dir="$work/$name-download-cache"
stage=$(mktemp -d "$work/abi-package.XXXXXX")
# makepkg runs as an unprivileged user and must traverse this parent.
chmod 0755 "$stage"
install -d -m 0755 "$cache_dir"
source_cache="$cache_dir/$name-$version.tar.gz"

download_verified() {
  local source_url=$1
  local expected=$2
  local destination=$3
  local temporary=""

  [[ ! -L $destination ]] || fail "refusing symlinked download cache entry: $destination"
  if [[ -f $destination ]] && verify_file "$expected" "$destination"; then
    return 0
  fi
  rm -f -- "$destination"
  temporary=$(mktemp "$cache_dir/.download.XXXXXX")
  if ! curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
    "$source_url" --output "$temporary"; then
    rm -f -- "$temporary"
    fail "download failed: $source_url"
  fi
  if ! verify_file "$expected" "$temporary"; then
    rm -f -- "$temporary"
    fail "download digest mismatch: $source_url"
  fi
  chmod 0644 "$temporary"
  mv "$temporary" "$destination"
}

download_verified "$url" "$sha256" "$source_cache"

python3 - "$source_cache" "$name-$version" <<'PY' || fail "ABI source archive has an unsafe member set"
import pathlib
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])
expected_root = sys.argv[2]
with tarfile.open(archive, "r:gz") as source:
    members = source.getmembers()
    if not members:
        raise SystemExit("ABI source archive is empty")
    for member in members:
        name = member.name[:-1] if member.isdir() and member.name.endswith("/") else member.name
        if not name or name.startswith("/") or ".." in pathlib.PurePosixPath(name).parts:
            raise SystemExit(f"unsafe ABI source member: {member.name}")
    roots = {pathlib.PurePosixPath(member.name).parts[0] for member in members if member.name}
    if roots != {expected_root}:
        raise SystemExit("ABI source archive has an unexpected member set")
PY

if ! id -u abi-build >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$stage/home" --shell /usr/bin/nologin \
    abi-build
  added_build_user=1
else
  added_build_user=0
fi
build_home=$(getent passwd abi-build | cut -d: -f6)
build_dir="$stage/build"
install -d -m 0755 -o abi-build -g abi-build "$build_dir" "$build_home"
install -m 0644 -o abi-build -g abi-build "$pkgbuild_path" "$build_dir/PKGBUILD"
install -m 0644 -o abi-build -g abi-build "$source_cache" \
  "$build_dir/$name-$version.tar.gz"

runuser -u abi-build -- test -w "$build_dir" || fail "build user cannot access $build_dir"
makepkg_config="$stage/makepkg.conf"
cp /etc/makepkg.conf "$makepkg_config"
printf '\nCFLAGS+=" -ffile-prefix-map=%s=/usr/src/try-omarchy-%s"\nCXXFLAGS+=" -ffile-prefix-map=%s=/usr/src/try-omarchy-%s"\nOPTIONS+=(!debug)\nPKGEXT=\".pkg.tar.zst\"\n' \
  "$stage" "$name" "$stage" "$name" >> "$makepkg_config"

export SOURCE_DATE_EPOCH="$source_date_epoch"
export PACKAGER='Try Omarchy factory <factory@try-omarchy>'
(
  cd "$build_dir"
  runuser -u abi-build -- env HOME="$build_home" SOURCE_DATE_EPOCH="$source_date_epoch" \
    PACKAGER="$PACKAGER" CMAKE_BUILD_PARALLEL_LEVEL=4 \
    makepkg --config "$makepkg_config" --noconfirm --skippgpcheck
)

package_archive="$build_dir/$name-$version-$pkgrel-aarch64.pkg.tar.zst"
[[ -f $package_archive ]] || fail "makepkg did not produce $package_archive"

python3 - "$package_archive" "$binary_sha256" "$name" "$version" "$pkgrel" <<'PY' || fail "ABI package provenance mismatch"
import hashlib
import io
import subprocess
import sys
import tarfile

archive = sys.argv[1]
expected = sys.argv[2]
name, version, pkgrel = sys.argv[3:]
raw = subprocess.check_output(["zstd", "-d", "-c", archive])
with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as package:
    info = package.extractfile(".PKGINFO")
    if info is None:
        raise SystemExit("ABI package is missing .PKGINFO")
    pkginfo = info.read().decode()
    if f"pkgname = {name}\n" not in pkginfo or f"pkgver = {version}-{pkgrel}\n" not in pkginfo or "arch = aarch64\n" not in pkginfo:
        raise SystemExit("ABI package identity mismatch")
    abi = "provides = libaquamarine.so=13-64" if name == "aquamarine" else "depend = libaquamarine.so=13-64"
    if abi not in pkginfo:
        raise SystemExit("ABI package does not provide or depend on libaquamarine.so=13")
    member = package.extractfile(f"usr/lib/lib{name}.so.{version}")
    if member is None:
        raise SystemExit("ABI package is missing its versioned library")
    digest = hashlib.sha256(member.read()).hexdigest()
    if digest != expected:
        raise SystemExit(f"{name} reproducible library digest mismatch: {digest}")
PY

install -m 0644 "$package_archive" "$output_repo/$name-$version-$pkgrel-aarch64.pkg.tar.zst"
if [[ $name == aquamarine ]]; then
  pacman -U --needed --noconfirm "$package_archive" >/dev/null
fi
if (( added_build_user )); then
  userdel abi-build
  added_build_user=0
fi
rm -rf -- "$stage"
stage=""
echo "Rebuilt $name $version-$pkgrel from $packaging_commit (library $binary_sha256)"
done
repo-add "$output_repo/try-omarchy-abi-pins.db.tar.gz" "$output_repo/"*.pkg.tar.zst >/dev/null
