#!/bin/bash
#
# Launches an upstream-shell VM: a stock aarch64 Omarchy install that owns its
# boot (edk2 UEFI firmware on pflash → Limine → the guest's own UKI). See
# docs/shell-plan.md. Takes the same arguments, environment and progress lines
# as run-qemu-gpu.sh, so the app drives either launcher the same way.
#
#   run-shell-guest.sh [--ephemeral | --reset-storage | --reset-storage-only] [GUEST_DIR]
#
# Host settings reach the guest as the systemd credential tryomarchy.host
# (SMBIOS type 11), never on the kernel command line, which is the guest's.

set -euo pipefail

usage() {
  echo "Usage: macos/run-shell-guest.sh [--ephemeral | --reset-storage | --reset-storage-only] [GUEST_DIR]" >&2
  exit 64
}

fail() {
  echo "run-shell-guest: $*" >&2
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

((reset_only)) || echo '[qemu-gpu] Launch phase: checking' >&2

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
[[ -d $guest_input && ! -L $guest_input ]] || fail "guest directory is missing or unsafe: $guest_input"
guest_dir=$(cd "$guest_input" && pwd -P)

case ${OMARCHY_QEMU_GPU_INSPECT_ONLY:-0} in
  0) codesign --verify --deep --strict "$app_bundle" >/dev/null 2>&1 ||
       fail "the installed app is damaged or has an invalid code signature" ;;
  1) ;;
  *) fail "OMARCHY_QEMU_GPU_INSPECT_ONLY must be 0 or 1" ;;
esac
[[ -x $qemu_bin && -x $native_bridge && -x $zstd_bin ]] || fail "the bundled runtime is incomplete"
[[ -f $firmware_code && ! -L $firmware_code ]] || fail "the bundled UEFI firmware is missing: $firmware_code"

# --- the factory ---------------------------------------------------------------
factory="$guest_dir/factory.json"
[[ -f $factory && ! -L $factory ]] || fail "this guest is not an upstream-shell factory (no factory.json)"
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
[[ -f $compressed && ! -L $compressed ]] || fail "the factory disk is missing: $compressed"
factory_identity=$disk_sha

if [[ ${OMARCHY_QEMU_GPU_INSPECT_ONLY:-0} == 1 ]]; then
  printf '%s\t%s\n' "$factory_identity" "$disk_bytes"
  exit 0
fi

