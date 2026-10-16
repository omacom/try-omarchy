#!/bin/bash
#
# Boots the factory disk's userland with systemd-nspawn on a Linux arm64 host
# (no VM: the guest's own systemd, Omarchy and try-omarchy, on the host's
# kernel) and checks it the way a user meets it: first-boot setup, the system
# and the package's units, Omarchy's desktop session on a vkms virtual display
# drawn by Mesa's software renderer, the shell, apps, and installs from
# Omarchy's repositories.
#
#   sudo guest/tests/desktop/run.sh [--package FILE] FACTORY_DIR OUT_DIR [APP...]
#
# FACTORY_DIR holds factory.json and the compressed disk (guest/build.sh's
# output). --package offers a try-omarchy package the way the app offers its
# bundled one (the tryomarchy.package credential and the package share), so
# the guest's own update service installs it before first login. APP: see
# session-checks.sh; CI_INSTALLS passes through. OUT_DIR receives
# results.txt, results.md, screens/, the console and the journal. Exits 1
# when a check fails.
#
# What differs from the VM, and why: no kernel or firmware of the guest's
# own; no Mac on the other side of the virtio ports (units that need one are
# skipped by their conditions, or listed in container-expected); the form of
# first-boot setup is answered by provision-seeded.sh; SDDM, which needs a
# virtual terminal, is masked and the session is started the way SDDM's
# autologin starts it (a PAM login running the session entry, with the seat
# named since the session has no VT); pacman's download sandbox is off when the
# host kernel lacks Landlock, and the host allows the unprivileged user
# namespaces apps' sandboxes need; the test user may sudo without a password.

set -euo pipefail

fail() {
  echo "desktop-test: $*" >&2
  exit 1
}

