#!/bin/bash
#
# Omarchy's first-boot owner setup with fixed answers in place of its form.
# Runs as omarchy-provision-owner.service's ExecStart (run.sh's drop-in), so
# the unit's other parts stay the guest's own: its conditions and ordering,
# and try-omarchy's drop-in (the tzupdate shim on PATH, the kept autologin,
# owner-setup). The functions are Omarchy's: this sources the provisioning
# program without its final `main` and runs the steps run_setup runs after
# the form is confirmed.
#
# /ci-run/answers sets CI_USER and CI_PASSWORD.

set -euo pipefail

program=/usr/bin/omarchy-provision-owner
[[ $(tail -n 1 "$program") == main ]] || { echo "provision-seeded: $program no longer ends with main" >&2; exit 1; }
# shellcheck source=/dev/null
source /ci-run/answers
# shellcheck source=/dev/null
source <(sed '$d' "$program")

# The form's answers, read by Omarchy's functions.
# shellcheck disable=SC2034
{
username=$CI_USER
password=$CI_PASSWORD
full_name="Try Omarchy CI"
email_address="ci@example.invalid"
hostname=omarchy-ci
keyboard_label="English (US)"
}
# What the form preselects: tzupdate -p (try-omarchy's shim, which answers
# with the Mac's zone), else UTC.
timezone=$(tzupdate -p 2>/dev/null) || timezone=""
[[ -n $timezone ]] || timezone=UTC
echo "provision-seeded: user $username, time zone $timezone"

platform_ready
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
rm -f "$FINALIZE_WARNING_FLAG"
echo account >"$STATE_FILE"
run_provisioning >>"$LOG_FILE" 2>&1
if [[ -f $FINALIZE_WARNING_FLAG ]]; then
  echo "provision-seeded: user finalization reported errors (see $LOG_FILE)" >&2
fi
echo "provision-seeded: done"
