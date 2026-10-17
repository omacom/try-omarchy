#!/bin/bash
#
# Checks of the owner's desktop session, as that user inside the container,
# after run.sh started Omarchy's session the way SDDM does (uwsm). States, not
# pixels: Hyprland's outputs, config errors, layers and clients. Screenshots
# go to /ci-run/screens for people to look at.
#
#   session-checks.sh [APP...]    APP: a command Omarchy's keybindings run
#                                 (default: files, a terminal and the
#                                 factory's own apps)
#
# CI_INSTALLS names the apps to install the way Omarchy's Install menu does
# and then open (default: ghostty kitty 1password; also vscode, signal; empty
# for none). Text is typed through a virtual keyboard (wtype).
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
# The environment uwsm gives the session's apps (OMARCHY_PATH, PATH, the XDG
# variables), as a terminal in the session has it.
while IFS= read -r variable; do
  [[ $variable == *=\$\'* ]] && continue
  case ${variable%%=*} in '' | *[!A-Za-z0-9_]*) continue ;; esac
  export "$variable"
done < <(systemctl --user show-environment 2>/dev/null)
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
# The container has no keyboard, so the seat has none either until a wtype
# connects one. Each wtype would then add a keyboard, press its keys and leave
# before Omarchy's shell has bound it, losing them (the menu missed Escape).
# An idle wtype keeps one keyboard on the seat for the whole run, as a real
# machine has.
wtype -s 3600000 2>/dev/null &
keyboard=$!
# Logs for people reading a failed run.
trap 'kill "$keyboard" 2>/dev/null; journalctl --user -b --no-pager >/ci-run/user-journal.txt 2>&1; cp "$XDG_RUNTIME_DIR"/hypr/*/hyprland.log /ci-run/ 2>/dev/null' EXIT

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

# --- windows -----------------------------------------------------------------------------
clients() { hc clients -j | jq -r '.[] | select(.class != "org.omarchy.screensaver") | .address' | sort; }
client_field() { hc clients -j | jq -r --arg a "$1" --arg f "$2" '.[] | select(.address == $a) | .[$f]'; }
index=2
shot() { grim "$screens/$(printf '%02d' "$index")-${1// /-}.png" 2>/dev/null; index=$((index + 1)); }
window=""
# Runs COMMAND... here and waits for the window it opens; sets $window. With
# WANT (VAR=VALUE), the window's process must have it in its environment.
opened_by() { # label want command...
  local label=$1 want=$2 before launched
  shift 2
  before=$(clients)
  launched=$SECONDS
  window=""
  "$@" >/dev/null 2>&1
  appeared() { window=$(comm -13 <(printf '%s\n' "$before") <(clients) | head -1); [[ -n $window ]]; }
  if ! wait_for 120 appeared; then
    bad "$label opened no window within 120 s"
    journalctl --user -b --no-pager -o cat --since "-125s" 2>/dev/null | grep -v '^\s*$' | tail -12 | sed 's/^/     /'
    return 1
  fi
  ok "$label opens a window ($(client_field "$window" class)) in $((SECONDS - launched)) s"
  if [[ -n $want ]]; then
    if tr '\0' '\n' <"/proc/$(client_field "$window" pid)/environ" 2>/dev/null | grep -qx "$want"; then
      ok "$label runs with $want (try-omarchy's wrapper)"
    else
      bad "$label runs without $want: the launch path bypassed try-omarchy's wrapper"
    fi
  fi
}
close_current() { # label
  local target=$window
  close_window "$target" >/dev/null
  gone() { ! hc clients -j | jq -e --arg a "$target" 'any(.[]; .address == $a)'; }
  wait_for 30 gone || note "$1's window did not close within 30 s"
}
# CMD the way a keybinding runs it.
try_app() { # label cmd [want]
  opened_by "$1" "${3:-}" run_cmd "$2" || return 0
  sleep 3
  shot "$1"
  close_current "$1"
}

# --- the shell and Omarchy's keybindings ---------------------------------------------
# A virtual keyboard (wtype) types into windows; Hyprland's bindings take real
# keyboards only, so tests/e2e presses those through QEMU's keyboard. Here the
# bindings must exist and the commands they run must work.
bound() { # modmask key description
  hc binds -j | jq -e --argjson m "$1" --arg k "$2" --arg d "$3" \
    'any(.[]; .modmask == $m and (.key | ascii_upcase) == $k and .description == $d)' >/dev/null
}
for binding in "64 RETURN Terminal" "64 SPACE Omarchy menu"; do
  read -r modmask key description <<<"$binding"
  bound "$modmask" "$key" "$description" && ok "Super + ${key,,} is bound to $description" ||
    bad "Super + ${key,,} is not bound to $description"
done

run_cmd "omarchy-menu summon" >/dev/null
if wait_for 30 layer omarchy-menu; then
  ok "Omarchy's menu opens (the command Super + Space runs)"
  sleep 1
  shot menu
  no_menu() { ! layer omarchy-menu; }
  wtype -k Escape 2>/dev/null
  if wait_for 5 no_menu; then
    ok "Escape closes the menu"
  else
    bad "Escape did not close the menu"
    run_cmd "omarchy-menu close" >/dev/null
  fi
else
  bad "Omarchy's menu did not open"
fi
notify-send "Try Omarchy CI" "A notification from the desktop test" 2>/dev/null
if wait_for 20 layer omarchy-notifications; then
  ok "a notification shows"
  shot notification
else
  bad "a notification did not show"
fi

token=$RANDOM$RANDOM
if opened_by "the terminal (the command Super + Return runs)" "" run_cmd omarchy-launch-terminal; then
  sleep 3
  wtype "echo \$((6 * 7)) $token > /ci-run/typed.txt" 2>/dev/null
  wtype -k Return 2>/dev/null
  typed() { [[ $(cat /ci-run/typed.txt 2>/dev/null) == "42 $token" ]]; }
  wait_for 15 typed && ok "a command typed into the terminal runs" || bad "a command typed into the terminal did not run"
  shot terminal
  close_current "the terminal"
else
  { echo "xdg-terminal-exec picks: $(xdg-terminal-exec --print-id 2>&1)"; cat ~/.config/xdg-terminals.list 2>&1; } | sed 's/^/     /'
fi

printf '%s' "$token" | wl-copy 2>/dev/null
[[ $(wl-paste -n 2>/dev/null) == "$token" ]] && ok "copy and paste" || bad "what was copied does not paste"

# --- the browser, with a page ---------------------------------------------------------
title="Try Omarchy CI page $token"
printf '<!doctype html><title>%s</title><h1>%s</h1>\n' "$title" "$title" >/ci-run/page.html
if opened_by "the browser" "" run_cmd "omarchy-launch-browser file:///ci-run/page.html"; then
  loaded() { [[ $(client_field "$window" title) == *"$title"* ]]; }
  wait_for 45 loaded && ok "the browser shows a local page" || bad "the browser's title never became the page's ($(client_field "$window" title))"
  shot browser
  close_current "the browser"
fi

# --- screen recording ---------------------------------------------------------------
videos=$(xdg-user-dir VIDEOS 2>/dev/null || echo "$HOME/Videos")
mkdir -p "$videos"
before_videos=$(ls "$videos")
OMARCHY_SCREENRECORD_DEBUG=true omarchy-capture-screenrecording --fullscreen >/tmp/screenrecord.log 2>&1 &
# Process names stop at 15 characters ("gpu-screen-reco"): match the command.
recording() { pgrep -u "$(id -u)" -f '(^|/)(wf-recorder|gpu-screen-recorder)( |$)'; }
if wait_for 20 recording; then
  recorder=$(recording | head -1 | xargs -r ps -o args= -p | awk '{ sub(".*/", "", $1); print $1 }')
  sleep 3
  omarchy-capture-screenrecording --stop-recording >>/tmp/screenrecord.log 2>&1
  new_video() { video=$(comm -13 <(printf '%s\n' "$before_videos") <(ls "$videos") | head -1); [[ -n $video && -s $videos/$video ]]; }
  if wait_for 20 new_video; then ok "Omarchy's screen recording saves a video ($recorder: $video)"
  else bad "the screen recording saved no video"; tail -8 /tmp/screenrecord.log | sed 's/^/     /'; fi
else
  bad "Omarchy's screen recording did not start"
  tail -8 /tmp/screenrecord.log "$XDG_RUNTIME_DIR/omarchy-screenrecord.log" 2>/dev/null | sed 's/^/     /'
fi

# --- a theme switch -----------------------------------------------------------------
theme_name=$HOME/.local/state/omarchy/current/theme.name
current=$(cat "$theme_name" 2>/dev/null)
# omarchy-theme-list prints "Tokyo Night" for the theme tokyo-night.
kebab() { tr '[:upper:] ' '[:lower:]-'; }
next=""
while IFS= read -r theme; do
  [[ $(kebab <<<"$theme") == "$(kebab <<<"$current")" ]] || { next=$theme; break; }
done < <(omarchy-theme-list 2>/dev/null)
if [[ -n $next ]] && omarchy-theme-set "$next" >/tmp/theme.log 2>&1; then
  switched() { [[ $(cat "$theme_name" 2>/dev/null) != "$current" ]]; }
  if wait_for 30 switched && wait_for 30 layer omarchy-bar; then
    ok "the theme switches to $next and the bar comes back"
    sleep 2
    shot theme
  else
    bad "the theme did not switch to $next"
  fi
  errors=$(hc configerrors | sed '/^\s*$/d')
  [[ -z $errors || $errors == "no errors"* ]] || { bad "configuration errors after the theme switch"; sed 's/^/     /' <<<"$errors"; }
  [[ -z $current ]] || omarchy-theme-set "$current" >/dev/null 2>&1
else
  bad "omarchy-theme-set ${next:-(no other theme)} failed"; tail -8 /tmp/theme.log 2>/dev/null | sed 's/^/     /'
fi

# --- the factory's apps ---------------------------------------------------------------
apps=("$@")
((${#apps[@]})) || apps=(omarchy-launch-nautilus foot obsidian localsend pinta "libreoffice --writer" evince)
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
# Installs with Omarchy's command, closes what the installer opened, then opens
# the app the way Omarchy launches it.
install_and_open() { # label package install-command launch-command [want]
  local label=$1 package=$2 install=$3 launch=$4 want=${5:-} before extra
  if ! pacman -Si "$package" >/dev/null 2>&1; then
    note "$label: $package is not in Omarchy's aarch64 repositories"
    return
  fi
  before=$(clients)
  if timeout 900 bash -c "$install" >/tmp/install.log 2>&1 && pacman -Q "$package" >/dev/null 2>&1; then
    ok "$label installs ($install)"
  else
    bad "$label does not install ($install)"; tail -10 /tmp/install.log | sed 's/^/     /'
    return
  fi
  sleep 5
  for extra in $(comm -13 <(printf '%s\n' "$before") <(clients)); do
    close_window "$extra" >/dev/null
  done
  sleep 2
  try_app "$label" "$launch" "$want"
}
# Ghostty and Kitty need desktop OpenGL above what VirGL offers and run
# through try-omarchy's software-renderer wrappers when Omarchy launches them.
for app in ${CI_INSTALLS-ghostty kitty 1password}; do
  case $app in
    ghostty | kitty) install_and_open "$app" "$app" "omarchy-install-terminal $app" omarchy-launch-terminal LIBGL_ALWAYS_SOFTWARE=1 ;;
    1password) install_and_open 1Password 1password omarchy-install-service-1password omarchy-launch-1password ;;
    vscode) install_and_open "VS Code" visual-studio-code-bin omarchy-install-editor-vscode code ;;
    signal) install_and_open Signal signal-desktop omarchy-install-service-signal signal-desktop ;;
    *) bad "unknown app to install: $app" ;;
  esac
done

dumps=$(coredumpctl list --no-pager --no-legend 2>/dev/null)
if [[ -n $dumps ]]; then bad "processes dumped core in the session"; sed 's/^/     /' <<<"$dumps"
else ok "no core dumps in the session"; fi
