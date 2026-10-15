#!/bin/bash
#
# Contract test for run-shell-guest.sh: a fake app bundle with shimmed QEMU,
# helper and zstd, driven through the dry-run path. Checks the UEFI boot,
# the host-settings credential, the integration package offer, storage
# layout and resets. Runs no VM.

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd -P)
macos_dir=$(cd "$test_dir/.." && pwd -P)

fail() {
  printf 'run-shell-guest.test: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  [[ $1 == *"$2"* ]] || fail "expected output to contain [$2], got [$1]"
}

assert_not_contains() {
  [[ $1 != *"$2"* ]] || fail "expected output not to contain [$2]"
}

test_root=$(mktemp -d '/private/tmp/omarchy-shell-test.XXXXXX')
trap '/bin/rm -rf "$test_root"' EXIT HUP INT TERM

app="$test_root/Try Omarchy.app"
resources="$app/Contents/Resources"
shims="$test_root/bin"
mkdir -p "$app/Contents/MacOS" "$resources/guest" "$resources/guest-packages" "$resources/firmware" \
  "$resources/runtime/bin" "$resources/scripts" "$shims"
cp "$macos_dir/run-shell-guest.sh" "$resources/scripts/run-qemu-gpu.sh"
cp "$macos_dir/qemu-port-forwarding.sh" "$macos_dir/qemu-networking.sh" "$resources/scripts/"
chmod 755 "$resources/scripts/run-qemu-gpu.sh"

cat >"$app/Contents/MacOS/omarchy-vm-helper" <<'SH'
#!/bin/bash
case $1 in
  --host-keyboard-geometry) echo jis ;;
  --host-timezone) echo America/Sao_Paulo ;;
  *) exit 1 ;;
esac
SH
# The nested-virtualization probe fails, as on M1/M2 Macs.
printf '#!/bin/bash\nexit 1\n' >"$resources/runtime/bin/Try Omarchy"
# The fake factory is stored uncompressed; "decompressing" copies it.
cat >"$resources/runtime/bin/zstd" <<'SH'
#!/bin/bash
while (($#)); do
  case $1 in
    -o) out=$2; shift 2 ;;
    -*) shift ;;
    *) in=$1; shift ;;
  esac
done
cp "$in" "$out"
SH
printf '#!/bin/sh\nexit 0\n' >"$shims/codesign"
chmod 755 "$app/Contents/MacOS/omarchy-vm-helper" "$resources/runtime/bin/Try Omarchy" \
  "$resources/runtime/bin/zstd" "$shims/codesign"

dd if=/dev/zero of="$resources/guest/omarchy-aarch64-edge.img.zst" bs=1048576 count=4 2>/dev/null
sha=$(shasum -a 256 "$resources/guest/omarchy-aarch64-edge.img.zst" | cut -d' ' -f1)
cat >"$resources/guest/factory.json" <<JSON
{"format":1,"kind":"upstream-shell-factory","boot":"uefi-limine",
 "disk":{"path":"omarchy-aarch64-edge.img","bytes":4194304,"sha256":"$sha"},
 "compressed":{"path":"omarchy-aarch64-edge.img.zst","sha256":"$sha"}}
JSON
printf 'firmware' >"$resources/firmware/edk2-aarch64-code.fd"
printf 'package' >"$resources/guest-packages/try-omarchy-0.2.0-1-aarch64.pkg.tar.zst"

launch() { # args...
  env PATH="$shims:$PATH" OMARCHY_QEMU_GPU_STATE_ROOT="$test_root/state" OMARCHY_QEMU_GPU_DRY_RUN=1 \
    OMARCHY_QEMU_GPU_CPUS=4 OMARCHY_QEMU_GPU_MEMORY_MIB=2048 "${launch_env[@]}" \
    "$resources/scripts/run-qemu-gpu.sh" "$@" 2>&1 | sed 's/\\//g'
  return "${PIPESTATUS[0]}"
}

# Inspect-only reports the factory identity and size for build-app.sh.
record=$(env OMARCHY_QEMU_GPU_INSPECT_ONLY=1 "$resources/scripts/run-qemu-gpu.sh")
[[ $record == "$sha"$'\t'4194304 ]] || fail "unexpected inspect record: $record"

