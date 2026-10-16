#!/bin/bash
#
# Checks of the booted factory userland, as root inside the container: first-
# boot provisioning finished, no system unit failed except those listed in
# container-expected (hardware the container lacks), try-omarchy's units
# behaved, nothing dumped core, and the network works.
#
# Prints one "ok", "FAIL" or "note" line per check.

set -uo pipefail

# shellcheck source=/dev/null
source /ci-run/answers
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; }
note() { echo "note $*"; }

expected_failure() { # unit -> reason, or nothing
  awk -v u="$1" '$1 == u { $1 = ""; sub(/^ /, ""); print; exit }' /ci/container-expected 2>/dev/null
}

# --- provisioning ------------------------------------------------------------------
if getent passwd "$CI_USER" >/dev/null; then ok "first-boot setup created $CI_USER"; else bad "first-boot setup created no user"; fi
if [[ -e /var/lib/omarchy/provisioning/pending ]]; then bad "first-boot setup is still pending"
else ok "first-boot setup finished (pending cleared)"; fi
if grep -q 'first-boot setup complete' /var/log/omarchy-provision-owner.log 2>/dev/null; then
  ok "Omarchy's provisioning log says setup completed"
else
  bad "Omarchy's provisioning log has no completion"
  tail -15 /var/log/omarchy-provision-owner.log 2>/dev/null | sed 's/^/     /'
fi
if grep -q 'finalize-user failed' /var/log/omarchy-provision-owner.log 2>/dev/null; then
  bad "user finalization failed during setup"
  grep -iE 'error|fail' /var/log/omarchy-provision-owner.log | tail -10 | sed 's/^/     /'
fi
[[ $(hostname) == omarchy-ci ]] && ok "host name from setup" || bad "host name is $(hostname), not omarchy-ci"
[[ -f /etc/sddm.conf.d/autologin.conf ]] && ok "the owner's autologin is kept (try-omarchy's drop-in)" ||
  bad "the owner's autologin was removed"

# --- units -----------------------------------------------------------------------------
state=$(systemctl is-system-running 2>/dev/null)
note "system state: $state"
while read -r unit _; do
  [[ -n $unit ]] || continue
  reason=$(expected_failure "$unit")
  if [[ -n $reason ]]; then
    note "$unit failed as expected in a container: $reason"
  else
    bad "$unit failed"
    journalctl -b -u "$unit" --no-pager -n 8 -o cat 2>/dev/null | sed 's/^/     /'
    # Omarchy's first-boot steps log their output there.
    [[ $unit != omarchy-provision-* ]] || tail -15 /var/log/omarchy-install.log 2>/dev/null | sed 's/^/     install.log: /'
  fi
done < <(systemctl list-units --failed --plain --no-legend 2>/dev/null)

# One unit property, by name (systemctl show prints them in its own order).
property() { systemctl show "$1" -p "$2" | sed "s/^$2=//"; }
for unit in $(awk '$1 == "enable" { print $2 }' /usr/lib/systemd/system-preset/80-try-omarchy.preset); do
  active=$(property "$unit" ActiveState)
  result=$(property "$unit" Result)
  restarts=$(property "$unit" NRestarts)
  condition=$(property "$unit" ConditionResult)
  reason=$(expected_failure "$unit")
  if [[ -n $reason && $active == failed ]]; then
    note "$unit failed as expected in a container: $reason"
  elif [[ $active == failed || ( -n $result && $result != success ) ]]; then
    bad "$unit: $active ($result)"
  elif [[ ${restarts:-0} != 0 ]]; then
    bad "$unit restarted $restarts times"
  elif [[ $condition == no ]]; then
    note "$unit skipped: its condition does not hold here"
  else
    ok "$unit: $active"
  fi
done

[[ $(systemctl is-enabled systemd-timesyncd.service 2>/dev/null) == enabled ]] && ok "NTP is enabled" || bad "NTP is not enabled"
version=$(pacman -Q try-omarchy 2>/dev/null | awk '{print $2}')
# A package offered the way the app offers its bundled one (the
# tryomarchy.package credential and the package share) installs before login
# when it is newer than the installed one.
if [[ -n ${CI_OFFERED_VERSION:-} ]]; then
  result=$(jq -r .result /var/lib/try-omarchy/package-install.json 2>/dev/null)
  case $result in
    installed)
      [[ $version == "$CI_OFFERED_VERSION" ]] && ok "the update path installed the offered try-omarchy $version before login" ||
        bad "the update path reported an install, but try-omarchy $version is installed, not $CI_OFFERED_VERSION" ;;
    current) note "the offered try-omarchy $CI_OFFERED_VERSION is not newer than the factory's $version" ;;
    *) bad "the update path did not install the offered package: $(cat /var/lib/try-omarchy/package-install.json 2>/dev/null || echo 'no result')" ;;
  esac
elif [[ -n ${CI_PACKAGE_VERSION:-} ]]; then
  [[ $version == "$CI_PACKAGE_VERSION" ]] && ok "try-omarchy $version installed" ||
    bad "try-omarchy $version installed, expected $CI_PACKAGE_VERSION"
else
  note "try-omarchy $version installed"
fi

dumps=$(coredumpctl list --no-pager --no-legend 2>/dev/null)
if [[ -n $dumps ]]; then
  bad "processes dumped core during boot and setup"
  sed 's/^/     /' <<<"$dumps"
else
  ok "no core dumps"
fi

# --- network -------------------------------------------------------------------------
if curl -fsS --max-time 20 -o /dev/null https://pkgs.omarchy.org/edge/aarch64/omarchy.db; then
  ok "the guest reaches Omarchy's package repository"
else
  bad "the guest cannot reach Omarchy's package repository"
  { ip -br addr; ip route; resolvectl status 2>&1 | head -20; nmcli -t dev 2>&1; } | sed 's/^/     /'
fi
[[ $(systemctl is-active ufw.service 2>/dev/null) == active ]] && ok "Omarchy's firewall is active" ||
  note "Omarchy's firewall is $(systemctl is-active ufw.service 2>/dev/null)"
