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
# into a scratch folder with the exporter's own importer, and checks what came
# across and what stayed behind. Then imports it as the native install does,
# into a home seeded from this Omarchy's /etc/skel with --defaults /etc/skel:
# the Omarchy setting the VM changed replaces the untouched default, and a
# setting the owner changed stays.
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
skel_record=/var/lib/e2e-native-export-skel
# Omarchy settings in /etc/skel the export's policy carries as written.
skel_settings() {
  (cd /etc/skel && find .config -type f | LC_ALL=C sort |
    grep -vE 'monitors\.lua|fcitx5|omarchy/extensions|omarchy/toggles|shell\.json|chromium-flags')
}

# The native install's import: a fresh home from /etc/skel, --defaults /etc/skel.
native_import() { # dir token passphrase work
  local dir=$1 token=$2 passphrase=$3 work=$4 setting changed native=$4/native plan plan_id
  setting=$(cat "$skel_record" 2>/dev/null)
  [[ -n $setting ]] || { bad "the export recorded no changed Omarchy setting"; return; }
  changed=$(skel_settings | grep -vxF "$setting" | head -1)
  install -d -m 0700 -o "$user" "$native" "$work/native-job"
  cp -a /etc/skel/. "$native/"
  chown -R "$user:" "$native"
  [[ -n $changed ]] && printf '\n# owner-change\n' >>"$native/$changed"
  native_importer() { # operation [plan id]
    as_user "$migration/omarchy-migration/bin/omarchy-migration" "$1" --bundle "$work/bundle.age" \
      --receipt "$work/receipt.json" --target "$native" --job "$work/native-job" --passphrase-fd 0 \
      --defaults /etc/skel --age "$migration/age" --age-sha256 "$(<"$migration/age.sha256")" ${2:+--plan-id "$2"}
  }
  plan=$(native_importer plan <<<"$passphrase" 2>"$work/native-plan.err")
  plan_id=$(python3 -I -c 'import json, sys; print(json.load(sys.stdin)["plan_id"])' <<<"$plan" 2>/dev/null)
  if [[ -z $plan_id ]]; then
    bad "the native import could not plan: $(tr '\n' ' ' <"$work/native-plan.err")"
    return
  fi
  if native_importer apply "$plan_id" <<<"$passphrase" >/dev/null 2>"$work/native-apply.err"; then
    ok "the native import applies its plan over a home from /etc/skel"
  else
    bad "the native import could not apply its plan: $(tr '\n' ' ' <"$work/native-apply.err")"
  fi
  grep -qF "# $token" "$native/$setting" && ok "the setting the VM changed replaces the untouched default ($setting)" ||
    bad "the untouched default $setting was not replaced"
  if [[ -n $changed ]]; then
    grep -qF "# owner-change" "$native/$changed" && ok "a setting the owner changed stays ($changed)" ||
      bad "the native import replaced $changed, which the owner changed"
  fi
}

case $mode in
  export)
    token=$3
    passphrase=$(cat)
    grep -qw tryomarchy.native_exports=1 /run/try-omarchy/cmdline && ok "the host settings offer the native-exports outbox" ||
      bad "the host settings do not offer the native-exports outbox"
    outbox_device=''
    for tag in /sys/bus/virtio/drivers/9pnet_virtio/*/mount_tag; do
      [[ -r $tag && $(tr -d '\0' <"$tag") == tryomarchy-native-exports ]] && outbox_device=${tag%/mount_tag} && break
    done
    [[ -n $outbox_device ]] && ok "the native-exports outbox is a 9p device (${outbox_device##*/})" ||
      bad "no 9p device with mount tag tryomarchy-native-exports"
    visudo -cq -f /etc/sudoers.d/try-omarchy-export && ok "the export's sudo rule is valid" || bad "the export's sudo rule does not parse"
    id -nG "$user" | grep -qw wheel && ok "the user is in wheel, which the sudo rule names" || bad "the user is not in wheel"
    grep -qsw tryomarchy.native_exports=1 /run/try-omarchy/cmdline && grep -q '"setup.move-to-native-install"' "$home/$menu" &&
      ok "Setup shows Move to Native Install" || bad "Setup has no Move to Native Install row"
    as_user sh -c "mkdir -p ~/Projects/e2e-export ~/.ssh && printf '%s' '$token' >~/Projects/e2e-export/canary && printf key >~/.ssh/id_e2e_export"
    setting=$(skel_settings | while read -r path; do [[ -f $home/$path ]] && { echo "$path"; break; }; done)
    if [[ -n $setting ]]; then
      as_user sh -c "printf '\n# %s\n' '$token' >>\"\$HOME/$setting\""
      printf '%s\n' "$setting" >"$skel_record"
      ok "the VM changes an Omarchy setting from /etc/skel ($setting)"
    else
      bad "no Omarchy setting from /etc/skel is in the home"
    fi

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
    native_import "$dir" "$token" "$passphrase" "$work"
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
