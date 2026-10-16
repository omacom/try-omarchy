#!/bin/bash
#
# In the guest, as the desktop user: what the end-to-end run's keyboard checks
# read back after pressing keys on the VM's keyboard.
#
#   hypr-state.sh windows    the number of windows
#   hypr-state.sh menu       exits 0 while Omarchy's menu is open

set -uo pipefail
export XDG_RUNTIME_DIR=/run/user/$(id -u)
for dir in "$XDG_RUNTIME_DIR"/hypr/*/; do
  if [[ -S $dir/.socket.sock ]]; then
    dir=${dir%/}
    export HYPRLAND_INSTANCE_SIGNATURE=${dir##*/}
  fi
done
case ${1:-} in
  windows) hyprctl clients -j | jq length ;;
  menu) hyprctl layers -j | jq -e '[.. | objects | select(.namespace? == "omarchy-menu")] | length > 0' >/dev/null ;;
  *) echo "usage: hypr-state.sh windows|menu" >&2; exit 64 ;;
esac
