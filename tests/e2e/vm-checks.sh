#!/bin/bash
#
# What only the real VM has, as root in the guest: the Mac on the other side of
# the virtio ports, VirGL on the Mac's GPU, and the shared folder.
#
#   vm-checks.sh USER MAC_TIME_ZONE [SHARE_TOKEN]
#
# SHARE_TOKEN: the content of e2e-from-mac.txt in the shared folder; the
# guest writes e2e-from-guest.txt back. Prints "ok", "FAIL" or "note" lines.

set -uo pipefail
user=$1
mac_zone=$2
share_token=${3:-}
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; }
note() { echo "note $*"; }
uid=$(id -u "$user")
as_user() { runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"; }

# --- the Mac's ports ---------------------------------------------------------------------
for port in audio clipboard camera battery timezone settings authentication guest; do
  [[ -e /dev/virtio-ports/dev.tryomarchy.$port ]] && ok "port dev.tryomarchy.$port" || bad "no port dev.tryomarchy.$port"
done
[[ -s /run/try-omarchy/cmdline ]] && ok "host settings credential published: $(tr '\n' ' ' </run/try-omarchy/cmdline | cut -c1-120)" ||
  bad "no host settings at /run/try-omarchy/cmdline"

for unit in try-omarchy-timezone.service try-omarchy-guest-status.service omarchy-native-battery-bridge.service; do
  [[ $(systemctl is-active "$unit") == active ]] && ok "$unit is active" || bad "$unit is $(systemctl is-active "$unit")"
done
for unit in omarchy-native-audio-bridge.service omarchy-native-camera-bridge.service omarchy-native-clipboard-bridge.service; do
  active=$(as_user systemctl --user show "$unit" -p ActiveState | sed 's/^ActiveState=//')
  restarts=$(as_user systemctl --user show "$unit" -p NRestarts | sed 's/^NRestarts=//')
  if [[ $active == active && ${restarts:-0} == 0 ]]; then ok "$unit is active"; else bad "$unit: $active, $restarts restarts"; fi
done

# --- integrations ----------------------------------------------------------------------
zone=$(timedatectl show -p Timezone --value)
[[ $zone == "$mac_zone" ]] && ok "the time zone follows the Mac ($zone)" || bad "time zone $zone, the Mac's is $mac_zone"
battery=$(upower -e 2>/dev/null | grep -m1 battery)
if [[ -n $battery ]]; then
  ok "the Mac's battery: $(upower -i "$battery" | awk '/percentage|state:/ { printf "%s %s ", $1, $2 }')"
else
  note "no battery in the guest (a Mac without one, or the bridge is missing)"
fi
if grep -qx 'Mac Camera' /sys/class/video4linux/*/name 2>/dev/null; then ok "the Mac camera is a V4L2 device"
else bad "no Mac Camera V4L2 device"; fi
sink=$(as_user wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null | awk -F'"' '/node.description/ { print $2; exit }')
[[ -n $sink ]] && ok "PipeWire's default output: $sink" || bad "PipeWire has no default output"
source=$(as_user wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | awk -F'"' '/node.description/ { print $2; exit }')
[[ -n $source ]] && ok "PipeWire's default input: $source" || bad "PipeWire has no default input"

# --- graphics ------------------------------------------------------------------------------
if as_user cc -O2 -o /tmp/virgl-smoke /ci/virgl-smoke.c -lEGL -lGLESv2 2>/tmp/virgl-smoke.log; then
  output=$(as_user /tmp/virgl-smoke 2>&1)
  if grep -q '^PASS' <<<"$output"; then ok "VirGL renders on the Mac's GPU: $(grep -m1 '^renderer' <<<"$output")"
  else bad "the rendering smoke test failed"; sed 's/^/     /' <<<"$output"; fi
else
  bad "the rendering smoke test does not compile"; tail -5 /tmp/virgl-smoke.log | sed 's/^/     /'
fi

# --- shared folder ---------------------------------------------------------------------
if [[ -n $share_token ]]; then
  if [[ $(cat /mnt/mac/e2e-from-mac.txt 2>/dev/null) == "$share_token" ]]; then ok "the guest reads the Mac's shared folder"
  else bad "the guest cannot read the Mac's file in /mnt/mac"; fi
  if as_user sh -c "printf '%s' '$share_token' >/mnt/mac/e2e-from-guest.txt"; then ok "the user writes to the shared folder"
  else bad "the user cannot write to /mnt/mac"; fi
  link=$(find "/home/$user" -maxdepth 1 -type l -lname '/mnt/mac*' 2>/dev/null | head -1)
  [[ -n $link ]] && ok "the home folder links the share (${link##*/})" || bad "no link to /mnt/mac in the home folder"
fi
