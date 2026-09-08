#!/bin/bash
# Paired virtual HDR driver and private mpv renderer, built against the guest ABI.
set -euo pipefail
fail() { echo "register-native-hdr: $*" >&2; exit 1; }
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
[[ $root == /* && -d $root && $work == /* && -d $work ]] || fail "absolute root and work directories required"
root=$(realpath "$root"); work=$(realpath "$work")
case "$root" in /|/bin|/boot|/etc|/home|/opt|/root|/usr|/var) fail "unsafe staged root" ;; esac
[[ $root != "$work" && $work != "$root/"* ]] || fail "work must be outside staged root"
[[ -f $spec && -f $pacman_config ]] || fail "spec and pacman config required"
[[ -z $output || ( $output == /* && ! -L $output ) ]] || fail "invalid output path"
[[ $(uname -s) == Linux && $(uname -m) == aarch64 ]] || fail "native Linux ARM64 builder required"
guest=$(cd "$(dirname "$0")/.." && pwd -P)
hdr="$guest/hdr"
build=$(mktemp -d "$work/native-hdr-build.XXXXXX")
trap 'rm -rf "$build"' EXIT
stage="$build/package"
mkdir -p "$stage" "$work/download-cache"
python3 - "$hdr" "$spec" "$work/download-cache" "$build" <<'PYTHON'
import hashlib, json, pathlib, subprocess, sys
hdr, spec_path, cache, build = map(pathlib.Path, sys.argv[1:])
spec = json.loads(spec_path.read_text())
meta = json.loads((hdr/'sources.json').read_text())
assert spec['image']['architecture'] == 'aarch64'
assert (meta['version'], meta['kernelVersion'], meta['kernelRelease']) == ('1.0.0', '7.2.2', '7.2.2-2-aarch64-ARCH')
assert meta['linuxBaseUrl'] == 'https://raw.githubusercontent.com/gregkh/linux/v7.2.2/drivers/gpu/drm/virtio/'
assert set(meta['patches']) == {'virtio-gpu-hdr.patch', 'mesa-es3-norm16.patch', 'mpv-wayland-color.patch'}
def verify(path, digest):
    return path.is_file() and not path.is_symlink() and hashlib.sha256(path.read_bytes()).hexdigest() == digest
assert verify(hdr/'linux-source-sha256.json', meta['linuxManifestSha256'])
for name, digest in meta['patches'].items():
    assert verify(hdr/name, digest), name
linux = json.loads((hdr/'linux-source-sha256.json').read_text())
assert len(linux) == 17
def fetch(name, url, digest):
    target = cache/name
    if target.is_symlink():
        raise SystemExit('symlinked source cache entry')
    if not verify(target, digest):
        tmp = build/(name+'.download')
        subprocess.run(['curl', '--fail', '--location', '--retry', '2', '--proto', '=https', '--tlsv1.2',
                        '--silent', '--show-error', url, '-o', str(tmp)], check=True)
        if not verify(tmp, digest):
            raise SystemExit('source digest mismatch: '+name)
        tmp.replace(target)
    return target
kernel = build/'kernel'; kernel.mkdir()
for name, digest in linux.items():
    assert pathlib.Path(name).name == name
    source = fetch('linux-7.2.2-'+name, meta['linuxBaseUrl']+name, digest)
    (kernel/name).write_bytes(source.read_bytes())
fetch('mesa-26.2.1.tar.xz', meta['mesa']['url'], meta['mesa']['sha256'])
fetch('mpv-0.41.0.tar.gz', meta['mpv']['url'], meta['mpv']['sha256'])
(build/'epoch').write_text(str(spec['image']['sourceDateEpoch']))
(build/'build-packages').write_text('\n'.join(n+'='+v for n,v in sorted(meta['buildPackages'].items()))+'\n')
PYTHON
kernel_release=7.2.2-2-aarch64-ARCH
kernel_headers="$root/usr/lib/modules/$kernel_release/build"
[[ $(cat "$kernel_headers/include/config/kernel.release") == "$kernel_release" ]] || fail "matching kernel headers required"
# Extra generators belong to the disposable builder, not the staged guest.
python3 - "$pacman_config" "$build/pacman.conf" <<'PYTHON'
import pathlib, sys
lines = []; section = ''
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line.startswith('[') and line.endswith(']'):
        section = line[1:-1]
    if section == 'omarchy' or line.startswith('IgnorePkg'):
        continue
    lines.append(line)
pathlib.Path(sys.argv[2]).write_text('\n'.join(lines)+'\n')
PYTHON
mapfile -t extra_packages <"$build/build-packages"
pacman --noconfirm --config "$build/pacman.conf" -S --needed "${extra_packages[@]}"
for package in "${extra_packages[@]}"; do
  [[ $(pacman -Q "${package%%=*}") == "${package/=/ }" ]] || fail "build package version mismatch"
done
for command in meson ninja gcc g++ make pkg-config patch tar bsdtar gzip zstd readelf; do
  command -v "$command" >/dev/null || fail "missing build tool: $command"
done
jobs=${OMARCHY_GUEST_BUILD_JOBS:-$(nproc)}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || fail "invalid build job count"
export SOURCE_DATE_EPOCH=$(cat "$build/epoch")
patch -d "$build/kernel" -p1 --batch --fuzz=0 <"$hdr/virtio-gpu-hdr.patch"
make -C "$kernel_headers" M="$build/kernel" -j"$jobs" modules
install -Dm644 "$build/kernel/virtio-gpu.ko" "$stage/usr/lib/modules/$kernel_release/updates/omarchy-hdr/virtio-gpu.ko"
export PKG_CONFIG_SYSROOT_DIR="$root"
export PKG_CONFIG_LIBDIR="$root/usr/lib/pkgconfig:$root/usr/share/pkgconfig"
python3 - "$build" "$root" <<'PYTHON'
import pathlib, shlex, sys
build, root = map(pathlib.Path, sys.argv[1:])
for name, compiler in [('cc','gcc'), ('cxx','g++')]:
    path = build/name
    # Meson may pass a sysroot library by absolute filename. Libraries without
    # DT_SONAME (notably mujs) would then retain the build directory in DT_NEEDED.
    path.write_text('#!/bin/bash\nroot='+shlex.quote(str(root))+'''\nargs=()
for argument; do
  case "$argument" in
    "$root"/*.so) args+=("-L${argument%/*}" "-l:${argument##*/}") ;;
    *) args+=("$argument") ;;
  esac
