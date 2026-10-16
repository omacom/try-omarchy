#!/bin/bash
#
# Checks of the owner's desktop session, as that user inside the container,
# after run.sh started Omarchy's session the way SDDM does (uwsm). States, not
# pixels: Hyprland's outputs, config errors, layers and clients. Screenshots
# go to /ci-run/screens for people to look at.
#
#   session-checks.sh [APP...]    APP: a command Omarchy's keybindings run
#                                 (default: the browser, files, a terminal and
#                                 the factory's own apps)
#
# Prints one "ok", "FAIL" or "note" line per check.

set -uo pipefail

ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; }
note() { echo "note $*"; }
screens=/ci-run/screens
mkdir -p "$screens"
export XDG_RUNTIME_DIR=/run/user/$(id -u)

wait_for() { # seconds command...
  local deadline=$((SECONDS + $1))
  shift
  until "$@" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || return 1
    sleep 1
  done
}

hypr_instance() {
  local dir
  for dir in "$XDG_RUNTIME_DIR"/hypr/*/; do
    [[ -S $dir/.socket.sock ]] && { basename "$dir"; return 0; }
  done
  return 1
}

start=$SECONDS
if ! wait_for 180 hypr_instance; then
  bad "Hyprland did not start within 180 s"
  systemctl --user --no-pager status 'wayland-wm@*' 2>&1 | tail -20 | sed 's/^/     /'
  journalctl --user -b --no-pager -n 40 -o cat 2>&1 | sed 's/^/     /'
  exit 0
fi
HYPRLAND_INSTANCE_SIGNATURE=$(hypr_instance)
export HYPRLAND_INSTANCE_SIGNATURE
for socket in "$XDG_RUNTIME_DIR"/wayland-[0-9]*; do
  [[ -S $socket ]] && { export WAYLAND_DISPLAY=${socket##*/}; break; }
done
hc() { hyprctl "$@" 2>/dev/null; }
# Omarchy's configuration is Lua: dispatchers are Lua expressions, as its
# keybindings and scripts use them.
run_cmd() { hc dispatch "hl.dsp.exec_cmd([[$1]])"; }
close_window() { hc dispatch "hl.dsp.window.close({ window = \"address:$1\" })"; }
outputs() { hc monitors -j | jq -e 'length > 0'; }
wait_for 60 outputs && ok "Hyprland is up with an output after $((SECONDS - start)) s ($(hc monitors -j | jq -r '.[0] | "\(.name) \(.width)x\(.height)"'))" ||
  bad "Hyprland has no output"

# No one types here: Omarchy's Stay Awake toggle keeps the screensaver and
# the lock away for the rest of the run.
omarchy-toggle-idle stay-awake >/dev/null 2>&1 && ok "Omarchy's Stay Awake toggle is on" || bad "omarchy-toggle-idle stay-awake failed"
# Logs for people reading a failed run.
trap 'journalctl --user -b --no-pager >/ci-run/user-journal.txt 2>&1; cp "$XDG_RUNTIME_DIR"/hypr/*/hyprland.log /ci-run/ 2>/dev/null' EXIT

errors=$(hc configerrors | sed '/^\s*$/d')
if [[ -z $errors || $errors == "no errors"* ]]; then ok "Hyprland loaded Omarchy's and try-omarchy's configuration without errors"
else bad "Hyprland configuration errors"; sed 's/^/     /' <<<"$errors"; fi

wait_for 60 systemctl --user is-active graphical-session.target &&
  ok "graphical-session.target is active (uwsm)" || bad "graphical-session.target never became active"

layer() { hc layers -j | jq -e --arg n "$1" '[.. | objects | select(.namespace? == $n)] | length > 0'; }
for namespace in omarchy-background omarchy-bar; do
  wait_for 120 layer "$namespace" && ok "the shell shows $namespace" || bad "the shell never showed $namespace"
done
sleep 2
grim "$screens/01-desktop.png" 2>/dev/null && ok "screenshot of the desktop" || bad "grim could not take a screenshot"

