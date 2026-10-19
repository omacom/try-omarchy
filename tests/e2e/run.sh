#!/bin/bash
#
# End to end on this Mac: a disposable VM in the built app's own runtime
# (QEMU on HVF, VirGL on the Mac's GPU, the Cocoa window, the Mac bridges),
# from first boot to a second cold boot. What the hosted CI cannot run.
#
#   tests/e2e/run.sh [--app APP] [--factory DIR] [--package FILE] [--out DIR] [--keep] [--no-installs] [--prepare-only] [APP_COMMAND...]
#
# --app APP     the built app (default dist/app.noindex/Try Omarchy.app)
# --factory DIR boot this factory (guest/build.sh's output) instead of the app's
# --package FILE offer this try-omarchy package instead of the app's bundled one
#               (as the app offers it, through the guest's update service)
# --out DIR     results, screenshots and logs (default .build/e2e/<time>)
# --keep        keep the VM's storage folder afterwards
# --no-installs skip installing apps from Omarchy's repositories (by default:
#               Ghostty, Kitty, 1Password, VS Code and Signal; CI_INSTALLS
#               names others, see guest/tests/desktop/session-checks.sh)
# --prepare-only create and prepare the VM, keep it and stop before its first boot
#
# The VM gets its own storage folder (never the app's), a free loopback port
# for SSH and a test shared folder. Before its first boot the disk receives
# fixed answers for Omarchy's first-boot form, the checks and a root SSH key
# (prepare-disk.sh, in the guest builder image, so Docker must be running).
# The VM's window opens on this Mac while the run lasts (about ten minutes).
# The checks: guest/tests/desktop's system and session checks, plus Omarchy's
# keybindings pressed on the VM's keyboard (qmp-keys.py), the Mac integrations
# (vm-checks.sh), the shutdown and a second boot that keeps the user's files.
# Exits 1 when a check fails.

set -euo pipefail

fail() {
  echo "e2e: $*" >&2
  exit 1
}

repo=$(cd "$(dirname "$0")/../.." && pwd -P)
app="$repo/dist/app.noindex/Try Omarchy.app"
out=""
keep=0
installs=1
prepare_only=0
package=""
factory=""
while (($#)); do
  case $1 in
    --app) app=${2:?}; shift 2 ;;
    --factory) factory=$(cd "${2:?}" && pwd -P); shift 2 ;;
    --package) package=$(cd "$(dirname "${2:?}")" && pwd -P)/$(basename "$2"); shift 2 ;;
    --out) out=${2:?}; shift 2 ;;
    --keep) keep=1; shift ;;
    --no-installs) installs=0; shift ;;
    --prepare-only) prepare_only=1; keep=1; shift ;;
    -h | --help) sed -n '2,30p' "$0"; exit 0 ;;
    --*) fail "unknown option: $1" ;;
    *) break ;;
  esac
done
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || fail "runs on an Apple Silicon Mac"
[[ -d $app ]] || fail "no app at $app (run make app)"
app=$(cd "$app" && pwd -P)
launcher="$app/Contents/Resources/scripts/run-qemu-gpu.sh"
[[ -x $launcher ]] || fail "the app has no launcher"
command -v docker >/dev/null && docker info >/dev/null 2>&1 || fail "Docker must be running (the disk is prepared in the guest builder image)"
docker image inspect try-omarchy-guest-builder >/dev/null 2>&1 ||
  docker build --quiet --platform linux/arm64 -f "$repo/guest/factory/Containerfile" -t try-omarchy-guest-builder "$repo" >/dev/null