((EUID == 0)) || fail "run as root"
offered=""
if [[ ${1:-} == --package ]]; then
  offered=$(cd "$(dirname "${2:?}")" && pwd)/$(basename "$2")
  [[ -f $offered && ${offered##*/} =~ ^try-omarchy-[0-9][A-Za-z0-9._+-]*-(aarch64|any)\.pkg\.tar\.zst$ ]] ||
    fail "not a try-omarchy package: $2"
  shift 2
fi
(($# >= 2)) || fail "usage: run.sh [--package FILE] FACTORY_DIR OUT_DIR [APP...]"
factory=$(cd "$1" && pwd)
mkdir -p "$2"
out=$(cd "$2" && pwd)
shift 2
apps=("$@")
here=$(cd "$(dirname "$0")" && pwd)
machine=omarchy-ci
user=omarchy-ci
for tool in systemd-nspawn machinectl zstd jq losetup; do
  command -v "$tool" >/dev/null || fail "$tool is required"
done

work=$(mktemp -d /var/tmp/omarchy-desktop.XXXXXX)
root=$work/root
run=$work/ci-run
loop=""
results=$out/results.txt
: >"$results"
t0=$SECONDS
log() { printf '\n==> [%4ds] %s\n' "$((SECONDS - t0))" "$*"; }
record() { tee -a "$results"; }

cleanup() {
  local status=$?
  set +e
  if machinectl show "$machine" >/dev/null 2>&1; then
    journalctl -M "$machine" -b --no-pager >"$out/journal.txt" 2>&1
    machinectl poweroff "$machine" >/dev/null 2>&1
    for _ in $(seq 1 60); do machinectl show "$machine" >/dev/null 2>&1 || break; sleep 1; done
    machinectl terminate "$machine" >/dev/null 2>&1
  fi
  [[ -n ${nspawn_pid:-} ]] && wait "$nspawn_pid" 2>/dev/null
  cp -r "$run/screens" "$out/" 2>/dev/null
  cp "$run"/*.txt "$run"/*.log "$out/" 2>/dev/null
  cp "$root/var/log/omarchy-provision-owner.log" "$out/" 2>/dev/null
  chmod -R a+rX "$out"
  umount -R "$root" 2>/dev/null
  [[ -z $loop ]] || losetup -d "$loop" 2>/dev/null
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

# --- the display ---------------------------------------------------------------------
log "vkms virtual display"
modprobe vkms 2>/dev/null || {
  apt-get install -yq "linux-modules-extra-$(uname -r)" >/dev/null 2>&1
  modprobe vkms
}
udevadm settle
card=""
for entry in /sys/class/drm/card*; do
  [[ ${entry##*/} =~ ^card[0-9]+$ && $(readlink -f "$entry/device") == */vkms* ]] && card=/dev/dri/${entry##*/}
done
[[ -n $card ]] || fail "vkms created no DRM card"
chmod 666 "$card"
echo "vkms: $card"

# --- the disk --------------------------------------------------------------------------
log "Factory disk"
image=$(jq -r .compressed.path "$factory/factory.json")
expected=$(jq -r .compressed.sha256 "$factory/factory.json")
[[ $(sha256sum "$factory/$image" | cut -d' ' -f1) == "$expected" ]] || fail "the factory disk does not match factory.json"
zstd -q -d --sparse "$factory/$image" -o "$work/disk.img"
loop=$(losetup --find --show --partscan "$work/disk.img")
udevadm settle
mkdir -p "$root"
mount -o subvol=@,compress=zstd "${loop}p2" "$root"
mount -o subvol=@home,compress=zstd "${loop}p2" "$root/home"
mount -o subvol=@log,compress=zstd "${loop}p2" "$root/var/log"
mount -o subvol=@pkg,compress=zstd "${loop}p2" "$root/var/cache/pacman/pkg"
mount "${loop}p1" "$root/boot"
jq -r '"factory: omarchy \(.omarchy), kernel \(.kernel), built \(.built)"' "$factory/factory.json" | tee -a "$out/versions.txt"

# --- container adaptations (see the header) -------------------------------------------
mkdir -p "$run/screens"
chmod 1777 "$run" "$run/screens"
offered_version=""
offer=()
if [[ -n $offered ]]; then
  offered_version=${offered##*/try-omarchy-}
  offered_version=${offered_version%-*.pkg.tar.zst}
  mkdir -p "$work/packages"
  cp "$offered" "$work/packages/"
  # The share's mount point already mounted, the update service skips its 9p mount.
  offer=(--set-credential="tryomarchy.package:${offered##*/}" --bind-ro="$work/packages:/run/try-omarchy/packages")
fi
printf 'CI_USER=%s\nCI_PASSWORD=%s\nCI_PACKAGE_VERSION=%s\nCI_OFFERED_VERSION=%s\n' "$user" \
  "ci-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
  "$(awk '$1 == "try-omarchy" { print $2 }' "$factory/packages.txt")" "$offered_version" >"$run/answers"
chmod 644 "$run/answers"
: >"$work/fstab"
ln -sfn /dev/null "$root/etc/systemd/system/sddm.service"
# pacman's download sandbox needs Landlock, which the host's kernel may lack
# (the guest's own kernel has it).
grep -q '^DisableSandbox' "$root/etc/pacman.conf" || sed -i '/^\[options\]/a DisableSandbox' "$root/etc/pacman.conf"
install -d "$root/etc/systemd/system/omarchy-provision-owner.service.d"
cat >"$root/etc/systemd/system/omarchy-provision-owner.service.d/90-ci-seeded.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=/ci/provision-seeded.sh
StandardInput=null
StandardOutput=journal
StandardError=journal
TTYPath=
TTYReset=no
TTYVHangup=no
TTYVTDisallocate=no
EOF

# --- boot --------------------------------------------------------------------------------
log "Booting the userland (systemd-nspawn)"
# The host's systemd-networkd serves the container's veth (DHCP, masquerade);
# Docker leaves the FORWARD policy at DROP, so let that link's traffic through.
sysctl -qw net.ipv4.ip_forward=1
# Ubuntu's AppArmor refuses unprivileged user namespaces, which the guest's
# kernel allows and its sandboxes use (Electron, glycin's image loaders).
sysctl -qw kernel.apparmor_restrict_unprivileged_userns=0 2>/dev/null || true
iptables -I FORWARD 1 -i "ve-$machine" -j ACCEPT
iptables -I FORWARD 1 -o "ve-$machine" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
systemd-nspawn --boot --quiet --machine="$machine" --directory="$root" \
  --network-veth --resolv-conf=auto --timezone=off --link-journal=no \
  --bind-ro="$work/fstab:/etc/fstab" --bind-ro="$here:/ci" --bind="$run:/ci-run" \
  --bind="$card" --property="DeviceAllow=$card rw" --bind=/dev/fuse --property="DeviceAllow=/dev/fuse rwm" \
  --bind-ro=/run/udev ${offer[@]+"${offer[@]}"} \
  --console=pipe </dev/null >"$out/console.log" 2>&1 &
nspawn_pid=$!
# The host side of the container's network: systemd-networkd's
# 80-container-ve.network serves DHCP and masquerades for ve-* links.
( sleep 20; { networkctl status "ve-$machine" --no-pager; ip -br addr show "ve-$machine"; } >"$out/host-network.txt" 2>&1 ) &
in_guest() { systemd-run --machine="$machine" --quiet --wait --pipe --collect "$@"; }
for _ in $(seq 1 120); do
  in_guest /usr/bin/true >/dev/null 2>&1 && break
  kill -0 "$nspawn_pid" 2>/dev/null || { tail -40 "$out/console.log"; fail "the container stopped during boot"; }
  sleep 1
done
booted=$SECONDS
timeout 900 systemd-run --machine="$machine" --quiet --wait --pipe --collect \
  /usr/bin/systemctl is-system-running --wait >/dev/null 2>&1 || true
echo "ok   boot and first-boot setup finished in $((SECONDS - booted)) s ($(in_guest /usr/bin/systemctl is-system-running 2>/dev/null))" | record

log "System checks"
in_guest /ci/system-checks.sh 2>&1 | record

# --- the desktop session ----------------------------------------------------------------
log "Desktop session (uwsm, as SDDM's autologin starts it)"
uid=$(in_guest /usr/bin/id -u "$user")
in_guest /usr/bin/bash -c "printf '%s ALL=(ALL) NOPASSWD: ALL\n' $user >/etc/sudoers.d/zz-ci && chmod 440 /etc/sudoers.d/zz-ci"
entry=""
for candidate in usr/share/wayland-sessions usr/local/share/wayland-sessions; do
  [[ -f $root/$candidate/omarchy.desktop ]] && { entry=$root/$candidate/omarchy.desktop; break; }
done
[[ -n $entry ]] || fail "Omarchy ships no wayland session entry"
session=$(awk -F= '$1 == "Exec" { sub(/^Exec=/, ""); print; exit }' "$entry")
[[ -n $session ]] || fail "Omarchy ships no wayland session entry"
echo "session: $session"
systemd-run --machine="$machine" --quiet --unit=ci-desktop-session -p PAMName=login -p User="$user" \
  -p WorkingDirectory="~" -E LIBSEAT_BACKEND=noop -E AQ_DRM_DEVICES="$card" -E XDG_SESSION_TYPE=wayland \
  /usr/bin/bash -lc "XDG_SEAT=seat0 exec $session"

log "Session checks"
check_env=(-E "XDG_RUNTIME_DIR=/run/user/$uid")
[[ -z ${CI_INSTALLS+set} ]] || check_env+=(-E "CI_INSTALLS=$CI_INSTALLS")
systemd-run --machine="$machine" --quiet --wait --pipe --collect -p User="$user" "${check_env[@]}" \
  /ci/session-checks.sh ${apps[@]+"${apps[@]}"} 2>&1 | record
journalctl -M "$machine" --no-pager -u ci-desktop-session >"$out/session.log" 2>&1 || true

# --- results ------------------------------------------------------------------------------
log "Results"
failures=$(grep -c '^FAIL' "$results" || true)
passes=$(grep -c '^ok' "$results" || true)
{
  echo "### Factory userland on a virtual display"
  echo
  sed 's/^/- /' "$out/versions.txt"
  echo "- $passes passed, $failures failed, $(grep -c '^note' "$results" || true) notes, $((SECONDS - t0)) s"
  echo
  echo '```'
  grep -E '^(ok|FAIL|note)' "$results"
  echo '```'
} >"$out/results.md"
((failures == 0)) || exit 1
