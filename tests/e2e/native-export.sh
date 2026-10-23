#!/bin/bash
#
# Move to Native Install in the real VM, as root in the guest. The transfer
# passphrase comes on standard input.
#
#   native-export.sh export USER TOKEN
#   native-export.sh import USER DIR TOKEN
#
# export: seeds a file and an SSH key in the home, then runs the menu row's
# command as the user, with only the package's sudo rule, and prints
# "export-id ID" when it finishes.
# import: restores the published export in DIR (bundle.age and receipt.json)
# into a scratch folder with the exporter's own importer, as the native
# install will, and checks what came across and what stayed behind.
# Prints "ok", "FAIL" or "note" lines.

set -uo pipefail
mode=$1
user=$2
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; }
note() { echo "note $*"; }
uid=$(id -u "$user")
home=/home/$user
as_user() { runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" "$@"; }
migration=/usr/lib/try-omarchy/migration
menu=.config/omarchy/extensions/omarchy-menu.jsonc

case $mode in
  export)
    token=$3
    passphrase=$(cat)
    visudo -cq -f /etc/sudoers.d/try-omarchy-export && ok "the export's sudo rule is valid" || bad "the export's sudo rule does not parse"
    id -nG "$user" | grep -qw wheel && ok "the user is in wheel, which the sudo rule names" || bad "the user is not in wheel"
    grep -qsw tryomarchy.native_exports=1 /run/try-omarchy/cmdline && grep -q '"setup.move-to-native-install"' "$home/$menu" &&
      ok "Setup shows Move to Native Install" || bad "Setup has no Move to Native Install row"
    as_user sh -c "mkdir -p ~/Projects/e2e-export ~/.ssh && printf '%s' '$token' >~/Projects/e2e-export/canary && printf key >~/.ssh/id_e2e_export"

    # Only the package's rule: the run's own NOPASSWD rule steps aside.
    aside=$(mktemp -d)
    [[ ! -e /etc/sudoers.d/zz-e2e ]] || mv /etc/sudoers.d/zz-e2e "$aside/"
    output=$(printf '%s\n%s\n' "$passphrase" "$passphrase" | as_user /usr/bin/try-omarchy-export-home 2>&1)
    status=$?
    [[ ! -e $aside/zz-e2e ]] || mv "$aside/zz-e2e" /etc/sudoers.d/zz-e2e
    rmdir "$aside"
    printf '%s\n' "$output" | sed 's/^/note export: /'
    export_id=$(sed -n 's/^Export \([0-9a-f-]\{36\}\) is ready\.$/\1/p' <<<"$output" | tail -1)
    if ((status == 0)) && [[ -n $export_id ]]; then
      ok "Move to Native Install exports the home without a password ($export_id)"
      echo "export-id $export_id"
    else
      bad "the export failed with status $status"
    fi
    compgen -G '/home/.try-omarchy-export.*' >/dev/null && bad "the export left its /home snapshot" ||
      ok "the export removes its /home snapshot"
    findmnt -rn -o TARGET | grep -q '^/run/try-omarchy/export\.' && bad "the export left a mount behind" ||
      ok "the export unmounts the outbox and the snapshot"
    ;;
  import)
    dir=$3
    token=$4
    passphrase=$(cat)
    work=/var/tmp/e2e-import
    rm -rf "$work"
    install -d -m 0700 -o "$user" "$work" "$work/home" "$work/job" "$work/wrong-job"
    install -m 0600 -o "$user" "$dir/bundle.age" "$dir/receipt.json" "$work/"
    importer() { # operation job [plan id]
      as_user env OMARCHY_TEST_AGE="$migration/age" OMARCHY_TEST_AGE_SHA256="$(<"$migration/age.sha256")" \
        "$migration/omarchy-migration/bin/omarchy-migration" "$1" --bundle "$work/bundle.age" --receipt "$work/receipt.json" \
        --target "$work/home" --job "$2" --passphrase-fd 0 ${3:+--plan-id "$3"}
    }
    importer plan "$work/wrong-job" <<<"not the transfer passphrase" >/dev/null 2>&1 &&
      bad "the bundle opens with a wrong passphrase" || ok "the bundle refuses a wrong passphrase"
    plan=$(importer plan "$work/job" <<<"$passphrase" 2>"$work/plan.err")
    plan_id=$(python3 -I -c 'import json, sys; print(json.load(sys.stdin)["plan_id"])' <<<"$plan" 2>/dev/null)
    if [[ -n $plan_id ]]; then
      ok "the importer opens the export with the transfer passphrase and plans it"
      if report=$(importer apply "$work/job" "$plan_id" <<<"$passphrase" 2>"$work/apply.err"); then
        ok "the importer restores the export: $(python3 -I -c 'import json, sys; print(" ".join(c["id"] + "=" + c["outcome"] for c in json.load(sys.stdin)["categories"]))' <<<"$report")"
      else
        bad "the importer could not apply its plan: $(tr '\n' ' ' <"$work/apply.err")"
      fi
    else
      bad "the importer could not plan the export: $(tr '\n' ' ' <"$work/plan.err")"
    fi
    restored=$work/home
    [[ $(cat "$restored/Projects/e2e-export/canary" 2>/dev/null) == "$token" ]] && ok "files in the home come across" ||
      bad "Projects/e2e-export/canary did not come across"
    [[ -e $restored/.ssh/id_e2e_export ]] && bad "an SSH key came across" || ok "SSH keys stay behind"
    [[ -e $restored/.config/hypr/monitors.lua ]] && bad "the VM's monitors.lua came across" || ok "the VM's monitors.lua stays behind"
    if [[ -f $restored/$menu ]]; then
      grep -qE '"setup\.(try-omarchy|move-to-native-install|import-previous-vm)"' "$restored/$menu" &&
        bad "Try's menu rows came across" || ok "Try's menu rows stay behind, the rest of the menu file comes across"
    else
      note "the export has no $menu"
    fi
    rm -rf "$work"
    ;;
  *)
    bad "unknown mode $mode"
    ;;
esac
