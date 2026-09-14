#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
source "$root/qemu-networking.sh"
fail() { echo "qemu-networking.test: $*" >&2; exit 1; }
test_root=$(mktemp -d /private/tmp/omarchy-network-test.XXXXXX)
network_stage=''
trap 'rm -rf "$test_root"; [[ -z $network_stage ]] || rm -rf "$network_stage"' EXIT
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

# Exercise the real startup function under the launcher's /bin/bash. The XPC
# client must be a direct child of that launcher for daemon authorization.
network_stage=$(mktemp -d /private/tmp/omarchy-network.XXXXXX)
mkdir -p "$test_root/resources/network" "$test_root/session"
touch "$network_stage/ready"
python3 - "$network_stage/network.sock" <<'PY'
import socket, sys
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
    listener.bind(sys.argv[1])
PY
cat >"$test_root/client-parent.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(void) {
    if (getppid() != atoi(getenv("EXPECTED_LAUNCHER_PID"))) {
        fputs("Networking client is not a direct child of the launcher\n", stderr);
        return 1;
    }
    puts(getenv("NETWORK_STAGE"));
    return 0;
}
C
cc -Wall -Wextra -Werror "$test_root/client-parent.c" -o "$test_root/resources/network/omarchy-network-client"
for helper in omarchy-network-supervisor socket_vmnet; do
  cp "$test_root/resources/network/omarchy-network-client" "$test_root/resources/network/$helper"
done
NETWORK_STAGE="$network_stage" /bin/bash -eu -o pipefail -c '
  source "$1/qemu-networking.sh"
  fail() { echo "$*" >&2; exit 1; }
  export EXPECTED_LAUNCHER_PID=$$
  OMARCHY_NETWORK_MODE=bridged OMARCHY_NETWORK_INTERFACE=en0
  qemu_network_validate
  qemu_network_start "$2/resources" "$2/session"
  [[ $QEMU_NETWORK_DIRECTORY == "$NETWORK_STAGE" ]]
  [[ $QEMU_NETWORK_NETDEV == "stream,id=omarchy-net,server=off,addr.type=unix,addr.path=$NETWORK_STAGE/network.sock" ]]
' networking-start-test "$root" "$test_root"
echo 'qemu-networking.test: PASS'
