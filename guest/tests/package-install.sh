#!/bin/bash
#
# Installs the try-omarchy package the way a guest gets it, against Omarchy's
# live aarch64 repositories, inside the guest builder image
# (guest/factory/Containerfile): its dependencies resolve, the DKMS battery
# module and v4l2loopback build for linux-omarchy's headers, the install
# hooks enable the preset units, an upgrade from the base package keeps the
# administrator's choices, and removal leaves nothing behind.
#
#   package-install.sh NEW.pkg.tar.zst [BASE.pkg.tar.zst]
#
# With BASE, NEW must have a higher version when PACKAGE_CHANGED=1 (the
# package's files differ): a guest installs the app's package only when it is
# newer. The pacman cache is /var/cache/pacman/pkg; mount one to reuse
# downloads. Prints one "ok"/"FAIL" line per check and exits 1 on a failure.

set -uo pipefail

new=${1:?usage: package-install.sh NEW.pkg.tar.zst [BASE.pkg.tar.zst]}
base=${2:-}
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }
check() { # description command...
  local description=$1
  shift
  if "$@" >/tmp/check.log 2>&1; then ok "$description"; else bad "$description"; sed 's/^/     /' /tmp/check.log | tail -20; fi
}
die() { echo "FAIL $*"; exit 1; }

# The repositories of the factory build (guest/factory/build-image.sh).
cat >/etc/pacman.conf <<'EOF'
[options]
HoldPkg = pacman glibc
Architecture = aarch64
ParallelDownloads = 8
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
DisableSandbox

[omarchy]
Server = https://pkgs.omarchy.org/edge/$arch

[core]
Server = https://arm-mirror.omarchy.org/$arch/$repo

[extra]
Server = https://arm-mirror.omarchy.org/$arch/$repo

[alarm]
Server = https://arm-mirror.omarchy.org/$arch/$repo

[aur]
Server = https://arm-mirror.omarchy.org/$arch/$repo
EOF
pacman-key --populate omarchy >/dev/null 2>&1 || die "cannot import Omarchy's repository key"
pacman -Syu --noconfirm >/tmp/sync.log 2>&1 || { tail -20 /tmp/sync.log; die "cannot update the builder from Omarchy's repositories"; }

# Every guest has linux-omarchy itself, and DKMS builds only for a kernel
# whose module tree is installed. Its initramfs and boot-entry hooks have
# nothing to do here, as in the factory build.
mkdir -p /etc/pacman.d/hooks
for hook in 60-mkinitcpio-remove.hook 60-limine-mkinitcpio-remove-pre.hook 80-limine-efi-deploy.hook \
  90-limine-mkinitcpio-remove-post.hook 90-mkinitcpio-install.hook; do
  ln -sfn /dev/null "/etc/pacman.d/hooks/$hook"
done
pacman -S --noconfirm --needed linux-omarchy >/tmp/kernel.log 2>&1 || { tail -20 /tmp/kernel.log; die "cannot install linux-omarchy"; }

version_of() { pacman -Qp "$1" 2>/dev/null | awk '{print $2}'; }
new_version=$(version_of "$new")
[[ -n $new_version ]] || die "not a package: $new"
echo "new package: $new_version"

if [[ -n $base ]]; then
  base_version=$(version_of "$base")
  echo "base package: $base_version (package files changed: ${PACKAGE_CHANGED:-unknown})"
  order=$(vercmp "$new_version" "$base_version")
  if [[ ${PACKAGE_CHANGED:-0} == 1 ]]; then
    if ((order > 0)); then ok "the changed package has a higher version ($base_version -> $new_version)"
    else bad "the package's files changed but its version did not go up ($base_version -> $new_version): bump pkgrel in guest/package/try-omarchy/PKGBUILD"; fi
  elif ((order < 0)); then
    bad "the version went down ($base_version -> $new_version)"
  fi
fi

install_package() { # archive log
  pacman -U --noconfirm --needed "$1" >"$2" 2>&1 || { tail -30 "$2"; return 1; }
}

