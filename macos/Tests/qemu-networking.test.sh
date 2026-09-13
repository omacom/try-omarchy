#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
source "$root/qemu-networking.sh"
fail() { echo "qemu-networking.test: $*" >&2; exit 1; }
test_root=$(mktemp -d /private/tmp/omarchy-network-test.XXXXXX)
trap 'rm -rf "$test_root"' EXIT
qemu_network_validate
[[ $QEMU_NETWORK_MODE == nat ]] || fail 'default is not NAT'
[[ $(qemu_network_mac) == 52:54:00:12:34:56 ]] || fail 'NAT identity changed'
for invalid in unknown NAT ''; do
  if (OMARCHY_NETWORK_MODE="${invalid:-bad}"; qemu_network_validate) 2>/dev/null; then fail 'invalid mode accepted'; fi
done
OMARCHY_NETWORK_MODE=bridged OMARCHY_NETWORK_INTERFACE=en0
qemu_network_validate
QEMU_SELECTED_STORAGE_MODE=ephemeral QEMU_SELECTED_DISK=''
first=$(qemu_network_mac)
[[ $first =~ ^02(:[0-9a-f]{2}){5}$ ]] || fail 'invalid bridge MAC'
[[ $first != "$(qemu_network_mac)" ]] || fail 'ephemeral identities reused'
mkdir -p "$test_root/disks/current"
printf 'disk' >"$test_root/disks/current/rootfs.ext4"
QEMU_PERSISTENT_STORAGE_DISKS_ROOT="$test_root/disks"
QEMU_SELECTED_DISK="$test_root/disks/current/rootfs.ext4"
QEMU_SELECTED_STORAGE_MODE=persistent
first=$(qemu_network_mac)
[[ $first == "$(qemu_network_mac)" ]] || fail 'persistent identity changed'
cp "$QEMU_SELECTED_DISK" "$QEMU_SELECTED_DISK.new"
mv "$QEMU_SELECTED_DISK.new" "$QEMU_SELECTED_DISK"
second=$(qemu_network_mac)
[[ $first != "$second" ]] || fail 'replacement disk reused identity'
[[ $second == "$(qemu_network_mac)" ]] || fail 'replacement identity not retained'
chmod 644 "$test_root/network-identities/current.json"
if qemu_network_mac >/dev/null 2>&1; then fail 'unsafe record permissions accepted'; fi
chmod 600 "$test_root/network-identities/current.json"
mv "$test_root/network-identities/current.json" "$test_root/record"
ln -s "$test_root/record" "$test_root/network-identities/current.json"
if qemu_network_mac >/dev/null 2>&1; then fail 'symlink record accepted'; fi
[[ -s $test_root/record ]] || fail 'symlink target modified'
echo 'qemu-networking.test: PASS'
