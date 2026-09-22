#!/bin/bash
# Install the host battery integration into an EXISTING Try Omarchy guest.
#
# Run INSIDE the guest as root, against files staged through the shared Mac
# folder (never the network):
#
#   1. On the Mac, copy these repo paths into the shared folder, preserving
#      the layout below.
#   2. In the guest: sudo ~/<folder>/battery-retrofit/install-battery-into-existing-guest.sh
#
# Expected staging layout (--source defaults to this script's directory):
#   native-module/try-omarchy-battery/{try-omarchy-battery.c,Makefile,dkms.conf}
#   native-overlay/usr/local/bin/omarchy-native-battery-bridge
#   native-overlay/usr/lib/systemd/system/omarchy-native-battery-bridge.service
#   native-overlay/etc/udev/rules.d/95-omarchy-native-battery.rules
#   native-overlay/etc/modules-load.d/95-try-omarchy-battery.conf
#   native-overlay/etc/UPower/UPower.conf.d/90-try-omarchy.conf
#
# A factory reset is never required; the DKMS hook rebuilds the module on
# every guest kernel update from then on.

set -euo pipefail

fail() {
  echo "install-battery: $*" >&2
  exit 1
}

source_dir=$(cd "$(dirname "$0")" && pwd -P)
while (($#)); do
  case "$1" in
    --source)
      source_dir=${2:-}
      shift 2
      ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

(( EUID == 0 )) || fail "run as root (sudo)"
[[ -e /dev/virtio-ports/dev.tryomarchy.battery ]] ||
  fail "no battery port; update the Try Omarchy app on the Mac first"
for command in dkms install modprobe systemctl udevadm; do
  command -v "$command" >/dev/null || fail "$command is required"
done

module_source="$source_dir/native-module/try-omarchy-battery"
overlay="$source_dir/native-overlay"
for file in \
  "$module_source/try-omarchy-battery.c" \
  "$module_source/Makefile" \
  "$module_source/dkms.conf" \
  "$overlay/usr/local/bin/omarchy-native-battery-bridge" \
  "$overlay/usr/lib/systemd/system/omarchy-native-battery-bridge.service" \
  "$overlay/etc/udev/rules.d/95-omarchy-native-battery.rules" \
  "$overlay/etc/modules-load.d/95-try-omarchy-battery.conf" \
  "$overlay/etc/UPower/UPower.conf.d/90-try-omarchy.conf"; do
  [[ -f $file ]] || fail "staged file is missing: $file"
done

version=1.0.0
module_dest=/usr/src/try-omarchy-battery-1.0.0
[[ $module_dest == "/usr/src/try-omarchy-battery-$version" ]] ||
  fail "module destination does not match version $version"
install -d -m 0755 "$module_dest"
install -m 0644 "$module_source/try-omarchy-battery.c" /usr/src/try-omarchy-battery-1.0.0/try-omarchy-battery.c
install -m 0644 "$module_source/Makefile" /usr/src/try-omarchy-battery-1.0.0/Makefile
install -m 0644 "$module_source/dkms.conf" /usr/src/try-omarchy-battery-1.0.0/dkms.conf
install -m 0755 "$overlay/usr/local/bin/omarchy-native-battery-bridge" \
  /usr/local/bin/omarchy-native-battery-bridge
install -m 0644 "$overlay/usr/lib/systemd/system/omarchy-native-battery-bridge.service" \
  /usr/lib/systemd/system/omarchy-native-battery-bridge.service
install -m 0644 "$overlay/etc/udev/rules.d/95-omarchy-native-battery.rules" \
  /etc/udev/rules.d/95-omarchy-native-battery.rules
install -m 0644 "$overlay/etc/modules-load.d/95-try-omarchy-battery.conf" \
  /etc/modules-load.d/95-try-omarchy-battery.conf
install -d -m 0755 /etc/UPower/UPower.conf.d
install -m 0644 "$overlay/etc/UPower/UPower.conf.d/90-try-omarchy.conf" \
  /etc/UPower/UPower.conf.d/90-try-omarchy.conf

if ! dkms status "try-omarchy-battery/$version" 2>/dev/null | grep -q installed; then
  [[ $version == 1.0.0 ]] || fail "unexpected module version: $version"
  dkms install try-omarchy-battery/1.0.0
fi
modprobe try_omarchy_battery
udevadm control --reload
udevadm trigger --subsystem-match=virtio-ports
systemctl daemon-reload
systemctl enable --now omarchy-native-battery-bridge.service
systemctl try-restart upower.service 2>/dev/null || true

echo "install-battery: done — the bar battery appears within 30 seconds"