kernel_release() {
  local dir
  for dir in /usr/lib/modules/*/build; do
    [[ -d $dir ]] && { basename "$(dirname "$dir")"; return 0; }
  done
  return 1
}

# The system and user units the package's presets enable.
preset_units() { # system|user
  awk '$1 == "enable" { print $2 }' "/usr/lib/systemd/$1-preset/80-try-omarchy.preset"
}

check_installed() { # label
  local label=$1 release unit missing=() module
  check "$label: pacman's file check" pacman -Qkk try-omarchy
  release=$(kernel_release) || { bad "$label: linux-omarchy-headers installed no kernel build directory"; return; }
  for module in try-omarchy-battery v4l2loopback; do
    if dkms status -m "$module" -k "$release" 2>/dev/null | grep -q ': installed'; then
      ok "$label: DKMS built $module for $release"
    else
      bad "$label: DKMS did not build $module for $release"
      dkms status 2>&1 | sed 's/^/     /'
      find /var/lib/dkms -name make.log -path "*$module*" -exec tail -20 {} \; 2>/dev/null | sed 's/^/     /'
    fi
  done
  for unit in $(preset_units system); do
    [[ $(systemctl is-enabled "$unit" 2>/dev/null) == enabled ]] || missing+=("$unit")
  done
  for unit in $(preset_units user); do
    [[ $(systemctl --global is-enabled "$unit" 2>/dev/null) == enabled ]] || missing+=("$unit (user)")
  done
  if ((${#missing[@]})); then bad "$label: preset units not enabled: ${missing[*]}"
  else ok "$label: every preset unit is enabled"; fi
  check "$label: NTP is enabled" test "$(systemctl is-enabled systemd-timesyncd.service 2>/dev/null)" = enabled
  # The graphical bridges start with the desktop session, not every user manager.
  for unit in omarchy-native-audio-bridge.service omarchy-native-camera-bridge.service omarchy-native-clipboard-bridge.service; do
    if [[ -L /etc/systemd/user/graphical-session.target.wants/$unit && ! -e /etc/systemd/user/default.target.wants/$unit ]]; then
      ok "$label: $unit starts with the graphical session"
    else
      bad "$label: $unit is not wanted by graphical-session.target alone"
    fi
  done
  check "$label: sudoers drop-in parses" visudo -cf /etc/sudoers.d/try-omarchy-timezone
  check "$label: version file" grep -qx "$(pacman -Q try-omarchy | awk '{print $2}')" /usr/share/try-omarchy/version
}

if [[ -n $base ]]; then
  install_package "$base" /tmp/base.log || die "the base package does not install"
  ok "base package installs with its dependencies"
  check_installed base
  # The administrator's choices survive the upgrade.
  systemctl --global disable omarchy-native-camera-bridge.service >/dev/null 2>&1
  systemctl --global mask omarchy-native-clipboard-bridge.service >/dev/null 2>&1
  systemctl disable try-omarchy-timezone.service >/dev/null 2>&1
  if install_package "$new" /tmp/upgrade.log; then
    ok "upgrade $base_version -> $new_version"
    [[ $(systemctl --global is-enabled omarchy-native-camera-bridge.service 2>/dev/null) == disabled ]] &&
      ok "upgrade: a disabled user unit stays disabled" || bad "upgrade: re-enabled a user unit the administrator disabled"
    [[ $(systemctl --global is-enabled omarchy-native-clipboard-bridge.service 2>/dev/null) == masked ]] &&
      ok "upgrade: a masked user unit stays masked" || bad "upgrade: unmasked a user unit"
    [[ $(systemctl is-enabled try-omarchy-timezone.service 2>/dev/null) == disabled ]] &&
      ok "upgrade: a disabled system unit stays disabled" || bad "upgrade: re-enabled a system unit the administrator disabled"
    check "upgrade: pacman's file check" pacman -Qkk try-omarchy
  else
    bad "upgrade $base_version -> $new_version"
  fi
  pacman -R --noconfirm try-omarchy >/dev/null 2>&1
  systemctl --global unmask omarchy-native-clipboard-bridge.service >/dev/null 2>&1
fi

# A fresh install, as the factory build makes it.
rm -f /etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service
if install_package "$new" /tmp/install.log; then
  ok "fresh install of $new_version with its dependencies"
  check_installed install
else
  die "fresh install of $new_version"
fi

# Removal: the package's files, its DKMS modules and its unit links go.
mapfile -t owned < <(pacman -Qlq try-omarchy | grep -v '/$')
release=$(kernel_release)
if pacman -R --noconfirm try-omarchy >/tmp/remove.log 2>&1; then
  ok "removal"
  left=()
  for path in "${owned[@]}"; do
    [[ -e $path || -L $path ]] && left+=("$path")
  done
  # pacman keeps changed backup files as .pacsave; the package's own are unchanged.
  ((${#left[@]} == 0)) && ok "removal: no packaged file is left" || bad "removal: files left: ${left[*]}"
  dkms status -m try-omarchy-battery 2>/dev/null | grep -q . &&
    bad "removal: the DKMS battery module is still registered" || ok "removal: the DKMS battery module is gone"
  [[ -z $release || ! -e /usr/lib/modules/$release/updates/dkms/try-omarchy-battery.ko.zst ]] ||
    bad "removal: the battery module file is still installed"
  dangling=$(find /etc/systemd/system /etc/systemd/user -xtype l 2>/dev/null)
  [[ -z $dangling ]] && ok "removal: no unit link points at a removed unit" ||
    bad "removal: unit links left pointing at removed units: $(echo "$dangling" | tr '\n' ' ')"
else
  tail -20 /tmp/remove.log
  bad "removal"
fi

# Keep one version of each package in a cache that outlives this run.
if pacman -S --noconfirm --needed pacman-contrib >/dev/null 2>&1; then
  paccache -rqk1 >/dev/null 2>&1 || true
fi

echo
if ((failures)); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all package checks passed"