stamp=$(date +%Y%m%d-%H%M%S)
[[ -n $out ]] || out="$repo/.build/e2e/$stamp"
mkdir -p "$out/screens"
out=$(cd "$out" && pwd -P)
work="$repo/.build/e2e/vm-$stamp"
mkdir -p "$work"
work=$(cd "$work" && pwd -P)
state="$work/state"
share="$work/share"
inject="$work/inject"
mkdir -p "$share" "$inject/ci" "$inject/ci-run"
results="$out/results.txt"
: >"$results"
t0=$SECONDS
user=omarchy-ci
log() { printf '\n==> [%4ds] %s\n' "$((SECONDS - t0))" "$*"; }
record() { tee -a "$results"; }
pass() { echo "ok   $*" | record; }
miss() { echo "FAIL $*" | record; }

launcher_pid=""
cleanup() {
  local status=$?
  set +e
  if [[ -n $launcher_pid ]] && kill -0 "$launcher_pid" 2>/dev/null; then
    guest systemctl poweroff >/dev/null 2>&1
    for _ in $(seq 1 60); do kill -0 "$launcher_pid" 2>/dev/null || break; sleep 1; done
    kill "$launcher_pid" 2>/dev/null
    wait "$launcher_pid" 2>/dev/null
  fi
  if ((keep)); then echo "e2e: the VM is kept in $work"; else rm -rf "$work"; fi
  exit "$status"
}
trap cleanup EXIT

