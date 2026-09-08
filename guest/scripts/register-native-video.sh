#!/bin/bash
# Build the Linux side of the VideoToolbox bridge against the staged guest ABI.
set -euo pipefail
fail() { echo "register-native-video: $*" >&2; exit 1; }
root= work= spec= pacman_config= output=
while (($#)); do
  case "$1" in
    --root) root=${2:-}; shift 2 ;;
    --work) work=${2:-}; shift 2 ;;
    --spec) spec=${2:-}; shift 2 ;;
    --pacman-config) pacman_config=${2:-}; shift 2 ;;
    --output) output=${2:-}; shift 2 ;;
    *) fail "unknown option: $1" ;;
  esac
done
[[ $root == /* && -d $root && $work == /* && -d $work ]] || fail "absolute root and work directories are required"
root=$(realpath "$root"); work=$(realpath "$work")
case "$root" in /|/bin|/boot|/etc|/home|/opt|/root|/usr|/var) fail "unsafe staged root" ;; esac
[[ $root != "$work" && $work != "$root/"* ]] || fail "work must be outside the staged root"
[[ -f $spec && -f $pacman_config ]] || fail "spec and pacman config are required"
[[ -z $output || ( $output == /* && ! -L $output ) ]] || fail "output must be an absolute non-symlink path"
[[ $(uname -m) == aarch64 && $(uname -s) == Linux ]] || fail "native Linux ARM64 builder required"
guest_dir=$(cd "$(dirname "$0")/.." && pwd -P)
metadata=$(python3 - "$spec" "$guest_dir" <<'PY'
import hashlib, json, pathlib, sys
s = json.loads(pathlib.Path(sys.argv[1]).read_text())
c = s['supplyChain']['nativeVideo']
expected = dict(version='1.0.0', ffmpegVersion='9.0.1',
 ffmpegUrl='https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz',
 ffmpegSha256='cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635',
 patch='video/ffmpeg-full-bitstream.patch',
 patchSha256='57301544bb9fd26bf50b1cc07288b58257201993e73bd71d53513045815a325a',
 license='GPL-3.0-or-later')
if c != expected or s['image']['architecture'] != 'aarch64':
 raise SystemExit('unreviewed native video supply chain')
patch = pathlib.Path(sys.argv[2]) / c['patch']
if hashlib.sha256(patch.read_bytes()).hexdigest() != c['patchSha256']:
 raise SystemExit('native video patch digest mismatch')
for key in ('version', 'ffmpegVersion', 'ffmpegUrl', 'ffmpegSha256'):
 print(c[key])
print(s['image']['sourceDateEpoch'])
PY
) || fail "invalid native video metadata"
mapfile -t values <<<"$metadata"
version=${values[0]}; ffmpeg_version=${values[1]}; url=${values[2]}; digest=${values[3]}; epoch=${values[4]}
for command in gcc g++ make pkg-config patch curl bsdtar gzip tar zstd pacman sha256sum; do
  command -v "$command" >/dev/null || fail "missing build tool: $command"
done

cache="$work/download-cache"
install -d -m 0755 "$cache"
archive="$cache/ffmpeg-$ffmpeg_version.tar.xz"
[[ ! -L $archive ]] || fail "symlinked FFmpeg cache entry"
verify_archive() { printf '%s  %s\n' "$digest" "$1" | sha256sum -c - >/dev/null; }
if [[ ! -f $archive ]] || ! verify_archive "$archive"; then
  temporary=$(mktemp "$cache/.ffmpeg.XXXXXX")
  if ! curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error "$url" -o "$temporary" ||
     ! verify_archive "$temporary"; then
    rm -f "$temporary"; fail "FFmpeg download or digest verification failed"
  fi
  chmod 0644 "$temporary"; mv "$temporary" "$archive"
fi
build=$(mktemp -d "$work/native-video-build.XXXXXX")
trap 'rm -rf "$build"' EXIT
stage="$build/package"
mkdir -p "$stage"
tar -xJf "$archive" --no-same-owner -C "$build"
source_dir="$build/ffmpeg-$ffmpeg_version"
patch -d "$source_dir" -p1 --batch --fuzz=0 <"$guest_dir/video/ffmpeg-full-bitstream.patch"

# Hyprland's preceding build installs the reviewed compiler toolchain. Resolve
# every media header and library against this exact guest, not builder packages.
export PKG_CONFIG_SYSROOT_DIR="$root"
export PKG_CONFIG_LIBDIR="$root/usr/lib/pkgconfig:$root/usr/share/pkgconfig"
python3 - "$build" "$root" <<'PY'
import pathlib, shlex, sys
for name, compiler in [('cc', 'gcc'), ('cxx', 'g++')]:
 p = pathlib.Path(sys.argv[1]) / name
 p.write_text('#!/bin/sh\nexec '+compiler+' '+shlex.quote('--sysroot='+sys.argv[2])+' "$@"\n')
 p.chmod(0o755)
PY
jobs=${OMARCHY_GUEST_BUILD_JOBS:-$(nproc)}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || fail "invalid build job count"
(
  cd "$source_dir"
  ./configure --prefix=/usr/local/lib/omarchy-video/ffmpeg \
    --cc="$build/cc" --cxx="$build/cxx" \
    --enable-shared --disable-static --disable-doc --disable-programs --disable-debug \
    --disable-autodetect --enable-gpl --enable-version3 --enable-vaapi --enable-libdrm \
    --enable-libdav1d --enable-libvpx --enable-libx264 --enable-libx265 --disable-x86asm
  make -j"$jobs"
  make DESTDIR="$stage" install
)
install -d "$stage/usr/local/libexec" "$stage/usr/lib/dri" "$stage/usr/local/lib/omarchy-video" \
  "$stage/usr/local/bin" "$stage/usr/lib/systemd/system" \
  "$stage/etc/systemd/system/multi-user.target.wants" \
  "$stage/usr/lib/firefox/defaults/pref" "$stage/usr/share/applications"
"$build/cxx" -std=c++17 -O2 -pthread "$guest_dir/video/broker.cpp" -o "$stage/usr/local/libexec/omarchy-video-broker"
"$build/cxx" -std=c++17 -O2 -shared -fPIC -pthread \
  "$guest_dir/video/driver.cpp" -o "$stage/usr/lib/dri/omarchy_drv_video.so" \
  $(pkg-config --cflags --libs libva gbm libdrm)
"$build/cxx" -std=c++17 -O2 -shared -fPIC -pthread \
  "$guest_dir/video/firefox-video-bootstrap.cpp" -o "$stage/usr/local/lib/omarchy-video/firefox-video-bootstrap.so"
"$build/cc" -O2 -shared -fPIC -pthread "$guest_dir/video/arm64-browser-compat.c" \
  -o "$stage/usr/local/lib/omarchy-video/arm64-browser-compat.so" -ldl
install -m 0644 "$guest_dir/video/environment.sh" "$guest_dir/video/vivaldi.sh" "$stage/usr/local/lib/omarchy-video/"
install -m 0755 "$guest_dir/video/mpv" "$guest_dir/video/firefox" "$stage/usr/local/bin/"
install -m 0644 "$guest_dir/video/firefox-prefs.js" "$stage/usr/lib/firefox/defaults/pref/try-omarchy-video.js"
install -m 0644 "$guest_dir/video/omarchy-video-firefox.desktop" "$stage/usr/share/applications/"
install -m 0644 "$guest_dir/video/omarchy-video-broker.service" "$stage/usr/lib/systemd/system/"
ln -s /usr/lib/systemd/system/omarchy-video-broker.service \
  "$stage/etc/systemd/system/multi-user.target.wants/omarchy-video-broker.service"

# Ship corresponding source and the exact local patch/build recipe with the
# private FFmpeg libraries. System FFmpeg and its linker configuration stay owned
# by Arch and continue to update normally.
sources="$stage/usr/share/try-omarchy/native-video-source"
licenses="$stage/usr/share/licenses/try-omarchy-native-video"
install -d "$sources" "$licenses"
install -m 0644 "$archive" "$sources/"
cp -a "$guest_dir/video" "$sources/"
install -m 0644 "$0" "$sources/register-native-video.sh"
install -m 0644 "$source_dir/COPYING.GPLv3" "$licenses/FFmpeg-GPL-3.0"
install -m 0644 "$guest_dir/../LICENSE" "$licenses/Try-Omarchy-MIT"
python3 - "$stage" "$spec" "$guest_dir" <<'PY'
import hashlib, json, pathlib, sys
stage, spec, guest = map(pathlib.Path, sys.argv[1:])
record = {'supplyChain': json.loads(spec.read_text())['supplyChain']['nativeVideo'],
 'sourceSha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((guest/'video').iterdir()) if p.is_file()},
 'binarySha256': {str(p.relative_to(stage)): hashlib.sha256(p.read_bytes()).hexdigest()
  for p in sorted(stage.rglob('*')) if p.is_file() and not p.is_symlink() and
  (p.suffix == '.so' or p.name == 'omarchy-video-broker' or '.so.' in p.name)}}
(stage/'usr/share/try-omarchy/native-video.json').write_text(json.dumps(record, indent=2)+'\n')
PY
size=$(du -sb "$stage" | awk '{print $1}')
cat >"$stage/.PKGINFO" <<EOF
pkgname = try-omarchy-native-video
pkgbase = try-omarchy-native-video
pkgver = $version-1
pkgdesc = VA-API bridge to the Mac VideoToolbox hardware decoder
url = https://github.com/omacom/try-omarchy
builddate = $epoch
packager = Try Omarchy reproducible guest builder
size = $size
arch = aarch64
license = MIT
license = GPL-3.0-or-later
depend = glibc
depend = gcc-libs
depend = libva
depend = libdrm
depend = mesa
depend = dav1d
depend = libvpx
depend = x264
depend = x265
optdepend = firefox: HEVC browser playback
optdepend = vivaldi: accelerated YouTube playback
optdepend = mpv: accelerated video playback
EOF
find "$stage" -exec touch -h -d "@$epoch" {} +
(
  cd "$stage"
  find . -mindepth 1 ! -name .MTREE -print0 | LC_ALL=C sort -z |
    bsdtar -cnf - --format=mtree --uid 0 --gid 0 \
      --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
      --no-recursion --null --files-from - | gzip -n -9 >.MTREE
)
package="$build/try-omarchy-native-video-$version-1-aarch64.pkg.tar.zst"
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner --format=gnu \
  -C "$stage" -cf - .PKGINFO .MTREE usr etc | zstd --quiet -12 --threads=1 -o "$package"
if [[ -n $output ]]; then
  install -m 0644 "$package" "$output"
  echo "Built native video package: $output"
  exit 0
fi
pacman --noconfirm --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" \
  --logfile "$root/var/log/pacman.log" -U "$package"
pacman --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" -Qkk try-omarchy-native-video
install -d "$root/usr/share/try-omarchy/repo"
install -m 0644 "$package" "$root/usr/share/try-omarchy/repo/"
echo "Registered native video $version with private FFmpeg $ffmpeg_version"