done
exec '''+compiler+' --sysroot="$root" "${args[@]}"\n')
    path.chmod(0o755)
(build/'native.ini').write_text('[binaries]\nc = '+repr(str(build/'cc'))+'\ncpp = '+repr(str(build/'cxx'))+'\n')
PYTHON
tar -xJf "$work/download-cache/mesa-26.2.1.tar.xz" --no-same-owner -C "$build"
tar -xzf "$work/download-cache/mpv-0.41.0.tar.gz" --no-same-owner -C "$build"
patch -d "$build/mesa-26.2.1" -p1 --batch --fuzz=0 <"$hdr/mesa-es3-norm16.patch"
patch -d "$build/mpv-0.41.0" -p1 --batch --fuzz=0 <"$hdr/mpv-wayland-color.patch"
meson setup "$build/mesa-build" "$build/mesa-26.2.1" --native-file "$build/native.ini" \
  --prefix=/usr/local/lib/omarchy-hdr/mesa --libdir=lib --buildtype=release \
  -Dgallium-drivers=virgl -Dvulkan-drivers=[] -Dplatforms=wayland,x11 \
  -Dglx=dri -Degl=enabled -Dgbm=enabled -Dglvnd=enabled -Dllvm=disabled \
  -Dgallium-va=disabled -Dvideo-codecs=[] -Dbuild-tests=false \
  -Dopengl=true -Dgles2=enabled -Dgles1=disabled -Ddraw-use-llvm=false -Dvalgrind=disabled
ninja -C "$build/mesa-build" -j"$jobs"
DESTDIR="$stage" meson install -C "$build/mesa-build" --no-rebuild
meson setup "$build/mpv-build" "$build/mpv-0.41.0" --native-file "$build/native.ini" \
  --prefix=/usr/local/lib/omarchy-hdr/mpv --buildtype=release \
  -Dlibmpv=false -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled \
  -Dwayland=enabled -Degl-wayland=enabled -Dvaapi=enabled -Dpipewire=enabled
ninja -C "$build/mpv-build" -j"$jobs"
install -Dm755 "$build/mpv-build/mpv" "$stage/usr/local/lib/omarchy-hdr/mpv/bin/mpv"
python3 - "$stage/usr/local/lib/omarchy-hdr" "$root" "$build" <<'PYTHON'
import pathlib, re, subprocess, sys
runtime = pathlib.Path(sys.argv[1])
for binary in sorted(runtime.rglob('*')):
    if not binary.is_file() or binary.is_symlink():
        continue
    with binary.open('rb') as stream:
        if stream.read(4) != b'\x7fELF':
            continue
    dynamic = subprocess.check_output(['readelf', '-d', str(binary)], text=True)
    for needed in re.findall(r'\(NEEDED\).*?\[([^\]]+)\]', dynamic):
        if '/' in needed:
            raise SystemExit(f'build-path runtime dependency in {binary}: {needed}')
    for search in re.findall(r'\((?:RPATH|RUNPATH)\).*?\[([^\]]+)\]', dynamic):
        if any(path in search for path in sys.argv[2:]):
            raise SystemExit(f'build-path runtime search in {binary}: {search}')
PYTHON
install -m644 "$hdr/environment.sh" "$stage/usr/local/lib/omarchy-hdr/environment.sh"
sources="$stage/usr/share/try-omarchy/native-hdr-source"
licenses="$stage/usr/share/licenses/try-omarchy-native-hdr"
mkdir -p "$sources/linux-7.2.2-virtio" "$licenses"
cp "$work/download-cache/mesa-26.2.1.tar.xz" "$work/download-cache/mpv-0.41.0.tar.gz" "$sources/"
cp -a "$hdr" "$sources/"
cp "$0" "$sources/register-native-hdr.sh"
python3 - "$hdr/linux-source-sha256.json" "$work/download-cache" "$sources/linux-7.2.2-virtio" <<'PYTHON'
import json, pathlib, sys
manifest, cache, output = map(pathlib.Path, sys.argv[1:])
for name in json.loads(manifest.read_text()):
    (output/name).write_bytes((cache/('linux-7.2.2-'+name)).read_bytes())
PYTHON
cp "$build/mpv-0.41.0/LICENSE.GPL" "$licenses/GPL-2.0"
cp "$build/mpv-0.41.0/LICENSE.LGPL" "$licenses/LGPL-2.1"
cp "$build/mesa-26.2.1/docs/license.rst" "$licenses/Mesa-license-notices"
cp "$guest/../LICENSE" "$licenses/Try-Omarchy-MIT"
install -m644 "$hdr/package.install" "$stage/.INSTALL"
python3 - "$stage" "$hdr" <<'PYTHON'
import hashlib, json, pathlib, sys
stage, hdr = map(pathlib.Path, sys.argv[1:])
record = {'sources': json.loads((hdr/'sources.json').read_text()),
          'binarySha256': {str(p.relative_to(stage)): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in sorted((stage/'usr').rglob('*')) if p.is_file() and not p.is_symlink()
                          and (p.suffix == '.ko' or '.so' in p.name or p.name == 'mpv')}}
(stage/'usr/share/try-omarchy/native-hdr.json').write_text(json.dumps(record, indent=2)+'\n')
PYTHON
size=$(du -sb "$stage" | awk '{print $1}')
cat >"$stage/.PKGINFO" <<EOF
pkgname = try-omarchy-native-hdr
pkgbase = try-omarchy-native-hdr
pkgver = 1.0.0-1
pkgdesc = Paired virtual HDR display driver and private mpv rendering runtime
url = https://github.com/omacom/try-omarchy
builddate = $SOURCE_DATE_EPOCH
packager = Try Omarchy reproducible guest builder
size = $size
arch = aarch64
license = GPL-2.0-only
license = GPL-2.0-or-later
license = MIT
depend = mpv
depend = mesa
depend = try-omarchy-native-video
EOF
find "$stage" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
(
  cd "$stage"
  find . -mindepth 1 ! -name .MTREE -print0 | LC_ALL=C sort -z |
    bsdtar -cnf - --format=mtree --uid 0 --gid 0 \
      --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
      --no-recursion --null --files-from - | gzip -n -9 >.MTREE
)
package="$build/try-omarchy-native-hdr-1.0.0-1-aarch64.pkg.tar.zst"
tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner --format=gnu \
  -C "$stage" -cf - .PKGINFO .INSTALL .MTREE usr | zstd --quiet -12 --threads=1 -o "$package"
if [[ -n $output ]]; then
  install -m644 "$package" "$output"
  echo "Built native HDR package: $output"
  exit 0
fi
pacman --noconfirm --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" \
  --logfile "$root/var/log/pacman.log" -U "$package"
install -Dm644 "$package" "$root/usr/share/try-omarchy/repo/$(basename "$package")"
echo "Registered native HDR 1.0.0 for kernel $kernel_release"
