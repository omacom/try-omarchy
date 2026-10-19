#!/bin/bash
#
# Builds the upstream-shell factory disk: a stock generic-aarch64 Omarchy
# install from pkgs.omarchy.org and Omarchy's Arch Linux ARM mirror, laid out
# the way upstream's ISO installs a full disk (omarchy-iso configurator and
# orchestrator), with owner provisioning deferred to first boot.
#
#   GPT  p1  2 GiB  vfat  OMARCHY_EFI   /boot  Limine + UKIs
#        p2  rest   btrfs omarchy       @ @home @log @pkg  (compress=zstd)
#
# The image-target manifest (platform=aarch64) defers hardware setup and the
# pacman master key to the VM's first boot, as upstream's image builders do.
# Runs inside guest/factory/Containerfile, privileged (loop devices, mounts).
#
#   build-image.sh --output DIR --work DIR [--channel edge] [--size-gib N]
#                  [--package FILE.pkg.tar.zst]...

set -euo pipefail
umask 022

fail() {
  echo "upstream-image: $*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

output=""
work=""
channel=edge
size_gib=20
extra_packages=()

while (($#)); do
  case $1 in
    --output) output=${2:?}; shift 2 ;;
    --work) work=${2:?}; shift 2 ;;
    --channel) channel=${2:?}; shift 2 ;;
    --size-gib) size_gib=${2:?}; shift 2 ;;
    --package) extra_packages+=("${2:?}"); shift 2 ;;
    *) fail "unknown option: $1" ;;
  esac
done

[[ -d $output && -d $work ]] || fail "--output and --work must be existing directories"
[[ $channel == edge ]] || fail "aarch64 Omarchy is published on the edge channel only"
[[ $size_gib =~ ^[0-9]+$ ]] && ((size_gib >= 12)) || fail "--size-gib must be at least 12"
for package in "${extra_packages[@]}"; do
  [[ -f $package && $package == *.pkg.tar.zst ]] || fail "not a package archive: $package"
done
[[ $(uname -m) == aarch64 ]] || fail "the builder must run on aarch64"

kernel=linux-omarchy
# The packages omarchy-channel-set installs for the channel. On aarch64 the
# edge channel carries Omarchy's development line (the quattro branch, where
# the aarch64 platform support lives); the release packages there predate it.
runtime_package=omarchy-dev
settings_package=omarchy-settings-dev
omarchy_repository="https://pkgs.omarchy.org/$channel/\$arch"
arm_mirror='https://arm-mirror.omarchy.org/$arch/$repo'
esp_mib=2048

# One build per work volume: a failed build keeps its state for inspection
# until the next one starts.
rm -rf "$work"/build.*
state=$(mktemp -d "$work/build.XXXXXX")
cache=$work/pacman-cache
disk=$state/disk.img
target=$state/target
top=$state/top
mkdir -p "$cache" "$target" "$top"

esp_loop=""
root_loop=""
mounted=()

