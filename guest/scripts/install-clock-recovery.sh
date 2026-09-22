#!/bin/bash
set -euo pipefail

(( $# == 0 )) || { echo 'Usage: sudo guest/scripts/install-clock-recovery.sh' >&2; exit 64; }
(( EUID == 0 )) || { echo 'Run this installer with sudo.' >&2; exit 1; }
source_dir=$(cd "$(dirname "$0")/../native-overlay" && pwd)
helper=/usr/local/lib/try-omarchy/guest-clock-recover
service=/usr/lib/systemd/system/try-omarchy-clock-recovery.service
timer=/usr/lib/systemd/system/try-omarchy-clock-recovery.timer
for file in "$helper" "$service" "$timer"; do
  [[ -f $source_dir$file && ! -L $source_dir$file && ! -L $file ]] || {
    echo "Unsafe or missing installation path: $file" >&2
    exit 1
  }
done
install -d -m 0755 /var/lib/try-omarchy /usr/local/lib/try-omarchy
backup=$(mktemp -d /var/lib/try-omarchy/clock-recovery-backup.XXXXXXXX)
for file in "$helper" "$service" "$timer"; do
  if [[ -f $file ]]; then cp -p "$file" "$backup/$(basename "$file")"; fi
done
install -o root -g root -m 0755 "$source_dir$helper" "$helper"
install -o root -g root -m 0644 "$source_dir$service" "$service"
install -o root -g root -m 0644 "$source_dir$timer" "$timer"
systemctl daemon-reload
systemctl enable --now systemd-timesyncd.service
systemctl start try-omarchy-clock-recovery.service
systemctl enable --now try-omarchy-clock-recovery.timer
printf 'Guest clock recovery enabled. Previous files retained in %s\n' "$backup"