# A first persistent launch creates the VM from the factory.
launch_env=(OMARCHY_QEMU_GPU_PORT_FORWARDS=tcp:2222:22 OMARCHY_QEMU_GPU_LOCALE=ja_JP.UTF-8 OMARCHY_QEMU_GPU_DISK_GIB=1)
output=$(launch)
assert_contains "$output" "if=pflash,format=raw,readonly=on,file=$resources/firmware/edk2-aarch64-code.fd"
assert_contains "$output" "if=pflash,format=raw,file=$test_root/state/shell/efi-vars.fd"
assert_not_contains "$output" " -kernel "
assert_not_contains "$output" " -append "
assert_contains "$output" "host settings: omarchy.qemu_virgl=1 omarchy.virgl_dual_source=1 tryomarchy.ssh_access=1 tryomarchy.keyboard=jis tryomarchy.locale=ja_JP.UTF-8 tryomarchy.timezone=America/Sao_Paulo"
credential=$(printf '%s' 'omarchy.qemu_virgl=1 omarchy.virgl_dual_source=1 tryomarchy.ssh_access=1 tryomarchy.keyboard=jis tryomarchy.locale=ja_JP.UTF-8 tryomarchy.timezone=America/Sao_Paulo' | base64 | tr -d '\n')
assert_contains "$output" "io.systemd.credential.binary:tryomarchy.host=$credential"
package=$(printf '%s' try-omarchy-0.2.0-1-aarch64.pkg.tar.zst | base64 | tr -d '\n')
assert_contains "$output" "io.systemd.credential.binary:tryomarchy.package=$package"
assert_contains "$output" "mount_tag=tryomarchy-packages"
assert_contains "$output" "name=dev.tryomarchy.guest"
assert_contains "$output" "Nested virtualization is unavailable"
assert_contains "$output" "[qemu-gpu] Launch phase: preparing"
# The app accepts only this QMP path shape (QEMUGPULauncher.qmpSocketPath).
[[ $output =~ unix:/tmp/omarchy-qemu-gpu\.[A-Za-z0-9]{6}/qmp\.sock, ]] || fail "the QMP socket path is not one the app accepts"
[[ -f $test_root/state/shell/disk.img && -f $test_root/state/shell/efi-vars.fd && -f $test_root/state/shell/vm.json ]] ||
  fail "the persistent VM was not created"
[[ $(stat -f %z "$test_root/state/shell/disk.img") == 1073741824 ]] || fail "the disk was not grown to 1 GiB"
[[ $(stat -f %z "$test_root/state/shell/efi-vars.fd") == 67108864 ]] || fail "the variable store is not 64 MiB"
[[ $(stat -f %Lp "$test_root/state/shell/disk.img") == 600 ]] || fail "the disk is not private"
[[ $(<"$test_root/state/.omarchy-qemu-storage") == omarchy-qemu-storage-root-v1 ]] || fail "no storage-root marker"

# The VM persists: a second launch keeps the disk.
printf 'guest data' | dd of="$test_root/state/shell/disk.img" conv=notrunc 2>/dev/null
launch_env=(OMARCHY_SHELL_INSTALL_PACKAGE=)
output=$(launch)
[[ $(head -c 10 "$test_root/state/shell/disk.img") == 'guest data' ]] || fail "the persistent disk was replaced"
assert_not_contains "$output" "tryomarchy.package"
assert_not_contains "$output" "tryomarchy.ssh_access"

# A reset replaces it from the factory.
output=$(launch --reset-storage-only)
assert_contains "$output" "Reset complete"
[[ ! -e $test_root/state/shell/disk.img ]] || fail "reset kept the disk"

# An ephemeral launch leaves the persistent store alone.
launch_env=()
output=$(launch --ephemeral)
[[ ! -e $test_root/state/shell/disk.img ]] || fail "an ephemeral launch created the persistent disk"
assert_contains "$output" "/private/tmp/omarchy-qemu-gpu."

# Invalid inputs are refused before anything starts.
launch_env=(OMARCHY_SHELL_INSTALL_PACKAGE=/etc/hosts)
output=$(launch) && fail "an arbitrary install package was accepted"
assert_contains "$output" "invalid integration package"
launch_env=(OMARCHY_QEMU_GPU_LOCALE=xx_XX.UTF-8)
output=$(launch) && fail "an unknown locale was accepted"
assert_contains "$output" "unsupported guest locale"

echo "run-shell-guest.test: ok"
