# Sourced after upstream setup-form.sh by the reviewed owner-provisioning hook.
# Keep the selection in the ordinary form variable, including its confirmation
# screen. No policy is saved until configure_timezone runs after confirmation.
omarchy_prompt_timezone() {
  local mirror status
  mirror=$(/usr/local/bin/try-omarchy-timezone --mirror-label 2>/dev/null) || mirror=""
  if [[ -n $mirror ]]; then
    timezone=$({ printf '%s\n' "$mirror"; timedatectl list-timezones; } |
      gum choose --height 10 --selected "$mirror" --header "Timezone") && status=0 || status=$?
  else
    timezone=$(timedatectl list-timezones | gum filter --height 10 --header "Timezone") && status=0 || status=$?
  fi
  ((status == 0)) || return "$status"
  [[ -n $timezone ]] || return 1
}