# --- storage -----------------------------------------------------------------
state_root=${OMARCHY_QEMU_GPU_STATE_ROOT:-"$HOME/Library/Application Support/Try Omarchy/VM/v1"}
[[ $state_root == /* && $state_root != *$'\n'* ]] || fail "invalid VM storage location"
umask 077
mkdir -p "$state_root"
state_root=$(cd "$state_root" && pwd -P)
vm_dir="$state_root/shell"
factory_cache="$state_root/shell-factory"
mkdir -p "$vm_dir" "$factory_cache"
chmod 700 "$vm_dir" "$factory_cache"

[[ -x /usr/bin/lockf ]] || fail "/usr/bin/lockf is required"
exec 9>>"$vm_dir/lock"
/usr/bin/lockf -s -t 0 9 || fail "this VM is already open"

disk="$vm_dir/disk.img"
vars="$vm_dir/efi-vars.fd"
metadata="$vm_dir/vm.json"

reset_vm() {
  rm -f "$disk" "$vars" "$metadata" "$vm_dir/guest-status.json"
}

if [[ $storage_mode == reset ]]; then
  reset_vm
  if ((reset_only)); then
    echo '[qemu-gpu] Reset complete.' >&2
    exit 0
  fi
  storage_mode=persistent
fi

# The decompressed factory is kept once per factory identity and cloned (APFS
# clonefile) for each new VM, so creating or resetting a VM costs no space.
factory_disk="$factory_cache/$factory_identity.img"
prepare_factory_disk() {
  [[ -f $factory_disk ]] && return 0
  echo '[qemu-gpu] Preparing the Omarchy factory disk (first launch only)...' >&2
  local stale
  for stale in "$factory_cache"/*.img; do
    [[ -e $stale ]] && rm -f "$stale"
  done
  local actual
  actual=$(/usr/bin/shasum -a 256 "$compressed" | cut -d' ' -f1)
  [[ $actual == "$compressed_sha" ]] || fail "the bundled factory disk is damaged"
  "$zstd_bin" -q -d --sparse -f "$compressed" -o "$factory_disk.partial" || fail "could not decompress the factory disk"
  [[ $(stat -f %z "$factory_disk.partial") == "$disk_bytes" ]] || fail "the factory disk has the wrong size"
  mv -f "$factory_disk.partial" "$factory_disk"
}

new_disk() { # destination
  prepare_factory_disk
  cp -c "$factory_disk" "$1" 2>/dev/null || cp "$factory_disk" "$1" || fail "could not create the VM disk"
  chmod 600 "$1"
}

new_vars() { # destination
  # edk2's variable store for the aarch64 virt machine is a zeroed 64 MiB
  # flash; the firmware formats it on first boot.
  rm -f "$1"
  /usr/bin/mkfile -n 64m "$1" || fail "could not create the UEFI variable store"
}

work_dir=$(mktemp -d '/private/tmp/omarchy-shell.XXXXXX') || fail "could not create a private temporary directory"
socket_dir="/tmp/${work_dir##*/}"

if [[ $storage_mode == ephemeral ]]; then
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

# Growing the disk file is enough: the guest grows its root partition and
# btrfs to fill the disk at boot (try-omarchy-grow-root.service).
disk_capacity_gib=${OMARCHY_QEMU_GPU_DISK_GIB:-}
if [[ -n $disk_capacity_gib ]]; then
  [[ $disk_capacity_gib =~ ^[1-9][0-9]{0,3}$ ]] || fail "OMARCHY_QEMU_GPU_DISK_GIB must be a whole number of GiB"
  wanted=$((disk_capacity_gib * 1024 * 1024 * 1024))
  current=$(stat -f %z "$working_disk")
  # dd with count=0 sets the length at the seek offset: a sparse extension.
  ((wanted <= current)) || /bin/dd if=/dev/null of="$working_disk" bs=1 count=0 seek="$wanted" 2>/dev/null ||
    fail "could not grow the VM disk"
fi

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

# --- host settings for the guest (credential tryomarchy.host) ---------------------
host_options="omarchy.qemu_virgl=1 omarchy.virgl_dual_source=1"

source "$script_dir/qemu-port-forwarding.sh"
source "$script_dir/qemu-networking.sh"
qemu_network_validate
QEMU_SELECTED_STORAGE_MODE=$storage_mode
QEMU_SELECTED_DISK=$working_disk
QEMU_PERSISTENT_STORAGE_DISKS_ROOT="$state_root/disks"
network_forwards=${OMARCHY_QEMU_GPU_PORT_FORWARDS:-}
[[ $QEMU_NETWORK_MODE == nat ]] || network_forwards=
qemu_port_forwarding_configure "$network_forwards" || fail "$QEMU_PORT_FORWARDING_ERROR"
qemu_netdev=$QEMU_PORT_FORWARDING_NETDEV
if ((QEMU_PORT_FORWARDING_ENABLES_SSH)) || [[ $QEMU_NETWORK_MODE == bridged && ${QEMU_NETWORK_SSH:-0} == 1 ]]; then
  host_options+=" tryomarchy.ssh_access=1"
fi

keyboard=$("$native_bridge" --host-keyboard-geometry) || fail "cannot detect the Mac keyboard geometry"
case $keyboard in ansi | iso | jis) host_options+=" tryomarchy.keyboard=$keyboard" ;; *) fail "invalid keyboard geometry" ;; esac
export TRYOMARCHY_KEYBOARD=$keyboard

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