# --- try-omarchy's per-user setup -----------------------------------------------------
loader=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/toggles/hypr/zz-try-omarchy.lua
[[ -f $loader ]] && ok "try-omarchy's Hyprland loader is in Omarchy's toggles directory" || bad "no try-omarchy Hyprland loader at $loader"
menu=${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions/omarchy-menu.jsonc
grep -q '"setup.try-omarchy"' "$menu" 2>/dev/null && ok "try-omarchy's rows are in the Omarchy menu extension" ||
  bad "try-omarchy's menu rows are missing from $menu"

while read -r unit _; do
  [[ -n $unit ]] && { bad "user unit $unit failed"; journalctl --user -b -u "$unit" --no-pager -n 6 -o cat 2>&1 | sed 's/^/     /'; }
done < <(systemctl --user list-units --failed --plain --no-legend 2>/dev/null)
user_property() { systemctl --user show "$1" -p "$2" | sed "s/^$2=//"; }
for unit in $(awk '$1 == "enable" { print $2 }' /usr/lib/systemd/user-preset/80-try-omarchy.preset); do
  active=$(user_property "$unit" ActiveState)
  restarts=$(user_property "$unit" NRestarts)
  condition=$(user_property "$unit" ConditionResult)
  if [[ ${restarts:-0} != 0 ]]; then bad "$unit restarted $restarts times ($active)"
  elif [[ $active == failed ]]; then bad "$unit failed"
  elif [[ $condition == no ]]; then note "$unit skipped: its condition does not hold here"
  else note "$unit: $active"; fi
done

# --- the shell: menu and notifications --------------------------------------------
# As Super + Space runs it.
run_cmd "omarchy-menu summon" >/dev/null
if wait_for 30 layer omarchy-menu; then
  ok "Omarchy's menu opens"
  sleep 1
  grim "$screens/02-menu.png" 2>/dev/null
  run_cmd "omarchy-menu close" >/dev/null
  no_menu() { ! layer omarchy-menu; }
  wait_for 15 no_menu || note "Omarchy's menu did not close"
else
  bad "Omarchy's menu did not open"
fi
notify-send "Try Omarchy CI" "A notification from the desktop test" 2>/dev/null
if wait_for 20 layer omarchy-notifications; then
  ok "a notification shows"
  grim "$screens/03-notification.png" 2>/dev/null
else
  bad "a notification did not show"
fi

# --- apps -----------------------------------------------------------------------------
clients() { hc clients -j | jq -r '.[] | select(.class != "org.omarchy.screensaver") | .address' | sort; }
index=4
# Runs CMD the way a keybinding does and waits for its window; with VAR=VALUE,
# the window's process must have that in its environment.
try_app() { # label cmd [VAR=VALUE]
  local label=$1 cmd=$2 want=${3:-} before launched new="" class pid
  before=$(clients)
  launched=$SECONDS
  run_cmd "$cmd" >/dev/null
  appeared() { new=$(comm -13 <(printf '%s\n' "$before") <(clients) | head -1); [[ -n $new ]]; }
  if ! wait_for 120 appeared; then
    bad "$label opened no window within 120 s"
    journalctl --user -b --no-pager -o cat --since "-125s" 2>/dev/null | grep -v '^\s*$' | tail -12 | sed 's/^/     /'
    return
  fi
  class=$(hc clients -j | jq -r --arg a "$new" '.[] | select(.address == $a) | .class')
  pid=$(hc clients -j | jq -r --arg a "$new" '.[] | select(.address == $a) | .pid')
  ok "$label opens a window ($class) in $((SECONDS - launched)) s"
  if [[ -n $want ]]; then
    if tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx "$want"; then
      ok "$label runs with $want (try-omarchy's wrapper)"
    else
      bad "$label runs without $want: the launch path bypassed try-omarchy's wrapper"
    fi
  fi
  sleep 3
  grim "$screens/$(printf '%02d' "$index")-${label// /-}.png" 2>/dev/null
  index=$((index + 1))
  close_window "$new" >/dev/null
  gone() { ! hc clients -j | jq -e --arg a "$new" 'any(.[]; .address == $a)'; }
  wait_for 30 gone || note "$label's window did not close within 30 s"
}

apps=("$@")
((${#apps[@]})) || apps=(omarchy-launch-browser omarchy-launch-nautilus foot obsidian localsend pinta "libreoffice --writer" evince)
for app in "${apps[@]}"; do
  try_app "${app%% *}" "$app"
done

# --- installing apps the way Omarchy's Install menu does ---------------------------
for package in cmatrix sl cowsay; do
  pacman -Si "$package" >/dev/null 2>&1 || continue
  if omarchy-pkg-add "$package" >/tmp/pkg-add.log 2>&1 && pacman -Q "$package" >/dev/null 2>&1; then
    ok "omarchy-pkg-add installs $package from Omarchy's repositories"
  else
    bad "omarchy-pkg-add $package failed"; tail -10 /tmp/pkg-add.log | sed 's/^/     /'
  fi
  break
done
# Terminals that need desktop OpenGL above what VirGL offers run through
# try-omarchy's software-renderer wrappers when Omarchy launches them.
for terminal in ${CI_TERMINALS:-ghostty kitty}; do
  if omarchy-install-terminal "$terminal" >/tmp/install-terminal.log 2>&1 && pacman -Q "$terminal" >/dev/null 2>&1; then
    ok "omarchy-install-terminal installs $terminal"
    try_app "$terminal from Omarchy's terminal launcher" omarchy-launch-terminal LIBGL_ALWAYS_SOFTWARE=1
  else
    bad "omarchy-install-terminal $terminal failed"; tail -10 /tmp/install-terminal.log | sed 's/^/     /'
  fi
done

dumps=$(coredumpctl list --no-pager --no-legend 2>/dev/null)
if [[ -n $dumps ]]; then bad "processes dumped core in the session"; sed 's/^/     /' <<<"$dumps"
else ok "no core dumps in the session"; fi
