#!/bin/bash
set -euo pipefail

[[ $# == 1 && $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ && $1 != root ]] || {
  echo "Usage: sudo install-onepassword-touch-id.sh GUEST_USER" >&2
  exit 64
}
(( EUID == 0 )) || { echo "Run this installer with sudo." >&2; exit 1; }
guest_user=$1
getent passwd "$guest_user" >/dev/null
source_dir=$(cd "$(dirname "$0")/../native-overlay" && pwd)
env -u DISPLAY -u WAYLAND_DISPLAY python3 -I -c 'import gi; gi.require_version("Gtk", "3.0"); gi.require_version("PolkitAgent", "1.0"); from gi.repository import Gtk, PolkitAgent'
[[ -f /var/lib/try-omarchy/native-authentication.json ]] || {
  echo "Pair this guest using the Touch ID setup first." >&2
  exit 1
}
[[ -x /opt/1Password/1password ]] || { echo "Install 1Password first." >&2; exit 1; }
backup_dir=$(mktemp -d /var/lib/try-omarchy/onepassword-backup.XXXXXXXX)
chmod 700 "$backup_dir"
helpers=/usr/local/lib/try-omarchy
unit=/usr/lib/systemd/system/try-omarchy-onepassword-touch-id@.service
for name in native-authentication-broker onepassword-touch-id-agent onepassword-password-dialog; do
  [[ ! -L $helpers/$name ]] || { echo "Refusing symlink destination." >&2; exit 1; }
  if [[ -f $helpers/$name ]]; then
    cp -p "$helpers/$name" "$backup_dir/$name"
  fi
  install -o root -g root -m 755 "$source_dir$helpers/$name" "$helpers/$name"
done
[[ ! -L $unit ]] || { echo "Refusing symlink unit." >&2; exit 1; }
if [[ -f $unit ]]; then cp -p "$unit" "$backup_dir/$(basename "$unit")"; fi
install -o root -g root -m 644 "$source_dir$unit" "$unit"
systemctl daemon-reload
systemctl enable "try-omarchy-onepassword-touch-id@$guest_user.service"
systemctl restart "try-omarchy-onepassword-touch-id@$guest_user.service"
printf '1Password Touch ID integration installed. Previous files retained in %s\n' "$backup_dir"
printf 'Disable with: sudo systemctl disable --now try-omarchy-onepassword-touch-id@%s.service\n' "$guest_user"
printf 'To test: sign in to 1Password, enable system authentication, unlock with your account password, then lock without quitting and try Touch ID.\n'
