#!/bin/bash
#
# Launches the Omarchy VM: a stock aarch64 Omarchy install that owns its boot
# (edk2 UEFI firmware on pflash → Limine → the guest's own UKI). See
# docs/architecture.md.
#
#   run-qemu-gpu.sh [--ephemeral | --reset-storage | --reset-storage-only] [GUEST_DIR]
#
# Host settings reach the guest as the systemd credential tryomarchy.host
# (SMBIOS type 11), never on the kernel command line, which is the guest's.
# The app reads the progress lines ("[qemu-gpu] Launch phase: …", "Reset
# phase: …", "Ready. QMP: …") and maps "run-qemu-gpu: …" errors.

set -euo pipefail

gpu_device='virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080,romfile='
cocoa_hdr=''
case ${OMARCHY_NATIVE_OPENGL_HDR:-0} in
  0) ;;
  1) gpu_device+=',x-omarchy-hdr=on'; cocoa_hdr=',hdr=on' ;;
  *) echo 'OMARCHY_NATIVE_OPENGL_HDR must be 0 or 1' >&2; exit 64 ;;
esac

usage() {
  echo "Usage: run-qemu-gpu.sh [--ephemeral | --reset-storage | --reset-storage-only] [GUEST_DIR]" >&2
  exit 64
}

fail() {
  echo "run-qemu-gpu: $*" >&2
  exit 1
}

storage_mode=persistent
reset_only=0
case ${1:-} in
  --ephemeral) storage_mode=ephemeral; shift ;;
  --reset-storage) storage_mode=reset; shift ;;
  --reset-storage-only) storage_mode=reset; reset_only=1; shift ;;
  --*) usage ;;
esac
(($# <= 1)) || usage

if ((reset_only)); then
  echo '[qemu-gpu] Reset phase: checking' >&2
else
  echo '[qemu-gpu] Launch phase: checking' >&2
fi

case ${OMARCHY_QEMU_GPU_DRY_RUN:-0} in 0) dry_run=0 ;; 1) dry_run=1 ;; *) fail "OMARCHY_QEMU_GPU_DRY_RUN must be 0 or 1" ;; esac

script_dir=$(cd "$(dirname "$0")" && pwd -P)
resources_dir=$(cd "$script_dir/.." && pwd -P)
contents_dir=$(cd "$resources_dir/.." && pwd -P)
app_bundle=$(cd "$contents_dir/.." && pwd -P)
guest_input=${1:-"$resources_dir/guest"}
qemu_bin="$resources_dir/runtime/bin/Try Omarchy"
native_bridge="$contents_dir/MacOS/omarchy-vm-helper"
zstd_bin="$resources_dir/runtime/bin/zstd"
firmware_code=${OMARCHY_SHELL_FIRMWARE:-"$resources_dir/firmware/edk2-aarch64-code.fd"}

[[ $(uname -m) == arm64 && $(uname -s) == Darwin ]] || fail "requires an Apple Silicon Mac"
macos_major=$(sw_vers -productVersion | cut -d. -f1)
[[ $macos_major =~ ^[0-9]+$ ]] && ((macos_major >= 15)) || fail "requires macOS 15 or newer"
# Nested virtualization (EL2) is opt-in: the UEFI firmware then runs at EL2
# too, where its virtual-timer interrupt never arrives under HVF, so Limine
# hangs in its first timer wait (seen on macOS 26 and 27, M4 and M5). 1 probes
# EL2 on macOS 26 or newer; 0, the default, always uses EL1.
case ${OMARCHY_QEMU_GPU_NESTED_VIRT:-0} in
  1) ((macos_major >= 26)) && probe_nested=1 || probe_nested=0 ;;
  0) probe_nested=0 ;;
  *) fail "OMARCHY_QEMU_GPU_NESTED_VIRT must be 0 or 1" ;;
esac
[[ -d $guest_input && ! -L $guest_input ]] || fail "guest directory is missing or unsafe: $guest_input"
guest_dir=$(cd "$guest_input" && pwd -P)

case ${OMARCHY_QEMU_GPU_INSPECT_ONLY:-0} in
  0) codesign --verify --deep --strict "$app_bundle" >/dev/null 2>&1 ||
       fail "the installed app is damaged or has an invalid code signature" ;;
  1) ;;
  *) fail "OMARCHY_QEMU_GPU_INSPECT_ONLY must be 0 or 1" ;;
esac
[[ -f $qemu_bin && -x $qemu_bin && -f $native_bridge && -x $native_bridge && -f $zstd_bin && -x $zstd_bin ]] ||
  fail "the bundled runtime is incomplete"
[[ -f $firmware_code && ! -L $firmware_code ]] || fail "the bundled UEFI firmware is missing: $firmware_code"

# --- the factory ---------------------------------------------------------------
factory="$guest_dir/factory.json"
[[ -f $factory && ! -L $factory ]] || fail "the guest directory has no factory.json"
factory_field() {
  /usr/bin/plutil -extract "$1" raw -o - "$factory" 2>/dev/null
}
[[ $(factory_field kind) == upstream-shell-factory && $(factory_field format) == 1 ]] ||
  fail "unsupported factory format"
[[ $(factory_field boot) == uefi-limine ]] || fail "the factory does not boot through UEFI"
compressed_name=$(factory_field compressed.path)
compressed_sha=$(factory_field compressed.sha256)
disk_sha=$(factory_field disk.sha256)
disk_bytes=$(factory_field disk.bytes)
[[ $compressed_name =~ ^[A-Za-z0-9._-]+\.img\.zst$ && $compressed_sha =~ ^[0-9a-f]{64}$ &&
  $disk_sha =~ ^[0-9a-f]{64}$ && $disk_bytes =~ ^[1-9][0-9]*$ ]] || fail "the factory manifest is invalid"