# --- the run's identity ---------------------------------------------------------------------
ssh-keygen -q -t ed25519 -N '' -C omarchy-e2e -f "$work/ssh-key"
cp "$work/ssh-key.pub" "$inject/authorized_keys"
port=$(/usr/bin/python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
password="e2e-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf 'CI_USER=%s\nCI_PASSWORD=%s\n' "$user" "$password" >"$inject/ci-run/answers"
cp "$repo"/guest/tests/desktop/provision-seeded.sh "$repo"/guest/tests/desktop/system-checks.sh \
  "$repo"/guest/tests/desktop/session-checks.sh "$repo"/tests/e2e/vm-checks.sh \
  "$repo"/guest/package/tests/virgl-smoke.c "$repo"/tests/e2e/hypr-state.sh "$repo"/tests/e2e/hdr-checks.sh "$inject/ci/"
: >"$inject/ci/container-expected"
share_token="from-the-mac-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf '%s' "$share_token" >"$share/e2e-from-mac.txt"
mac_zone=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')

ssh_options=(-i "$work/ssh-key" -p "$port" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes)
guest() { ssh "${ssh_options[@]}" root@127.0.0.1 "$@"; }

launch_env=(
  OMARCHY_QEMU_GPU_STATE_ROOT="$state"
  OMARCHY_QEMU_GPU_FACTORY_CACHE="$HOME/Library/Application Support/Try Omarchy/VM/v1/shell-factory"
  OMARCHY_QEMU_GPU_PORT_FORWARDS="tcp:$port:22"
  OMARCHY_QEMU_GPU_SHARED_FOLDER="$share"
  OMARCHY_QEMU_GPU_IMMERSIVE=0
)
[[ -z $package ]] || launch_env+=(OMARCHY_SHELL_INSTALL_PACKAGE="$package")
# The VM's size follows the launcher's own settings when they are set.
for setting in OMARCHY_QEMU_GPU_MEMORY_MIB OMARCHY_QEMU_GPU_CPUS; do
  [[ -z ${!setting:-} ]] || launch_env+=("$setting=${!setting}")
done
launcher_args=()
[[ -z $factory ]] || launcher_args=("$factory")
launch() { # log
  env "${launch_env[@]}" "$launcher" ${launcher_args[@]+"${launcher_args[@]}"} >"$1" 2>&1 &
  launcher_pid=$!
}
wait_for_ssh() { # seconds
  local deadline=$((SECONDS + $1))
  until guest true 2>/dev/null; do
    kill -0 "$launcher_pid" 2>/dev/null || return 1
    ((SECONDS < deadline)) || return 1
    sleep 2
  done
}
# --- a new VM, prepared before its first boot ------------------------------------------
log "Creating the VM (the app's launcher, dry run)"
env "${launch_env[@]}" OMARCHY_QEMU_GPU_DRY_RUN=1 "$launcher" ${launcher_args[@]+"${launcher_args[@]}"} >"$out/create.log" 2>&1 || {
  tail -20 "$out/create.log"
  fail "the launcher could not create the VM"
}
disk="$state/shell/disk.img"
[[ -f $disk ]] || fail "the launcher made no disk"
log "Preparing the first boot (fixed setup answers, checks, SSH key)"
docker run --rm --privileged --platform linux/arm64 --entrypoint /bin/bash \
  -v "$state/shell:/vm" -v "$inject:/inject:ro" -v "$repo/tests/e2e:/e2e:ro" \
  try-omarchy-guest-builder /e2e/prepare-disk.sh /vm/disk.img /inject

if ((prepare_only)); then
  echo "e2e: prepared; launch it with: env ${launch_env[*]} \"$launcher\""
  exit 0
fi

# --- first boot ---------------------------------------------------------------------------
log "First boot"
boot_start=$SECONDS
launch "$out/launch-1.log"
wait_for_ssh 600 || { tail -30 "$out/launch-1.log"; fail "no SSH within 10 minutes of the first boot"; }
guest systemctl is-system-running --wait >/dev/null 2>&1 || true
pass "first boot and setup finished in $((SECONDS - boot_start)) s ($(guest systemctl is-system-running 2>/dev/null))"
guest 'cat >/etc/sudoers.d/zz-e2e && chmod 440 /etc/sudoers.d/zz-e2e' <<<"$user ALL=(ALL) NOPASSWD: ALL"

log "System checks"
guest /ci/system-checks.sh 2>&1 | record
log "Desktop session"
uid=$(guest id -u "$user")
installs_list=${CI_INSTALLS-ghostty kitty 1password vscode signal}
((installs)) || installs_list=""
quoted=""
for app in "$@"; do quoted="$quoted $(printf '%q' "$app")"; done
guest "runuser -u $user -- env XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus CI_INSTALLS='$installs_list' /ci/session-checks.sh$quoted" 2>&1 | record
if [[ ${OMARCHY_NATIVE_OPENGL_HDR:-0} == 1 && ${TRY_OMARCHY_HDR_EXPECT_AFTER_REBOOT:-0} != 1 ]]; then
  guest "/ci/hdr-checks.sh $user" 2>&1 | record
fi
# Omarchy's keybindings, pressed on the VM's keyboard through QEMU (the path a
# Mac keyboard takes), which the session checks cannot do from inside.
log "Keybindings on the VM's keyboard"
qmp=$(sed -n 's/^\[qemu-gpu\] Ready\. QMP: //p' "$out/launch-1.log" | tail -1)
press() { /usr/bin/python3 "$repo/tests/e2e/qmp-keys.py" "$qmp" "$@"; }
state() { guest "runuser -u $user -- /ci/hypr-state.sh $1" 2>/dev/null; }
eventually() { # seconds command...
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    ((SECONDS < deadline)) || return 1
    sleep 1
  done
}
windows=$(state windows)
more_windows() { [[ $(state windows) -gt $windows ]]; }
same_windows() { [[ $(state windows) -eq $windows ]]; }
press meta_l+ret
if eventually 30 more_windows; then
  pass "Super + Return opens a terminal"
  sleep 3
  guest rm -f /ci-run/keys.txt
  press --text "echo keys-$port > /ci-run/keys.txt" && press ret
  keys_typed() { [[ $(guest cat /ci-run/keys.txt 2>/dev/null) == "keys-$port" ]]; }
  eventually 15 keys_typed && pass "a command typed on the VM's keyboard runs" || miss "a command typed on the VM's keyboard did not run"
  press meta_l+w
  eventually 15 same_windows && pass "Super + W closes the window" || miss "Super + W did not close the window"
else
  miss "Super + Return opened no terminal"
fi
press meta_l+spc
menu_open() { state menu; }
menu_closed() { ! state menu; }
if eventually 15 menu_open; then
  pass "Super + Space opens Omarchy's menu"
  press esc
  eventually 15 menu_closed && pass "Escape closes Omarchy's menu" || miss "Escape did not close Omarchy's menu"
else
  miss "Super + Space did not open Omarchy's menu"
fi

# After the session: the desktop bridges follow graphical-session.target.
log "Mac integrations"
guest /ci/vm-checks.sh "$user" "$mac_zone" "$share_token" 2>&1 | record
[[ $(cat "$share/e2e-from-guest.txt" 2>/dev/null) == "$share_token" ]] && pass "the Mac reads what the guest wrote to the share" ||
  miss "the Mac does not see the guest's file in the shared folder"
status_file="$state/shell/guest-status.json"
if [[ -s $status_file ]]; then pass "the app receives guest status: $(tr -d '\n' <"$status_file" | cut -c1-140)"
else miss "no guest status report at $status_file"; fi
# Omarchy boots quiet, so the virtio console carries the getty, not kernel messages.
[[ -s $state/shell/console.log ]] && pass "the guest's virtio console reaches console.log" || miss "console.log is empty"
guest 'tar -C /ci-run/screens -cf - .' | tar -C "$out/screens" -xf - 2>/dev/null || true
guest journalctl -b --no-pager >"$out/journal-1.txt" 2>&1 || true

# --- shutdown and a second cold boot -------------------------------------------------------
log "Shutdown"
guest "runuser -u $user -- sh -c 'echo $share_token >\$HOME/e2e-marker'"
guest systemctl poweroff >/dev/null 2>&1 || true
for _ in $(seq 1 90); do kill -0 "$launcher_pid" 2>/dev/null || break; sleep 1; done
if kill -0 "$launcher_pid" 2>/dev/null; then miss "the VM did not power off within 90 s"; kill "$launcher_pid"; else pass "the guest powers the VM off"; fi
wait "$launcher_pid" 2>/dev/null || true
launcher_pid=""

log "Second boot"
boot_start=$SECONDS
launch "$out/launch-2.log"
wait_for_ssh 300 || { tail -30 "$out/launch-2.log"; fail "no SSH within 5 minutes of the second boot"; }
guest systemctl is-system-running --wait >/dev/null 2>&1 || true
pass "second boot in $((SECONDS - boot_start)) s ($(guest systemctl is-system-running 2>/dev/null))"
[[ $(guest "cat /home/$user/e2e-marker" 2>/dev/null) == "$share_token" ]] && pass "the user's files survive a shutdown" ||
  miss "the user's files did not survive the shutdown"
guest test -e /var/lib/omarchy/provisioning/pending && miss "first-boot setup is pending again" || pass "first-boot setup does not run again"
hypr() { guest "ls /run/user/$uid/hypr/*/.socket.sock" >/dev/null 2>&1; }
for _ in $(seq 1 90); do hypr && break; sleep 1; done
hypr && pass "the desktop starts again on the second boot ($((SECONDS - boot_start)) s)" || miss "no desktop on the second boot"
if [[ ${OMARCHY_NATIVE_OPENGL_HDR:-0} == 1 ]]; then
  guest "/ci/hdr-checks.sh $user" 2>&1 | record
fi
guest journalctl -b --no-pager >"$out/journal-2.txt" 2>&1 || true

# --- results ----------------------------------------------------------------------------------
failures=$(grep -c '^FAIL' "$results" || true)
{
  echo "# End-to-end run, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "- Mac: $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion)"
  echo "- App: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null)"
  echo "- $(grep -c '^ok' "$results" || true) passed, $failures failed, $(grep -c '^note' "$results" || true) notes, $((SECONDS - t0)) s"
  echo
  echo '```'
  grep -E '^(ok|FAIL|note)' "$results"
  echo '```'
} >"$out/results.md"
echo
echo "e2e: $(grep -c '^ok' "$results" || true) passed, $failures failed; results in $out"
((failures == 0))
