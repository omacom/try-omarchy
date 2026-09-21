#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: install-touch-id-sudo.sh [--root ROOT] [--guest-dir GUEST_DIR]" >&2
  exit 64
}

fail() {
  echo "install-touch-id-sudo: $*" >&2
  exit 1
}

script_dir=$(cd "$(dirname "$0")" && pwd)
guest_dir=$(cd "$script_dir/.." && pwd)
root=/
while (($#)); do
  case "$1" in
    --root)
      root=${2:-}
      shift 2
      ;;
    --guest-dir)
      guest_dir=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[[ $root == /* ]] || fail "--root must be absolute"
if [[ $root != / ]]; then
  case "$root" in
    /bin|/boot|/etc|/home|/opt|/root|/usr|/var)
      fail "refusing unsafe staged root: $root"
      ;;
  esac
  [[ -d $root ]] || fail "staged root does not exist: $root"
  root=${root%/}
else
  (( EUID == 0 )) || fail "run as root"
  root=
fi
[[ -d $guest_dir/native-overlay ]] || fail "guest overlay not found: $guest_dir"

broker_source="$guest_dir/native-overlay/usr/local/lib/try-omarchy/native-authentication-broker"
enroll_source="$guest_dir/native-overlay/usr/local/sbin/try-omarchy-touch-id-enroll"
test_source="$guest_dir/native-overlay/usr/local/bin/try-omarchy-touch-id-test"
menu_source="$guest_dir/native-overlay/usr/local/bin/try-omarchy-touch-id"
control_source="$guest_dir/native-overlay/usr/local/sbin/try-omarchy-touch-id-control"
rule_source="$guest_dir/native-overlay/etc/udev/rules.d/93-omarchy-native-authentication.rules"
menu_installer_source="$guest_dir/scripts/install-touch-id-menu-entry.py"
for source_file in "$broker_source" "$enroll_source" "$test_source" "$menu_source" "$control_source" "$rule_source" "$menu_installer_source"; do
  [[ -f $source_file && ! -L $source_file ]] || fail "unsafe or missing source: $source_file"
done

[[ -x $root/usr/bin/python3 && ! -L $root/usr/bin/python3 ]] || {
  [[ -L $root/usr/bin/python3 && -x $root/usr/bin/python3 ]] || fail "guest Python is unavailable"
}
[[ -x $root/usr/bin/openssl && ! -L $root/usr/bin/openssl ]] || fail "guest OpenSSL is unavailable"
[[ -f $root/usr/lib/security/pam_exec.so && ! -L $root/usr/lib/security/pam_exec.so ]] || \
  fail "pam_exec.so is unavailable"

install -d -m 0755 "$root/usr/local/lib/try-omarchy" "$root/usr/local/sbin" "$root/usr/local/bin"
install -d -m 0755 "$root/etc/udev/rules.d"
install -m 0755 "$broker_source" \
  "$root/usr/local/lib/try-omarchy/native-authentication-broker"
install -m 0755 "$enroll_source" "$root/usr/local/sbin/try-omarchy-touch-id-enroll"
install -m 0755 "$test_source" "$root/usr/local/bin/try-omarchy-touch-id-test"
install -m 0755 "$menu_source" "$root/usr/local/bin/try-omarchy-touch-id"
install -m 0755 "$control_source" "$root/usr/local/sbin/try-omarchy-touch-id-control"
install -m 0644 "$rule_source" \
  "$root/etc/udev/rules.d/93-omarchy-native-authentication.rules"

# New accounts inherit /etc/skel, which materialization copies before the
# reviewed menu backport is applied to /usr/share/omarchy/config. Install the
# entry in the account defaults too, alongside the command it exposes.
"$menu_installer_source" "$root/etc/skel/.config/omarchy/extensions/omarchy-menu.jsonc"

if [[ -z $root ]]; then
  if ! /usr/local/lib/try-omarchy/native-authentication-broker migrate; then
    /usr/local/sbin/try-omarchy-touch-id-control disable || true
    fail "existing Touch ID state could not be migrated; sudo authentication was disabled"
  fi
  /usr/local/sbin/try-omarchy-touch-id-control migrate
  /usr/bin/udevadm control --reload-rules
  /usr/bin/udevadm trigger --subsystem-match=virtio-ports --action=change
  if [[ ${SUDO_USER:-root} != root ]]; then
    [[ ${SUDO_USER:-} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || fail "unsafe invoking user"
    account=$(getent passwd "$SUDO_USER") || fail "cannot resolve invoking user"
    IFS=: read -r _ _ account_uid _ _ account_home _ <<<"$account"
    [[ $account_uid == "${SUDO_UID:-}" ]] || fail "invoking user identity changed"
    [[ $account_home == /* && $account_home != / ]] || fail "unsafe invoking user home"
    runuser --user "$SUDO_USER" -- \
      "$menu_installer_source" \
      "$account_home/.config/omarchy/extensions/omarchy-menu.jsonc"
    runuser --user "$SUDO_USER" -- /usr/bin/omarchy menu refresh >/dev/null 2>&1 || true
  fi
fi

echo "Installed the opt-in Touch ID sudo integration."
echo "Enable with: try-omarchy-touch-id"
echo "Test with:   try-omarchy-touch-id-test"