shared_folder=${OMARCHY_QEMU_GPU_SHARED_FOLDER:-}
if [[ -n $shared_folder ]]; then
  [[ $shared_folder == /* && -d $shared_folder && ! -L $shared_folder ]] || fail "shared folder is missing or unsafe"
  shared_folder=$(cd "$shared_folder" && pwd -P)
  [[ $shared_folder != *,* && $shared_folder != *$'\n'* ]] || fail "shared folder path contains an unsupported character"
  case $shared_folder in
    / | /Users | /private | /private/tmp | /tmp | /System | /Library | /Applications | /Volumes | "$HOME" | "$HOME/Library" | "$HOME/Library/"*)
      fail "refusing to share $shared_folder" ;;
  esac
  name_encoded=$(printf '%s' "${shared_folder##*/}" | base64 | tr '+/' '-_' | tr -d '=\n')
  host_options+=" omarchy.shared_folder_name=$name_encoded"
fi

# Update integrations: the app shares one try-omarchy package for this boot,
# which the guest installs before login (try-omarchy-package-install.service).
package_to_install=${OMARCHY_SHELL_INSTALL_PACKAGE:-}
if [[ -n $package_to_install ]]; then
  [[ -f $package_to_install && ! -L $package_to_install &&
    ${package_to_install##*/} =~ ^try-omarchy-[0-9][A-Za-z0-9._+-]*-(aarch64|any)\.pkg\.tar\.zst$ ]] ||
    fail "invalid integration package: $package_to_install"
  mkdir "$work_dir/packages"
  cp "$package_to_install" "$work_dir/packages/"
fi

credential() { # name value
  printf 'io.systemd.credential.binary:%s=%s' "$1" "$(printf '%s' "$2" | base64 | tr -d '\n')"
}

# --- machine ---------------------------------------------------------------------
qemu_machine='virt,gic-version=3'
qemu_accel=(-accel hvf)
host_macos_major=$(sw_vers -productVersion | cut -d. -f1)
if ((host_macos_major >= 26)) &&
  printf '%s\n' '{"execute":"qmp_capabilities"}' '{"execute":"quit"}' |
  "$qemu_bin" -machine 'virt,gic-version=3,virtualization=on' -accel 'hvf,kernel-irqchip=on' \
    -cpu 'host,pmu=off' -smp 1 -m 128M -nodefaults -display none -S -qmp stdio >/dev/null 2>&1; then
  qemu_machine='virt,gic-version=3,virtualization=on'
  qemu_accel=(-accel 'hvf,kernel-irqchip=on')
  echo '[qemu-gpu] Nested virtualization is enabled.' >&2
else
  echo '[qemu-gpu] Nested virtualization is unavailable; using the compatible EL1 path.' >&2
fi

case ${OMARCHY_QEMU_GPU_IMMERSIVE:-1} in
  1) full_screen=on immersive=on ;;
  0) full_screen=off immersive=off ;;
  *) fail "OMARCHY_QEMU_GPU_IMMERSIVE must be 0 or 1" ;;
esac

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
[[ ! -f $console_log ]] || mv -f "$console_log" "$console_log.1"

network_mac=$(qemu_network_mac) || fail "cannot prepare the VM network identity"
if [[ $QEMU_NETWORK_MODE == bridged ]]; then
  qemu_network_start "$resources_dir" "$work_dir"
  qemu_netdev=$QEMU_NETWORK_NETDEV
fi

gpu_device='virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080,romfile='
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
  -display "cocoa,gl=on,show-cursor=on,zoom-to-fit=on,full-screen=$full_screen,full-grab=on,immersive=$immersive,swap-opt-cmd=off"
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
if [[ -n $shared_folder ]]; then
  qemu_args+=(
    -fsdev "local,id=omarchy-share,path=$shared_folder,security_model=none,multidevs=remap,guest_owner_uid=1000,guest_owner_gid=1000"
    -device 'virtio-9p-pci,fsdev=omarchy-share,mount_tag=mac,romfile='
  )
fi
if [[ -n ${OMARCHY_QEMU_GPU_USB_HOST:-} ]]; then
  [[ $OMARCHY_QEMU_GPU_USB_HOST =~ ^(hostbus=[0-9]+,hostaddr=[0-9]+|vendorid=0x[0-9a-f]{4},productid=0x[0-9a-f]{4})$ ]] ||
    fail "invalid USB passthrough device"
  qemu_args+=(
    -device 'qemu-xhci,id=omarchy-usb,streams=off'
    -device "usb-host,bus=omarchy-usb.0,id=omarchy-usb-host,$OMARCHY_QEMU_GPU_USB_HOST"
  )
fi
qemu_args+=(-add-fd 'fd=9,set=77,opaque=omarchy-persistent-lock')

unset SDL_AUDIO_DEVICE_NAME
export OMARCHY_SDL_AUDIO_CONTROL_DIRECTORY="$audio_routes"

if [[ ${OMARCHY_QEMU_GPU_DRY_RUN:-0} == 1 ]]; then
  printf '[qemu-gpu] dry-run command:' >&2
  printf ' %q' "$qemu_bin" "${qemu_args[@]}" >&2
  printf '\n[qemu-gpu] host settings: %s\n' "$host_options" >&2
  rm -rf "$work_dir"
  exit 0
fi

# --- run ---------------------------------------------------------------------------
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
  ! declare -F qemu_network_stop >/dev/null || qemu_network_stop
  case $work_dir in /private/tmp/omarchy-shell.??????) rm -rf "$work_dir" ;; esac
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ $storage_mode == persistent ]]; then
  echo "[qemu-gpu] Starting the persistent upstream Omarchy guest with $vcpu_count vCPUs and $memory_mib MiB RAM." >&2
  echo "[qemu-gpu] User data: $vm_dir" >&2
