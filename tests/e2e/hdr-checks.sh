#!/bin/bash
# Numeric checks inside the disposable owner session; no screen capture.
set -euo pipefail
user=${1:?}
uid=$(id -u "$user")
ok() { echo "ok   HDR: $*"; }
fail() { echo "FAIL HDR: $*"; exit 1; }
module=$(modinfo -n virtio_gpu)
[[ $module == */updates/dkms/virtio-gpu.ko* ]] || fail 'the DRM override is not selected'
ok "kernel $(uname -r) selects the DKMS driver"
read -r name version < /usr/share/try-omarchy/hdr/version
[[ $(pacman -Q hyprland) == "$name $version" ]] || fail 'the compositor companion is not installed'
pid=$(pgrep -u "$uid" -x Hyprland | head -1)
[[ $(sha256sum "/proc/$pid/exe" | cut -d' ' -f1) == $(sha256sum /usr/bin/Hyprland | cut -d' ' -f1) ]] || fail 'the running compositor differs from the installed binary'
ok "running compositor matches $version"
signature=''
for directory in /run/user/"$uid"/hypr/*; do
  [[ -S $directory/.socket.sock ]] && signature=${directory##*/}
done
[[ -n $signature ]] || fail 'no owner compositor socket'
monitor=$(runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" HYPRLAND_INSTANCE_SIGNATURE="$signature" hyprctl -j monitors)
printf '%s\n' "$monitor" > /ci-run/hdr-monitors.json
if ! jq -e 'length > 0 and all(.[]; .currentFormat == "XRGB2101010" and .colorManagementPreset == "hdredid" and .sdrMaxLuminance == 100)' <<< "$monitor" >/dev/null; then
  jq -c '[.[] | {name,currentFormat,colorManagementPreset,sdrMaxLuminance}]' <<< "$monitor"
  for edid in /sys/class/drm/card*-Virtual-*/edid; do
    /usr/lib/try-omarchy/hdr-monitor-policy "$edid"
  done
  fail 'output is not ten-bit PQ with the paired reference'
fi
ok "output: $(jq -c '[.[] | {name,width,height,refreshRate,scale,currentFormat,colorManagementPreset,sdrMaxLuminance}]' <<< "$monitor")"
errors=$(runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" HYPRLAND_INSTANCE_SIGNATURE="$signature" hyprctl configerrors)
[[ -z $errors || $errors == 'ok' ]] || fail "compositor configuration errors: $errors"
ok 'no compositor configuration errors'
stamp=/var/lib/try-omarchy/hdr-installed.sha256
[[ -f $stamp ]] || fail 'installer state is missing'
before=$(stat -c '%Y:%y' "$stamp")
/usr/lib/try-omarchy/hdr-install
[[ $(stat -c '%Y:%y' "$stamp") == "$before" ]] || fail 'unchanged installer rewrote its state'
ok 'unchanged installer skips driver/initramfs work'