cleanup() {
  local status=$? index
  for ((index = ${#mounted[@]} - 1; index >= 0; index--)); do
    umount -R "${mounted[index]}" 2>/dev/null || umount -l "${mounted[index]}" 2>/dev/null || true
  done
  [[ -z $esp_loop ]] || losetup -d "$esp_loop" 2>/dev/null || true
  [[ -z $root_loop ]] || losetup -d "$root_loop" 2>/dev/null || true
  for hook in "${masked_hooks[@]}"; do
    rm -f "/etc/pacman.d/hooks/$hook"
  done
  if ((status == 0)); then
    rm -rf "$state"
  else
    echo "upstream-image: build failed; state kept at $state" >&2
  fi
  exit "$status"
}
masked_hooks=()
trap cleanup EXIT

do_mount() {
  mount "$@"
  mounted+=("${*: -1}")
}

# --- builder pacman configuration ------------------------------------------
# The repositories of upstream's default/pacman/aarch64/pacman-edge.conf, with
# the package cache kept in the build volume instead of the image.
builder_conf=$state/pacman.conf
cat >"$builder_conf" <<EOF
[options]
HoldPkg = pacman glibc
Architecture = aarch64
CacheDir = $cache/
ParallelDownloads = 5
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
DisableSandbox

[omarchy]
Server = $omarchy_repository

[core]
Server = $arm_mirror

[extra]
Server = $arm_mirror

[alarm]
Server = $arm_mirror

[aur]
Server = $arm_mirror
EOF

log "Refreshing the package databases"
pacman-key --populate omarchy >/dev/null
pacman --config "$builder_conf" -Syy --noconfirm >/dev/null
omarchy_db=/var/lib/pacman/sync/omarchy.db
[[ -f $omarchy_db ]] || fail "the [omarchy] database did not download"
# Every database the factory installs from, so a release can tell whether
# upstream moved since this build (scripts/factory-freshness.py --check).
repositories='{}'
for repository in omarchy core extra alarm aur; do
  database=/var/lib/pacman/sync/$repository.db
  [[ -f $database ]] || fail "the [$repository] database did not download"
  repositories=$(jq -c --arg name "$repository" --arg sha "$(sha256sum "$database" | cut -d' ' -f1)" \
    '. + {($name): $sha}' <<<"$repositories")
done

# --- disk ----------------------------------------------------------------
log "Creating a ${size_gib} GiB GPT disk"
truncate -s "${size_gib}G" "$disk"
# Partition types: EFI System, and Linux root (ARM64) so systemd's GPT tools
# recognise the root partition.
sfdisk --quiet "$disk" <<EOF
label: gpt
start=2048, size=$((esp_mib * 2048)), type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="OMARCHY_EFI"
start=$((2048 + esp_mib * 2048)), type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE, name="omarchy-root"
EOF

partition_field() { # partition-number field
  sfdisk --json "$disk" | jq -r --argjson n "$1" --arg f "$2" '.partitiontable.partitions[$n - 1][$f]'
}
esp_start=$(partition_field 1 start)
esp_size=$(partition_field 1 size)
root_start=$(partition_field 2 start)
root_size=$(partition_field 2 size)
root_partuuid=$(partition_field 2 uuid | tr 'A-Z' 'a-z')

esp_loop=$(losetup --find --show --offset $((esp_start * 512)) --sizelimit $((esp_size * 512)) "$disk")
root_loop=$(losetup --find --show --offset $((root_start * 512)) --sizelimit $((root_size * 512)) "$disk")

mkfs.vfat -F 32 -n OMARCHY_EFI "$esp_loop" >/dev/null
mkfs.btrfs -q -L omarchy "$root_loop"
esp_uuid=$(blkid -s UUID -o value "$esp_loop")
root_uuid=$(blkid -s UUID -o value "$root_loop")

do_mount "$root_loop" "$top"
for subvolume in @ @home @log @pkg; do
  btrfs -q subvolume create "$top/$subvolume"
done
btrfs_options=noatime,compress=zstd
do_mount -o "$btrfs_options,subvol=@" "$root_loop" "$target"
mkdir -p "$target/home" "$target/var/log" "$target/var/cache/pacman/pkg" "$target/boot"
do_mount -o "$btrfs_options,subvol=@home" "$root_loop" "$target/home"
do_mount -o "$btrfs_options,subvol=@log" "$root_loop" "$target/var/log"
do_mount -o "$btrfs_options,subvol=@pkg" "$root_loop" "$target/var/cache/pacman/pkg"
do_mount -o umask=0077 "$esp_loop" "$target/boot"

# --- packages ----------------------------------------------------------------
# Defer the initramfs and UKI to one final build, as the ISO does: these hooks
# would otherwise rebuild every kernel's image on each transaction. pacstrap
# reads the builder's hook directory, not the target's.
mkdir -p /etc/pacman.d/hooks
for hook in 60-mkinitcpio-remove.hook 60-limine-mkinitcpio-remove-pre.hook 80-limine-efi-deploy.hook \
  90-limine-mkinitcpio-remove-post.hook 90-mkinitcpio-install.hook; do
  ln -sfn /dev/null "/etc/pacman.d/hooks/$hook"
  masked_hooks+=("$hook")
done

# A temporary keyring with the repository keys; it is removed before sealing
# and every VM makes its own on first boot (the image-target keyring request).
install -d -m 0755 "$target/etc/pacman.d"
pacman-key --gpgdir "$target/etc/pacman.d/gnupg" --init >/dev/null 2>&1
pacman-key --gpgdir "$target/etc/pacman.d/gnupg" --populate archlinuxarm omarchy >/dev/null 2>&1

target_install() {
  pacstrap -C "$builder_conf" -G -M -c "$target" --needed "$@"
}

log "Installing the base system and $kernel"
target_install base "$kernel" "$kernel-headers" mkinitcpio

# A build-time identity for limine-entry-tool, which keys entries by machine
# ID. Sealing empties it; owner provisioning rebuilds the entries for the VM's
# own ID (omarchy-provision-owner limine_entries_stale).
systemd-machine-id-setup --root="$target" >/dev/null

log "Installing the early Omarchy packages"
# omarchy-iso orchestrator: EARLY_BOOTSTRAP_BASE_PACKAGES, the aarch64
# keyring, the settings package, then LuaRocks before omarchy-nvim.
target_install base-devel git limine efibootmgr omarchy-keyring archlinuxarm-keyring "$settings_package"
target_install lua51 luarocks
target_install omarchy-nvim

log "Installing Omarchy ($runtime_package)"
target_install "$runtime_package"

# The default set for the aarch64 platform, as omarchy-pkg-defaults composes
# it. Names the repositories do not carry for aarch64 are recorded, not fatal,
# like the Mac image builder's available_base.
mapfile -t default_set < <(arch-chroot "$target" env OMARCHY_PATH=/usr/share/omarchy \
  /usr/bin/omarchy-pkg-defaults aarch64)
((${#default_set[@]} > 0)) || fail "omarchy-pkg-defaults returned no packages"
available=()
unavailable=()
for name in "${default_set[@]}"; do
  if pacman --config "$builder_conf" -Sp --print-format x "$name" >/dev/null 2>&1; then
    available+=("$name")
  else
    unavailable+=("$name")
  fi
done
# The aarch64 runtime does not depend on the Limine/Snapper stack; UEFI
# aarch64 machines need it like x86_64 (orchestrator _runtime_package_list).
available+=(limine limine-mkinitcpio-hook limine-snapper-sync snapper)
log "Installing the default set (${#available[@]} packages; ${#unavailable[@]} unavailable on aarch64)"
target_install "${available[@]}"

if ((${#extra_packages[@]})); then
  # A local package's optional dependencies are what it needs but must not
  # pull in when the app upgrades it inside a VM; the image carries them.
  mapfile -t optional < <(for package in "${extra_packages[@]}"; do
    bsdtar -xOf "$package" .PKGINFO | sed -n 's/^optdepend = \([^:<>= ]*\).*/\1/p'
  done | sort -u)
  if ((${#optional[@]})); then
    log "Installing the local packages' optional dependencies: ${optional[*]}"
    target_install "${optional[@]}"
  fi
  log "Installing ${#extra_packages[@]} local package(s)"
  pacstrap -C "$builder_conf" -G -M -c -U "$target" "${extra_packages[@]}"
fi

# The same package-owned companion used by the pre-login integration update.
# This does not alter the disk layout, owner provisioning or import workflow.
arch-chroot "$target" /usr/lib/try-omarchy/hdr-install --defer-initramfs

# --- boot configuration --------------------------------------------------------
log "Configuring Limine"
# The ESP, written once the packages exist. The firmware boots the removable
# path: a VM's variable store is new and holds no boot entry for Limine.
install -d "$target/boot/EFI/BOOT" "$target/boot/EFI/limine"
cp "$target/usr/share/limine/BOOTAA64.EFI" "$target/boot/EFI/BOOT/BOOTAA64.EFI"
cp "$target/usr/share/limine/BOOTAA64.EFI" "$target/boot/EFI/limine/limine_aa64.efi"
cat >"$target/etc/pacman.d/hooks/99-omarchy-limine.hook" <<'EOF'
[Trigger]
Operation = Upgrade
Type = Package
Target = limine

[Action]
Description = Deploying Omarchy Limine after upgrade...
When = PostTransaction
Exec = /bin/sh -c "/usr/bin/cp /usr/share/limine/BOOTAA64.EFI /boot/EFI/limine/limine_aa64.efi && /usr/bin/cp /usr/share/limine/BOOTAA64.EFI /boot/EFI/BOOT/BOOTAA64.EFI"
EOF

# archinstall's kernel parameters for an unencrypted btrfs root.
cmdline="root=PARTUUID=$root_partuuid zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs"
limine_template=$target/usr/share/omarchy/default/limine
[[ -f $limine_template/default.conf && -f $limine_template/limine.conf ]] || fail "omarchy ships no Limine templates"
sed -e "s|@@CMDLINE@@|$cmdline|" -e 's|^ESP_PATH=.*$|ESP_PATH="/boot"|' "$limine_template/default.conf" \
  >"$target/etc/default/limine"
printf '%s\n' "$cmdline" >"$target/etc/kernel/cmdline" 2>/dev/null || {
  install -d "$target/etc/kernel"
  printf '%s\n' "$cmdline" >"$target/etc/kernel/cmdline"
}
install -d "$target/etc/limine-entry-tool.d"
cat >"$target/etc/limine-entry-tool.d/00-omarchy-console.conf" <<'EOF'
# aarch64: keep the console on the screen rather than the firmware's serial port.
KERNEL_CMDLINE[default]+=" console=tty0 acpi=nospcr"
EOF
cp "$limine_template/limine.conf" "$target/boot/limine.conf"

cat >"$target/etc/fstab" <<EOF
# <file system> <dir> <type> <options> <dump> <pass>
UUID=$root_uuid  /                      btrfs  rw,$btrfs_options,subvol=/@     0 0
UUID=$root_uuid  /home                  btrfs  rw,$btrfs_options,subvol=/@home 0 0
UUID=$root_uuid  /var/log               btrfs  rw,$btrfs_options,subvol=/@log  0 0
UUID=$root_uuid  /var/cache/pacman/pkg  btrfs  rw,$btrfs_options,subvol=/@pkg  0 0
UUID=$esp_uuid  /boot                  vfat   rw,noatime,fmask=0077,dmask=0077,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro 0 2
EOF

# Neutral placeholders the owner replaces on first boot (configurator dry-run
# defaults for a deferred install).
printf 'omarchy\n' >"$target/etc/hostname"
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' "$target/etc/locale.gen"
arch-chroot "$target" locale-gen >/dev/null
printf 'LANG=en_US.UTF-8\n' >"$target/etc/locale.conf"
printf 'KEYMAP=us\nXKBLAYOUT=us\n' >"$target/etc/vconsole.conf"
ln -sfn /usr/share/zoneinfo/UTC "$target/etc/localtime"

# --- Omarchy system setup --------------------------------------------------------
log "Running omarchy-apply-system --defer-provisioning --first-install"
install -d -m 0755 "$target/var/lib/omarchy" "$target/var/lib/omarchy/image"
omarchy_db_sha256=$(sha256sum "$omarchy_db" | cut -d' ' -f1)
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'format=1\nplatform=aarch64\nbuilder=try-omarchy-upstream\nchannel=%s\nchannel_db_sha256=%s\nbuilt=%s\n' \
  "$channel" "$omarchy_db_sha256" "$built" >"$target/var/lib/omarchy/image/target"
chmod 0644 "$target/var/lib/omarchy/image/target"

# Inside the chroot only the install hook is worth deferring (orchestrator
# TARGET_DEFERRED_BOOT_HOOKS).
ln -sfn /dev/null "$target/etc/pacman.d/hooks/90-mkinitcpio-install.hook"
cp "$builder_conf" "$target/etc/pacman.conf"
sed -i "s|^CacheDir = .*|CacheDir = /var/cache/omarchy-build/|" "$target/etc/pacman.conf"
install -d "$target/var/cache/omarchy-build"
do_mount --bind "$cache" "$target/var/cache/omarchy-build"
arch-chroot "$target" env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/bin HOME=/root TERM=dumb LANG=C.UTF-8 \
  OMARCHY_PATH=/usr/share/omarchy OMARCHY_INSTALL=/usr/share/omarchy/install \
  OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log OMARCHY_LOG_TO_STDOUT=1 \
  /usr/bin/omarchy-apply-system --defer-provisioning --first-install
umount "$target/var/cache/omarchy-build"
unset 'mounted[${#mounted[@]}-1]'
rmdir "$target/var/cache/omarchy-build"
rm -f "$target/etc/pacman.d/hooks/90-mkinitcpio-install.hook"

[[ -f $target/var/lib/omarchy/image/deferred-steps ]] || fail "apply-system deferred no hardware steps"

# --- owner provisioning (orchestrator stage_provisioning_state) ------------------
log "Arming first-boot owner provisioning"
provisioning=$target/var/lib/omarchy/provisioning
install -d -m 0755 "$provisioning" "$provisioning/packages"
node_index=$(curl -fsSL https://nodejs.org/dist/latest/SHASUMS256.txt)
read -r node_sha node_file < <(awk '$2 ~ /^node-v[0-9.]+-linux-arm64\.tar\.gz$/ { print $1, $2; exit }' <<<"$node_index")
[[ -n ${node_file:-} ]] || fail "no Node.js linux-arm64 release found"
curl -fsSL "https://nodejs.org/dist/latest/$node_file" -o "$provisioning/packages/$node_file"
echo "$node_sha  $provisioning/packages/$node_file" | sha256sum -c --quiet -
touch "$provisioning/pending"
install -m 0644 "$target/usr/share/omarchy/install/provisioning/omarchy-provision-owner.service" \
  "$target/etc/systemd/system/omarchy-provision-owner.service"
install -d "$target/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/omarchy-provision-owner.service \
  "$target/etc/systemd/system/multi-user.target.wants/omarchy-provision-owner.service"

# --- login and name resolution (orchestrator configure_login/dns) --------------
install -d "$target/etc/sddm.conf.d"
printf '[Theme]\nCurrent=omarchy\n\n[Users]\nRememberLastUser=true\nRememberLastSession=true\n' \
  >"$target/etc/sddm.conf.d/99-omarchy-login.conf"
rm -f "$target/etc/sddm.conf.d/autologin.conf" "$target/etc/systemd/system/getty@tty1.service.d/autologin.conf"
arch-chroot "$target" systemctl enable sddm.service >/dev/null 2>&1 || true

# --- the final UKI (orchestrator finalize_limine_boot) -----------------------
log "Building the unified kernel image"
# mkinitcpio fails on a module this kernel lacks; drop those names last.
listed=$(sed -n 's/^\s*MODULES+\?=(\([^)]*\)).*/\1/p' "$target"/etc/mkinitcpio.conf.d/*.conf 2>/dev/null | tr -d "\"'" | tr ' ' '\n' | sed '/^$/d' | sort -u)
kernel_release=$(basename "$(dirname "$(ls "$target"/usr/lib/modules/*/pkgbase | head -1)")")
missing=()
for module in $listed; do
  modinfo --basedir "$target" -k "$kernel_release" "$module" >/dev/null 2>&1 || missing+=("$module")
done
if ((${#missing[@]})); then
  cat >"$target/etc/mkinitcpio.conf.d/zz-omarchy-absent-modules.conf" <<EOF
# Written by the image builder. The installed kernel has no such
# modules, and mkinitcpio fails on a module it cannot find.
_omarchy_absent=(${missing[*]})
_omarchy_kept=()
for _omarchy_module in "\${MODULES[@]}"; do
  [[ " \${_omarchy_absent[*]} " == *" \$_omarchy_module "* ]] || _omarchy_kept+=("\$_omarchy_module")
done
MODULES=("\${_omarchy_kept[@]}")
unset _omarchy_absent _omarchy_kept _omarchy_module
EOF
fi
for hook in "${masked_hooks[@]}"; do
  rm -f "/etc/pacman.d/hooks/$hook"
done
masked_hooks=()
arch-chroot "$target" limine-update
grep -q Omarchy "$target/boot/limine.conf" || fail "limine.conf has no Omarchy entry"
# try-omarchy's limine-entry-tool drop-in adds the virtio console that the Mac
# app keeps as console.log.
if [[ -f $target/etc/limine-entry-tool.d/50-try-omarchy-console.conf ]]; then
  grep -rqa 'console=hvc0' "$target/boot" || fail "the kernel image lacks try-omarchy's console=hvc0"
fi
btrfs quota disable "$target" 2>/dev/null || true

# --- installed configuration -----------------------------------------------------
log "Writing the installed pacman configuration"
templates=$target/usr/share/omarchy/default/pacman/aarch64
[[ -f $templates/pacman-$channel.conf && -f $templates/mirrorlist-$channel ]] ||
  fail "omarchy ships no aarch64 $channel pacman template"
install -m 0644 "$templates/pacman-$channel.conf" "$target/etc/pacman.conf"
install -m 0644 "$templates/mirrorlist-$channel" "$target/etc/pacman.d/mirrorlist"

ln -sfn ../run/systemd/resolve/stub-resolv.conf "$target/etc/resolv.conf"

# --- provenance --------------------------------------------------------------
log "Recording provenance"
arch-chroot "$target" pacman -Q | LC_ALL=C sort >"$state/packages.txt"
if ((${#unavailable[@]})); then
  printf '%s\n' "${unavailable[@]}" >"$state/unavailable.txt"
else
  : >"$state/unavailable.txt"
fi
omarchy_version=$(awk -v p="$runtime_package" '$1 == p { print $2 }' "$state/packages.txt")
kernel_version=$(awk -v k="$kernel" '$1 == k { print $2 }' "$state/packages.txt")

# --- seal ------------------------------------------------------------------------
log "Sealing the image"
# No shared identity: machine ID, random seed, SSH host keys, pacman keyring.
: >"$target/etc/machine-id"
rm -f "$target/var/lib/systemd/random-seed" "$target"/etc/ssh/ssh_host_*
rm -rf "$target/etc/pacman.d/gnupg"
[[ -f $target/var/lib/omarchy/image/pacman-keyring ]] || fail "the image requests no first-boot pacman keyring"
find "$target/var/cache/pacman/pkg" -mindepth 1 -delete
rm -rf "$target/root/.cache" "$target/var/tmp/"*

# Omarchy's factory reset restores @factory (orchestrator create_factory_snapshot).
btrfs -q subvolume snapshot -r "$top/@" "$top/@factory"

# Discard freed blocks (the package downloads and build churn) so the loop
# file is sparse where the filesystems are empty: the compressed image is
# smaller and a VM disk cloned from it allocates only what is in use.
# A balance first packs the data into as few block groups as possible, so
# the free space becomes long zero runs instead of scattered small extents.
btrfs balance start --full-balance "$top" >/dev/null
fstrim -v "$target/boot" || true
fstrim -v "$top" || true
sync
for ((index = ${#mounted[@]} - 1; index >= 0; index--)); do
  umount -R "${mounted[index]}"
done
mounted=()
losetup -d "$esp_loop" "$root_loop"
esp_loop=""
root_loop=""

log "Compressing"
image_name=omarchy-aarch64-$channel.img
zstd -q -T0 -10 --rm "$disk" -o "$state/$image_name.zst"
image_sha256=$(zstd -dc "$state/$image_name.zst" | sha256sum | cut -d' ' -f1)
compressed_sha256=$(sha256sum "$state/$image_name.zst" | cut -d' ' -f1)
image_bytes=$((size_gib * 1024 * 1024 * 1024))

mv "$state/$image_name.zst" "$output/"
mv "$state/packages.txt" "$output/packages.txt"
mv "$state/unavailable.txt" "$output/unavailable.txt"
jq -n \
  --arg channel "$channel" --arg built "$built" --arg db "$omarchy_db_sha256" \
  --arg omarchy "$omarchy_version" --arg kernel "$kernel_version" \
  --arg image "$image_name" --arg sha "$image_sha256" --argjson bytes "$image_bytes" \
  --arg compressed "$image_name.zst" --arg csha "$compressed_sha256" \
  --arg root_partuuid "$root_partuuid" --arg node "$node_file" --arg node_sha "$node_sha" \
  --argjson repositories "$repositories" \
  '{
    format: 1,
    kind: "upstream-shell-factory",
    platform: "aarch64",
    channel: $channel,
    built: $built,
    omarchy: $omarchy,
    kernel: $kernel,
    omarchy_db_sha256: $db,
    repositories: $repositories,
    boot: "uefi-limine",
    root_partuuid: $root_partuuid,
    node: { file: $node, sha256: $node_sha },
    disk: { path: $image, bytes: $bytes, sha256: $sha },
    compressed: { path: $compressed, sha256: $csha }
  }' >"$output/factory.json"
(cd "$output" && sha256sum "$image_name.zst" factory.json packages.txt unavailable.txt >SHA256SUMS)
log "Factory image: $output/$image_name.zst (omarchy $omarchy_version, $kernel $kernel_version)"