else
  echo "[qemu-gpu] Starting a disposable upstream Omarchy guest with $vcpu_count vCPUs and $memory_mib MiB RAM." >&2
fi
echo "[qemu-gpu] Port forwarding: $QEMU_PORT_FORWARDING_SUMMARY" >&2
echo '[qemu-gpu] Launch phase: starting' >&2
"$qemu_bin" "${qemu_args[@]}" &
qemu_pid=$!

for ((attempt = 0; attempt < 100; attempt++)); do
  [[ -S $qmp_socket && -S $guest_socket && -S $settings_socket ]] && break
  kill -0 "$qemu_pid" 2>/dev/null || fail "QEMU exited before it was ready"
  sleep 0.05
done
"$native_bridge" --wait-for-qmp "$qemu_pid" "$qmp_socket" 9>&- || fail "QEMU's QMP monitor did not become ready"
echo "[qemu-gpu] Ready. QMP: $qmp_socket" >&2

# Optional host bridges. Each one reconnects on its own schedule; a bridge that
# keeps failing leaves only its feature unavailable.
"$native_bridge" --bridge-native-audio "$qemu_pid" "$audio_socket" "$audio_routes" 9>&- &
bridge_pids+=($!)
for bridge in clipboard:"$clipboard_socket" authentication:"$authentication_socket" \
  camera:"$camera_socket" battery:"$battery_socket" timezone:"$timezone_socket"; do
  "$native_bridge" "--bridge-native-${bridge%%:*}" "$qemu_pid" "${bridge#*:}" 9>&- &
  bridge_pids+=($!)
done
status_file="$vm_dir/guest-status.json"
[[ $storage_mode == persistent ]] || status_file="$work_dir/guest-status.json"
"$native_bridge" --bridge-guest-status "$qemu_pid" "$guest_socket" "$status_file" 9>&- &
bridge_pids+=($!)
if [[ $QEMU_NETWORK_MODE == bridged ]]; then
  "$native_bridge" --bridge-network-link "$qemu_pid" "$qmp_socket" "$QEMU_NETWORK_DIRECTORY/link-state" 9>&- &
  bridge_pids+=($!)
fi

if wait "$qemu_pid"; then qemu_status=0; else qemu_status=$?; fi
qemu_pid=""
exit "$qemu_status"