compressed="$guest_dir/$compressed_name"
# A release app downloads the compressed factory instead of carrying it
# (FactoryImageDownload.swift) and names the verified copy here. It is only
# read when a new VM disk needs the factory.
if [[ ! -e $compressed && ! -L $compressed ]]; then
  compressed=${OMARCHY_QEMU_GPU_FACTORY_IMAGE:-}
  [[ -z $compressed || ($compressed == /* && $compressed != *$'\n'*) ]] ||
    fail "OMARCHY_QEMU_GPU_FACTORY_IMAGE must be an absolute path"
fi
factory_identity=$disk_sha

if [[ ${OMARCHY_QEMU_GPU_INSPECT_ONLY:-0} == 1 ]]; then
  printf '%s\t%s\n' "$factory_identity" "$disk_bytes"
  exit 0
fi

# --- storage -----------------------------------------------------------------
volume_filesystem() {
  if [[ -n ${OMARCHY_QEMU_GPU_TEST_FS_TYPE:-} ]]; then
    printf '%s\n' "$OMARCHY_QEMU_GPU_TEST_FS_TYPE"
    return
  fi
  local device
  device=$(/bin/df -P "$1" 2>/dev/null | awk 'NR == 2 { print $1 }')
  [[ -n $device ]] || return 1
  # "<device> on <mount point> (<type>, …)"; the mount point may contain spaces.
  /sbin/mount | awk -v prefix="$device on " 'index($0, prefix) == 1 { print; exit }' |
    sed -E 's/.* \(([^,)]+)[,)].*/\1/'
}
free_bytes() {
  if [[ -n ${OMARCHY_QEMU_GPU_TEST_FREE_BYTES:-} ]]; then
    printf '%s\n' "$OMARCHY_QEMU_GPU_TEST_FREE_BYTES"
    return
  fi
  local kibibytes
  kibibytes=$(/bin/df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }')
  [[ $kibibytes =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((kibibytes * 1024))"
}
require_free_space() { # path bytes
  local available
  available=$(free_bytes "$1") || fail "cannot determine free space on the volume holding $1"
  ((available >= $2)) ||
    fail "not enough free space for the Omarchy VM: $(($2 / 1048576)) MiB required, $((available / 1048576)) MiB available"
}

# The storage folder's marker: a private regular file holding exactly the
# token. The app's folder picker applies the same rules
# (StorageLocationPolicy.hasValidRootMarker, StorageMarkerAgreementTests).
valid_root_marker() { # path
  [[ -f $1 && ! -L $1 && $(stat -f %u "$1") == "$(id -u)" && $(stat -f %Lp "$1") == 600 &&
    $(<"$1") == omarchy-qemu-storage-root-v1 ]]
}

# Resolves and checks the storage folder and takes the persistent VM's lock.
open_storage() {
  state_root=${OMARCHY_QEMU_GPU_STATE_ROOT:-"$HOME/Library/Application Support/Try Omarchy/VM/v1"}
  [[ $state_root == /* && $state_root != *$'\n'* && $state_root != *$'\r'* ]] ||
    fail "the VM storage location must be an absolute single-line path"
  case ${state_root%/} in
    '' | /Users | /Volumes | /private | /private/tmp | /tmp) fail "refusing an unsafe VM storage location: $state_root" ;;
  esac
  umask 077
  mkdir -p "$state_root"
  chmod 700 "$state_root"
  state_root=$(cd "$state_root" && pwd -P)
  [[ $(stat -f %u "$state_root") == "$(id -u)" ]] || fail "the VM storage folder is not owned by this user: $state_root"

  # VM disks are sparse APFS clones; other filesystems would allocate every byte.
  filesystem=$(volume_filesystem "$state_root") || filesystem=''
  [[ -n $filesystem ]] || fail "cannot determine the filesystem holding $state_root"
  [[ $filesystem == apfs ]] || fail "the Omarchy VM requires an APFS volume; $state_root is on $filesystem"

  # The app checks this marker before it stores its per-workspace settings here.
  root_marker="$state_root/.omarchy-qemu-storage"
  if [[ ! -e $root_marker && ! -L $root_marker ]]; then
    (set -o noclobber; printf '%s\n' omarchy-qemu-storage-root-v1 >"$root_marker") 2>/dev/null || true
  fi
  valid_root_marker "$root_marker" || fail "the VM storage folder has an invalid marker: $root_marker"
  vm_dir="$state_root/shell"
  factory_cache="$state_root/shell-factory"
  mkdir -p "$vm_dir" "$factory_cache"
  chmod 700 "$vm_dir" "$factory_cache"

  [[ -x /usr/bin/lockf ]] || fail "/usr/bin/lockf is required"
  # One persistent VM per storage folder. A disposable VM runs beside it.
  if [[ $storage_mode != ephemeral ]]; then
    exec 9>>"$vm_dir/lock"
    /usr/bin/lockf -s -t 0 9 || fail "this VM is already open"
  fi
  disk="$vm_dir/disk.img"
  vars="$vm_dir/efi-vars.fd"
  metadata="$vm_dir/vm.json"
}

reset_vm() {
  rm -f "$disk" "$disk.partial" "$vars" "$metadata" "$vm_dir/guest-status.json"
}

# A reset-only request needs none of the launch inputs below.
if ((reset_only)); then
  open_storage
  echo '[qemu-gpu] Reset phase: deleting' >&2
  reset_vm
  echo '[qemu-gpu] Reset phase: finishing' >&2
  echo '[qemu-gpu] Reset complete.' >&2
  exit 0
fi

# --- QEMU capabilities -------------------------------------------------------------
# The app's signature covers the runtime; these catch a development build
# staged without the project's QEMU patches.
for marker in TryOmarchy.icns OMARCHY_SDL_AUDIO_CONTROL_DIRECTORY guest_owner_uid; do
  LC_ALL=C grep -aFq "$marker" "$qemu_bin" || fail "the bundled QEMU lacks the project patches; run make runtime"
done
qemu_devices=$("$qemu_bin" -device help 2>&1) || fail "cannot inspect the bundled QEMU"
require_qemu_device() {
  [[ $qemu_devices == *"name \"$1\""* ]] || fail "the bundled QEMU does not provide $1; run make runtime"
}
for device in hda-micro intel-hda virtconsole virtserialport virtio-balloon-pci virtio-9p-pci \
  virtio-blk-pci virtio-gpu-gl-pci virtio-keyboard-pci virtio-net-pci virtio-rng-pci \
  virtio-serial-pci virtio-tablet-pci virtio-pinch-pci; do
  require_qemu_device "$device"
done

# --- resources ---------------------------------------------------------------
host_cpu_count=$(sysctl -n hw.logicalcpu)
((host_cpu_count >= 4)) || fail "the guest requires at least four host CPUs"
default_vcpu_count=$((host_cpu_count < 8 ? host_cpu_count : 8))
vcpu_count=${OMARCHY_QEMU_GPU_CPUS-$default_vcpu_count}
[[ $vcpu_count =~ ^[1-9][0-9]{0,6}$ ]] && ((vcpu_count >= 4 && vcpu_count <= host_cpu_count)) ||
  fail "OMARCHY_QEMU_GPU_CPUS must be between 4 and $host_cpu_count"
host_memory_mib=$(($(sysctl -n hw.memsize) / 1048576))
default_memory_mib=$((host_memory_mib >= 16384 ? 8192 : 4096))
memory_mib=${OMARCHY_QEMU_GPU_MEMORY_MIB:-$default_memory_mib}
[[ $memory_mib =~ ^[0-9]{1,7}$ ]] || fail "OMARCHY_QEMU_GPU_MEMORY_MIB must be a whole number of MiB"
memory_mib=$((10#$memory_mib))
((memory_mib >= 2048)) || fail "the guest requires at least 2048 MiB of memory"
((memory_mib <= 4096 || memory_mib + 4096 <= host_memory_mib)) ||
  fail "OMARCHY_QEMU_GPU_MEMORY_MIB must leave the host at least 4096 MiB"

disk_capacity_gib=${OMARCHY_QEMU_GPU_DISK_GIB:-}
if [[ -n $disk_capacity_gib ]]; then
  [[ $disk_capacity_gib =~ ^[1-9][0-9]{0,3}$ ]] && ((disk_capacity_gib <= 8192)) ||
    fail "OMARCHY_QEMU_GPU_DISK_GIB must be a whole number of GiB from 1 to 8192"
fi

# --- host settings for the guest (credential tryomarchy.host) ---------------------
host_options="omarchy.qemu_virgl=1 omarchy.virgl_dual_source=1"

source "$script_dir/qemu-port-forwarding.sh"
source "$script_dir/qemu-networking.sh"
qemu_network_validate
network_forwards=${OMARCHY_QEMU_GPU_PORT_FORWARDS:-}
[[ $QEMU_NETWORK_MODE == nat ]] || network_forwards=
qemu_port_forwarding_configure "$network_forwards" || fail "$QEMU_PORT_FORWARDING_ERROR"
qemu_netdev=$QEMU_PORT_FORWARDING_NETDEV
port_forwarding_summary=$QEMU_PORT_FORWARDING_SUMMARY
if ((QEMU_PORT_FORWARDING_ENABLES_SSH)); then
  host_options+=" tryomarchy.ssh_access=1"
elif [[ $QEMU_NETWORK_MODE == bridged && ${QEMU_NETWORK_SSH:-0} == 1 ]]; then
  host_options+=" tryomarchy.ssh_access=1 tryomarchy.ssh_from=any"
fi
[[ $QEMU_NETWORK_MODE == nat ]] || port_forwarding_summary='inactive in bridged mode'

keyboard=$("$native_bridge" --host-keyboard-geometry) || fail "cannot detect the Mac keyboard geometry"
case $keyboard in ansi | iso | jis) host_options+=" tryomarchy.keyboard=$keyboard" ;; *) fail "invalid keyboard geometry" ;; esac
# QEMU's Cocoa display maps the ISO section key from the same geometry.
export TRYOMARCHY_KEYBOARD=$keyboard

# The camera housing of the Mac's built-in panel, one WIDTHxHEIGHT:TOP per
# display mode in pixels: QEMU's full screen covers the strip beside it, and
# the guest describes it to Omarchy's bar. Nothing on a Mac without a notch,
# or with the launcher's Camera notch setting off (OMARCHY_QEMU_GPU_NOTCH=0):
# full screen then stays below the housing, which QEMU reads as
# TRYOMARCHY_NOTCH=0. The notch is cosmetic, so a failed probe only leaves it
# out.
case ${OMARCHY_QEMU_GPU_NOTCH:-1} in
  1) ;;
  0) export TRYOMARCHY_NOTCH=0 ;;
  *) fail "OMARCHY_QEMU_GPU_NOTCH must be 0 or 1" ;;
esac
if [[ ${TRYOMARCHY_NOTCH:-1} != 0 ]]; then
  display_cutouts=$("$native_bridge" --host-display-cutouts 2>/dev/null) || display_cutouts=
  if [[ $display_cutouts =~ ^[1-9][0-9]{0,4}x[1-9][0-9]{0,4}:[1-9][0-9]{0,3}(,[1-9][0-9]{0,4}x[1-9][0-9]{0,4}:[1-9][0-9]{0,3}){0,63}$ ]]; then
    host_options+=" tryomarchy.display_cutouts=$display_cutouts"
  elif [[ -n $display_cutouts ]]; then
    echo "run-qemu-gpu: ignoring unexpected display cutouts: $display_cutouts" >&2
  fi
fi

if [[ -n ${OMARCHY_QEMU_GPU_MAC_LANGUAGE:-} ]]; then
  [[ $OMARCHY_QEMU_GPU_MAC_LANGUAGE =~ ^[a-z]{2,3}$ ]] || fail "invalid Mac language"
  host_options+=" tryomarchy.mac_language=$OMARCHY_QEMU_GPU_MAC_LANGUAGE"
fi
case ${OMARCHY_QEMU_GPU_LOCALE:-} in
  '') ;;
  en_US.UTF-8 | zh_TW.UTF-8 | zh_CN.UTF-8 | ko_KR.UTF-8 | ja_JP.UTF-8) host_options+=" tryomarchy.locale=$OMARCHY_QEMU_GPU_LOCALE" ;;
  *) fail "unsupported guest locale: $OMARCHY_QEMU_GPU_LOCALE" ;;
esac
host_timezone=$("$native_bridge" --host-timezone) || fail "cannot read the Mac time zone"
case $host_timezone in
  '' | *[!A-Za-z0-9_+/-]* | /* | */ | *//* | . | .. | ./* | ../* | */./* | */../*) fail "invalid Mac time zone" ;;
esac
host_options+=" tryomarchy.timezone=$host_timezone"

# One optional Mac folder for the guest. The app validates the selection
# first; re-check so a stray environment value can never export an unsafe tree.
shared_folder=${OMARCHY_QEMU_GPU_SHARED_FOLDER:-}
if [[ -n $shared_folder ]]; then
  [[ $shared_folder == /* && $shared_folder != *$'\n'* && $shared_folder != *$'\r'* && $shared_folder != *,* ]] ||
    fail "shared folder path contains an unsupported character"
  [[ -d $shared_folder && ! -L $shared_folder ]] || fail "shared folder is missing or is a symbolic link: $shared_folder"
  shared_folder=$(cd "$shared_folder" && pwd -P) || fail "cannot resolve the shared folder"
  # A symlink in the middle of the path can resolve to a name the first check
  # never saw, so validate the canonical path before it goes into -fsdev.
  [[ $shared_folder != *$'\n'* && $shared_folder != *$'\r'* && $shared_folder != *,* ]] ||
    fail "shared folder resolves to a path with an unsupported character: $shared_folder"
  [[ $(stat -f %u "$shared_folder") == "$(id -u)" ]] || fail "shared folder must be owned by this user: $shared_folder"
  home_dir=$(cd "$HOME" 2>/dev/null && pwd -P || true)
  case $shared_folder in
    / | /Users | /private | /private/tmp | /tmp | /System | /Library | /Applications | /Volumes)
      fail "refusing to share a system directory: $shared_folder" ;;
  esac
  if [[ -n $home_dir ]]; then
    [[ $shared_folder != "$home_dir" ]] || fail "refusing to share the whole home folder"
    [[ $shared_folder != "$home_dir/Library" && $shared_folder != "$home_dir/Library/"* ]] ||
      fail "refusing to share the Library folder"
  fi
  # The guest links ~/<name> to the mount; the name travels as URL-safe base64.
  shared_folder_name=${shared_folder##*/}
  name_encoded=$(printf '%s' "$shared_folder_name" | base64 | tr '+/' '-_' | tr -d '=\n')
  [[ $name_encoded =~ ^[A-Za-z0-9_-]+$ ]] || fail "cannot encode the shared folder name"
  host_options+=" omarchy.shared_folder_name=$name_encoded"
fi

credential() { # name value
  printf 'io.systemd.credential.binary:%s=%s' "$1" "$(printf '%s' "$2" | base64 | tr -d '\n')"
}

# Experimental host USB passthrough: usb-host properties, either a device
# class (vendorid=0x05ac) or exact host ports. Anything else is refused rather
# than reinterpreted as further QEMU options.
usb_host_properties=${OMARCHY_QEMU_GPU_USB_HOST:-}
if [[ -n $usb_host_properties ]]; then
  [[ $usb_host_properties =~ ^[a-z]+=[0-9A-Fa-fx.]+(,[a-z]+=[0-9A-Fa-fx.]+)*$ ]] ||
    fail "OMARCHY_QEMU_GPU_USB_HOST must be usb-host properties, for example vendorid=0x05ac"
  require_qemu_device qemu-xhci
  require_qemu_device usb-host
  # Unpatched QEMU reads hostbus=0 as "any bus" and could take a twin.
  LC_ALL=C grep -aFq 'exact bus 0 matching' "$qemu_bin" ||
    fail "the bundled QEMU lacks exact USB bus matching; run make runtime"
fi

# Diagnostics for HVF memory-mapping crashes.
hvf_trace_log=${OMARCHY_QEMU_GPU_HVF_TRACE_LOG:-}
[[ -z $hvf_trace_log || $hvf_trace_log == /* ]] || fail "OMARCHY_QEMU_GPU_HVF_TRACE_LOG must be an absolute path"

# Integration updates: the app shares its bundled try-omarchy package on every
# boot. The guest installs it before login only when it is newer than the
# installed one (try-omarchy-package-install.service), so a guest that already
# took a newer package from [omarchy] keeps it. OMARCHY_SHELL_INSTALL_PACKAGE
# names another archive; an empty value turns the offer off.
bundled_package=""
for candidate in "$resources_dir"/guest-packages/try-omarchy-*.pkg.tar.zst; do
  [[ -f $candidate ]] && bundled_package=$candidate
done
package_to_install=${OMARCHY_SHELL_INSTALL_PACKAGE-$bundled_package}
if [[ -n $package_to_install ]]; then
  [[ -f $package_to_install && ! -L $package_to_install &&
    ${package_to_install##*/} =~ ^try-omarchy-[0-9][A-Za-z0-9._+-]*-(aarch64|any)\.pkg\.tar\.zst$ ]] ||
    fail "invalid integration package: $package_to_install"
fi

# --- machine ---------------------------------------------------------------------
qemu_machine='virt,gic-version=3'
qemu_accel=(-accel hvf)
# On Macs without EL2 support the probe aborts; a subshell keeps the shell's
# job report about that out of the launch log.
if ((probe_nested)) && (
  printf '%s\n' '{"execute":"qmp_capabilities"}' '{"execute":"quit"}' |
    "$qemu_bin" -machine 'virt,gic-version=3,virtualization=on' -accel 'hvf,kernel-irqchip=on' \
      -cpu 'host,pmu=off' -smp 1 -m 128M -nodefaults -display none -S -qmp stdio
) >/dev/null 2>&1; then
  qemu_machine='virt,gic-version=3,virtualization=on'
  qemu_accel=(-accel 'hvf,kernel-irqchip=on')
  echo '[qemu-gpu] Nested virtualization is enabled.' >&2
elif ((probe_nested)); then
  echo '[qemu-gpu] Nested virtualization is unavailable; using the compatible EL1 path.' >&2
else
  echo '[qemu-gpu] Nested virtualization is off; using the EL1 path.' >&2
fi

case ${OMARCHY_QEMU_GPU_IMMERSIVE:-1} in
  1) full_screen=on immersive=on ;;
  0) full_screen=off immersive=off ;;
  *) fail "OMARCHY_QEMU_GPU_IMMERSIVE must be 0 or 1" ;;
esac

open_storage
if [[ $storage_mode == reset ]]; then
  reset_vm
  storage_mode=persistent
fi

# The decompressed factory is kept once per factory identity and cloned (APFS
# clonefile) for each new VM, so creating or resetting a VM costs no space. A
# disposable VM first tries to clone the storage folder's copy, and so does a
# VM whose storage the app keeps elsewhere for one session
# (OMARCHY_QEMU_GPU_FACTORY_CACHE, the main storage folder's shell-factory).
factory_disk="$factory_cache/$factory_identity.img"
shared_factory=${OMARCHY_QEMU_GPU_FACTORY_CACHE:-}
[[ -z $shared_factory || ($shared_factory == /* && $shared_factory != *$'\n'*) ]] ||
  fail "OMARCHY_QEMU_GPU_FACTORY_CACHE must be an absolute path"
prepare_factory_disk() {
  [[ -f $factory_disk ]] && return 0
  if [[ -n $shared_factory ]]; then
    local shared="$shared_factory/$factory_identity.img"
    if [[ -f $shared && ! -L $shared ]] && cp -c "$shared" "$factory_disk.partial" 2>/dev/null; then
      mv -f "$factory_disk.partial" "$factory_disk"
      return 0
    fi
    rm -f "$factory_disk.partial"
  fi
  [[ -n $compressed && -f $compressed && ! -L $compressed ]] ||
    fail "the Omarchy image has not been downloaded; open Try Omarchy to download it"
  echo '[qemu-gpu] Preparing the Omarchy factory disk (first launch only)...' >&2
  echo '[qemu-gpu] Launch phase: preparing' >&2
  local stale
  for stale in "$factory_cache"/*.img "$factory_cache"/*.partial; do
    [[ -e $stale ]] && rm -f "$stale"
  done
  # The decompressed disk is sparse, but about half of it is written.
  require_free_space "$factory_cache" $((disk_bytes / 2 + 1073741824))
  local actual available
  actual=$(/usr/bin/shasum -a 256 "$compressed" | cut -d' ' -f1)
  [[ $actual == "$compressed_sha" ]] || fail "the Omarchy factory image is damaged: $compressed"
  # A failed decompression (most often a full disk) must not leave gigabytes
  # of partial disk behind.
  if ! "$zstd_bin" -q -d --sparse -f "$compressed" -o "$factory_disk.partial"; then
    rm -f "$factory_disk.partial"
    available=$(free_bytes "$factory_cache") || available=0
    ((available >= 1073741824)) || fail "not enough free space to prepare the Omarchy VM; free up some space and launch again"
    fail "could not decompress the factory disk"
  fi
  [[ $(stat -f %z "$factory_disk.partial") == "$disk_bytes" ]] || fail "the factory disk has the wrong size"
  chmod 600 "$factory_disk.partial"
  echo '[qemu-gpu] Launch phase: finishing' >&2
  # zstd leaves much of the filesystem's free space allocated on APFS where
  # data and zeros alternate; return those blocks (about half the disk).
  "$native_bridge" --sparsify "$factory_disk.partial" >/dev/null || true
  mv -f "$factory_disk.partial" "$factory_disk"
}

new_disk() { # destination
  prepare_factory_disk
  cp -c "$factory_disk" "$1" 2>/dev/null || fail "could not clone the factory disk (the VM storage must be on APFS)"
  chmod 600 "$1"
}

new_vars() { # destination
  /bin/dd if=/dev/null of="$1" bs=1 count=0 seek=67108864 2>/dev/null || fail "could not create the UEFI variable store"
  chmod 600 "$1"
}

# --- run directory -----------------------------------------------------------------
# Remove run directories left by a launcher that was killed, once neither it
# nor its QEMU is still alive.
reap_stale_work_dirs() {
  local candidate marker launcher_pid qemu_pid_file stale_qemu_pid live
  live=$(ps -U "$(id -u)" -o pid= 2>/dev/null) || return 0
  for candidate in /private/tmp/omarchy-qemu-gpu.??????; do
    [[ -d $candidate && ! -L $candidate && $(stat -f %u "$candidate") == "$(id -u)" ]] || continue
    marker="$candidate/.run-qemu-gpu.owner"
    [[ -f $marker && ! -L $marker && $(<"$marker") =~ ^run-qemu-gpu:v2:([0-9]+)$ ]] || continue
    launcher_pid=${BASH_REMATCH[1]}
    stale_qemu_pid=''
    qemu_pid_file="$candidate/.qemu.pid"
    [[ -f $qemu_pid_file && ! -L $qemu_pid_file ]] && stale_qemu_pid=$(<"$qemu_pid_file")
    [[ -z $stale_qemu_pid || $stale_qemu_pid =~ ^[0-9]+$ ]] || continue
    if grep -qxE "[[:space:]]*($launcher_pid${stale_qemu_pid:+|$stale_qemu_pid})" <<<"$live"; then
      continue
    fi
    /bin/rm -rf "$candidate"
  done
}
reap_stale_work_dirs

work_dir=$(mktemp -d '/private/tmp/omarchy-qemu-gpu.XXXXXX') || fail "could not create a private temporary directory"
printf 'run-qemu-gpu:v2:%s\n' "$$" >"$work_dir/.run-qemu-gpu.owner"
# Every exit from here on stops QEMU and the bridges and removes the work directory.
qemu_pid=""
bridge_pids=()

terminate() { # pid attempts
  local pid=$1 attempt
  [[ $pid =~ ^[0-9]+$ ]] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  for ((attempt = 0; attempt < $2; attempt++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  local status=$? pid
  trap - EXIT HUP INT TERM
  set +e
  [[ -z $qemu_pid ]] || terminate "$qemu_pid" 40
  for pid in ${bridge_pids[@]+"${bridge_pids[@]}"}; do
    terminate "$pid" 20
  done
  if declare -F qemu_network_stop >/dev/null && ! qemu_network_stop; then
    ((status != 0)) || status=1
  fi
  case $work_dir in /private/tmp/omarchy-qemu-gpu.??????) rm -rf "$work_dir" ;; esac
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

socket_dir="/tmp/${work_dir##*/}"

if [[ $storage_mode == ephemeral ]]; then
  # A disposable disk lives in the run directory and is deleted with it.
  shared_factory=$factory_cache
  factory_cache="$work_dir/factory"
  mkdir -m 700 "$factory_cache"
  factory_disk="$factory_cache/$factory_identity.img"
  working_disk="$work_dir/disk.img"
  working_vars="$work_dir/efi-vars.fd"
  new_disk "$working_disk"
  new_vars "$working_vars"
else
  if [[ ! -f $disk ]]; then
    new_disk "$disk.partial"
    new_vars "$vars"
    mv -f "$disk.partial" "$disk"
    printf '{"format":1,"kind":"upstream-shell-vm","factory":"%s","created":"%s"}\n' \
      "$factory_identity" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$metadata"
  fi
  [[ -f $vars ]] || new_vars "$vars"
  working_disk=$disk
  working_vars=$vars
fi

# A VM from an earlier direct-boot version of the app (a bare ext4 root in
# disks/) is never booted. It is attached read-only so the guest's
# try-omarchy-import-previous can copy the user's files into this VM; deleting
# the disks folder detaches it.
previous_disk=''
if [[ $storage_mode == persistent && -d $state_root/disks && ! -L $state_root/disks ]]; then
  for candidate in "$state_root/disks/current/rootfs.ext4" "$state_root"/disks/*/rootfs.ext4; do
    [[ -f $candidate && ! -L $candidate && ! -L ${candidate%/*} ]] || continue
    previous_disk=$candidate
    break
  done
fi

# Growing the disk file is enough: the guest grows its root partition and
# btrfs to fill the disk at boot (try-omarchy-grow-root.service).
if [[ -n $disk_capacity_gib ]]; then
  wanted=$((disk_capacity_gib * 1073741824))
  current=$(stat -f %z "$working_disk")
  # Disks never shrink; a setting below the current size keeps the disk as is.
  if ((wanted > current && !dry_run)); then
    # dd with count=0 sets the length at the seek offset: a sparse extension.
    /bin/dd if=/dev/null of="$working_disk" bs=1 count=0 seek="$wanted" 2>/dev/null || fail "could not grow the VM disk"
  fi
fi

QEMU_SELECTED_STORAGE_MODE=$storage_mode
QEMU_NETWORK_STATE_ROOT=$state_root

if [[ -n $package_to_install ]]; then
  mkdir "$work_dir/packages"
  cp "$package_to_install" "$work_dir/packages/"
fi

qmp_socket="$socket_dir/qmp.sock"
audio_socket="$socket_dir/audio.sock"
clipboard_socket="$socket_dir/clipboard.sock"
authentication_socket="$socket_dir/authentication.sock"
camera_socket="$socket_dir/camera.sock"
battery_socket="$socket_dir/battery.sock"
timezone_socket="$socket_dir/timezone.sock"
settings_socket="$socket_dir/settings.sock"
guest_socket="$socket_dir/guest.sock"
audio_routes="$socket_dir/audio-routes"
mkdir -m 700 "$work_dir/audio-routes"

console_log="$vm_dir/console.log"
[[ $storage_mode == persistent ]] || console_log="$work_dir/console.log"
((dry_run)) || [[ ! -f $console_log ]] || mv -f "$console_log" "$console_log.1"

network_mac=$(qemu_network_mac) || fail "cannot prepare the VM network identity"
if [[ $QEMU_NETWORK_MODE == bridged ]]; then
  if ((dry_run)); then
    qemu_netdev='stream,id=omarchy-net,server=off,addr.type=unix,addr.path=/private/tmp/bridge-dry-run/network.sock'
  else
    qemu_network_start "$resources_dir" "$work_dir"
    qemu_netdev=$QEMU_NETWORK_NETDEV
  fi
fi

host_audio_frequency() { # direction sdl-device-name
  local rate
  rate=$("$native_bridge" --host-audio-frequency "$1" "$2" 2>/dev/null) || return 1
  [[ $rate =~ ^[1-9][0-9]{3,5}$ ]] || return 1
  printf '%s\n' "$rate"
}
audio_output_frequency=$(host_audio_frequency output "${OMARCHY_SDL_OUTPUT_DEVICE_NAME:-}") || audio_output_frequency=48000
audio_input_frequency=$(host_audio_frequency input "${OMARCHY_SDL_INPUT_DEVICE_NAME:-}") || audio_input_frequency=48000

qemu_args=(
  -name 'Try Omarchy'
  -machine "$qemu_machine"
  "${qemu_accel[@]}"
  -cpu 'host,pmu=off'
  -smp "$vcpu_count,sockets=1,cores=$vcpu_count,threads=1"
  -m "${memory_mib}M"
  -nodefaults
  -action 'reboot=reset,shutdown=poweroff'
  -drive "if=pflash,format=raw,readonly=on,file=${firmware_code//,/,,}"
  -drive "if=pflash,format=raw,file=${working_vars//,/,,}"
  -smbios "type=11,value=$(credential tryomarchy.host "$host_options")"
  -netdev "$qemu_netdev"
  -device "virtio-net-pci,id=omarchy-nic,netdev=omarchy-net,mac=$network_mac,romfile="
  -audiodev "sdl,id=omarchy-audio,timer-period=1000,out.buffer-count=8,out.frequency=$audio_output_frequency,in.frequency=$audio_input_frequency"
  -device 'intel-hda,id=omarchy-hda,romfile='
  -device 'hda-micro,bus=omarchy-hda.0,audiodev=omarchy-audio'
  -serial none
  -monitor none
  -qmp "unix:$qmp_socket,server=on,wait=off"
  -drive "if=none,id=omarchy-root,file=${working_disk//,/,,},format=raw,media=disk,cache=writeback"
  -device 'virtio-blk-pci,drive=omarchy-root,serial=omarchy-root,bootindex=0'
  -device "$gpu_device"
  -display "cocoa,gl=on${cocoa_hdr},show-cursor=on,zoom-to-fit=on,full-screen=$full_screen,full-grab=on,immersive=$immersive,swap-opt-cmd=off"
  -device 'virtio-keyboard-pci,romfile='
  -device 'virtio-tablet-pci,romfile='
  -device 'virtio-pinch-pci,romfile='
  -object 'rng-random,id=omarchy-rng,filename=/dev/urandom'
  -device 'virtio-rng-pci,rng=omarchy-rng'
  -device virtio-balloon-pci,free-page-reporting=on
  -device 'virtio-serial-pci,id=omarchy-serial'
  -chardev "file,id=omarchy-hvc0,path=${console_log//,/,,}"
  -device 'virtconsole,bus=omarchy-serial.0,nr=0,chardev=omarchy-hvc0'
  -chardev "socket,id=omarchy-audio-bridge,path=$audio_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=1,chardev=omarchy-audio-bridge,name=dev.tryomarchy.audio'
  -chardev "socket,id=omarchy-clipboard-bridge,path=$clipboard_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=2,chardev=omarchy-clipboard-bridge,name=dev.tryomarchy.clipboard'
  -chardev "socket,id=omarchy-authentication-bridge,path=$authentication_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=3,chardev=omarchy-authentication-bridge,name=dev.tryomarchy.authentication'
  -chardev "socket,id=omarchy-camera-bridge,path=$camera_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=4,chardev=omarchy-camera-bridge,name=dev.tryomarchy.camera'
  -chardev "socket,id=omarchy-guest-status,path=$guest_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=5,chardev=omarchy-guest-status,name=dev.tryomarchy.guest'
  -chardev "socket,id=omarchy-settings-bridge,path=$settings_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=6,chardev=omarchy-settings-bridge,name=dev.tryomarchy.settings'
  -chardev "socket,id=omarchy-battery-bridge,path=$battery_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=7,chardev=omarchy-battery-bridge,name=dev.tryomarchy.battery'
  -chardev "socket,id=omarchy-timezone-bridge,path=$timezone_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=8,chardev=omarchy-timezone-bridge,name=dev.tryomarchy.timezone'
)

if [[ -n $package_to_install ]]; then
  qemu_args+=(
    -smbios "type=11,value=$(credential tryomarchy.package "${package_to_install##*/}")"
    -fsdev "local,id=omarchy-packages,path=$work_dir/packages,security_model=none,readonly=on"
    -device 'virtio-9p-pci,fsdev=omarchy-packages,mount_tag=tryomarchy-packages,romfile='
  )
fi
if [[ -n $previous_disk ]]; then
  qemu_args+=(
    -drive "if=none,id=omarchy-previous,file=${previous_disk//,/,,},format=raw,media=disk,readonly=on"
    -device 'virtio-blk-pci,drive=omarchy-previous,serial=omarchy-previous'
  )
fi
if [[ -n $shared_folder ]]; then
  qemu_args+=(
    -fsdev "local,id=omarchy-share,path=$shared_folder,security_model=none,multidevs=remap,guest_owner_uid=1000,guest_owner_gid=1000"
    -device 'virtio-9p-pci,fsdev=omarchy-share,mount_tag=mac,romfile='
  )
fi
if [[ -n $usb_host_properties ]]; then
  qemu_args+=(
    -device 'qemu-xhci,id=omarchy-usb,streams=off'
    -device "usb-host,bus=omarchy-usb.0,id=omarchy-usb-host,$usb_host_properties"
  )
fi
if [[ -n $hvf_trace_log ]]; then
  qemu_args+=(-trace hvf_vm_map -trace hvf_vm_unmap -trace hvf_vm_protect -D "$hvf_trace_log")
fi
# QEMU holds the persistent VM's lock for as long as it runs.
[[ $storage_mode == ephemeral ]] || qemu_args+=(-add-fd 'fd=9,set=77,opaque=omarchy-persistent-lock')

unset SDL_AUDIO_DEVICE_NAME
export OMARCHY_SDL_AUDIO_CONTROL_DIRECTORY="$audio_routes"

if ((dry_run)); then
  printf '[qemu-gpu] dry-run command:' >&2
  printf ' %q' "$qemu_bin" "${qemu_args[@]}" >&2
  printf '\n[qemu-gpu] host settings: %s\n' "$host_options" >&2
  exit 0
fi

if [[ $storage_mode == persistent ]]; then
  echo "[qemu-gpu] Starting the persistent Omarchy VM with $vcpu_count vCPUs and $memory_mib MiB RAM." >&2
  echo "[qemu-gpu] User data: $vm_dir" >&2
else
  echo "[qemu-gpu] Starting a disposable Omarchy VM with $vcpu_count vCPUs and $memory_mib MiB RAM." >&2
fi
echo "[qemu-gpu] Port forwarding: $port_forwarding_summary" >&2
[[ -z $shared_folder ]] || echo "[qemu-gpu] Shared folder: $shared_folder (guest ~/$shared_folder_name)" >&2
[[ -z $previous_disk ]] || echo "[qemu-gpu] Previous VM attached read-only: $previous_disk" >&2
echo '[qemu-gpu] Launch phase: starting' >&2
"$qemu_bin" "${qemu_args[@]}" &
qemu_pid=$!
printf '%s\n' "$qemu_pid" >"$work_dir/.qemu.pid"

for ((attempt = 0; attempt < 200; attempt++)); do
  [[ -S $qmp_socket && -S $guest_socket && -S $settings_socket ]] && break
  kill -0 "$qemu_pid" 2>/dev/null || fail "QEMU exited before it was ready"
  sleep 0.05
done
[[ -S $qmp_socket ]] || fail "QEMU did not create its control socket"
"$native_bridge" --wait-for-qmp "$qemu_pid" "$qmp_socket" 9>&- || fail "QEMU's QMP monitor did not become ready"
echo "[qemu-gpu] Ready. QMP: $qmp_socket" >&2

# --- host bridges ------------------------------------------------------------------
# Audio is the guest's sound transport: QEMU without it is a failed session.
# The others are conveniences; each restarts up to five times, then only its
# feature stays unavailable for the rest of the session.
status_file="$vm_dir/guest-status.json"
[[ $storage_mode == persistent ]] || status_file="$work_dir/guest-status.json"
bridge_names=(audio clipboard authentication camera battery timezone guest-status)
bridge_restarts=(0 0 0 0 0 0 0)
start_bridge() { # index
  case ${bridge_names[$1]} in
    audio) "$native_bridge" --bridge-native-audio "$qemu_pid" "$audio_socket" "$audio_routes" 9>&- & ;;
    clipboard) "$native_bridge" --bridge-native-clipboard "$qemu_pid" "$clipboard_socket" 9>&- & ;;
    authentication) "$native_bridge" --bridge-native-authentication "$qemu_pid" "$authentication_socket" 9>&- & ;;
    camera) "$native_bridge" --bridge-native-camera "$qemu_pid" "$camera_socket" 9>&- & ;;
    battery) "$native_bridge" --bridge-native-battery "$qemu_pid" "$battery_socket" 9>&- & ;;
    timezone) "$native_bridge" --bridge-native-timezone "$qemu_pid" "$timezone_socket" 9>&- & ;;
    guest-status) "$native_bridge" --bridge-guest-status "$qemu_pid" "$guest_socket" "$status_file" 9>&- & ;;
  esac
  bridge_pids[$1]=$!
}
for index in "${!bridge_names[@]}"; do
  start_bridge "$index"
