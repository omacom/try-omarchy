#!/bin/bash
#
# Inside the guest builder image (privileged): prepares a new VM disk for the
# end-to-end run before its first boot, the way run.sh's container adaptation
# prepares the factory userland: Omarchy's first-boot setup takes fixed
# answers (guest/tests/desktop/provision-seeded.sh), the checks sit at /ci and
# /ci-run, and root accepts the run's SSH key. Nothing else changes.
#
#   prepare-disk.sh DISK INJECT_DIR
#
# INJECT_DIR holds ci/ (the check scripts), ci-run/ (answers) and
# authorized_keys.

set -euo pipefail
disk=$1
inject=$2

partition() { # number field
  sfdisk --json "$disk" | jq -r --argjson n "$1" --arg f "$2" '.partitiontable.partitions[$n - 1][$f]'
}
loop=$(losetup --find --show --offset $(($(partition 2 start) * 512)) --sizelimit $(($(partition 2 size) * 512)) "$disk")
trap 'umount -R /target 2>/dev/null; losetup -d "$loop" 2>/dev/null' EXIT
mkdir -p /target
mount -o subvol=@,compress=zstd "$loop" /target
mount -o subvol=@home,compress=zstd "$loop" /target/home

[[ -f /target/var/lib/omarchy/provisioning/pending ]] || { echo "prepare-disk: the disk is already set up" >&2; exit 1; }
rm -rf /target/ci /target/ci-run
cp -R "$inject/ci" /target/ci
cp -R "$inject/ci-run" /target/ci-run
chmod -R a+rX /target/ci /target/ci-run
chmod 1777 /target/ci-run
install -d -m 1777 /target/ci-run/screens
install -d -m 0700 /target/root/.ssh
install -m 0600 "$inject/authorized_keys" /target/root/.ssh/authorized_keys
install -d /target/etc/systemd/system/omarchy-provision-owner.service.d
cat >/target/etc/systemd/system/omarchy-provision-owner.service.d/90-ci-seeded.conf <<'EOF'
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
sync
echo "prepare-disk: ready for the first boot"