done
if [[ $QEMU_NETWORK_MODE == bridged ]]; then
  "$native_bridge" --bridge-network-link "$qemu_pid" "$qmp_socket" "$QEMU_NETWORK_DIRECTORY/link-state" 9>&- &
  bridge_pids+=($!)
fi

is_running() {
  local state
  state=$(ps -p "$1" -o state= 2>/dev/null || true)
  [[ -n $state && $state != *Z* ]]
}

# Bash 3.2 has no `wait -n`; poll QEMU, the bridges and the network session.
while is_running "$qemu_pid"; do
  if [[ $QEMU_NETWORK_MODE == bridged ]]; then
    if [[ -f $QEMU_NETWORK_DIRECTORY/failed ]]; then
      cat "$QEMU_NETWORK_DIRECTORY/log" >&2
      fail "the network helper stopped while Omarchy was running"
    fi
    [[ -d $QEMU_NETWORK_DIRECTORY && ! -f $QEMU_NETWORK_DIRECTORY/done ]] ||
      fail "the networking session ended while Omarchy was running"
  fi
  for index in "${!bridge_names[@]}"; do
    pid=${bridge_pids[$index]}
    [[ $pid =~ ^[0-9]+$ ]] || continue
    is_running "$pid" && continue
    if wait "$pid"; then bridge_status=0; else bridge_status=$?; fi
    bridge_pids[$index]=""
    name=${bridge_names[$index]}
    # QEMU closes its channels before it finishes exiting.
    for ((attempt = 0; attempt < 40; attempt++)); do
      is_running "$qemu_pid" || break 3
      sleep 0.05
    done
    [[ $name != audio ]] || fail "the native audio bridge exited while QEMU was running (status $bridge_status)"
    if ((bridge_restarts[index] < 5)); then
      bridge_restarts[index]=$((bridge_restarts[index] + 1))
      echo "[qemu-gpu] $name bridge exited (status $bridge_status); restarting (${bridge_restarts[index]}/5)" >&2
      start_bridge "$index"
    else
      echo "[qemu-gpu] the $name bridge is unavailable for the rest of this session" >&2
    fi
  done
  sleep 0.1
done

if wait "$qemu_pid"; then qemu_status=0; else qemu_status=$?; fi
qemu_pid=""
# Let the audio bridge drain after QEMU closes its channel.
for ((attempt = 0; attempt < 40; attempt++)); do
  [[ ${bridge_pids[0]} =~ ^[0-9]+$ ]] && is_running "${bridge_pids[0]}" || break
  sleep 0.05
done
exit "$qemu_status"
