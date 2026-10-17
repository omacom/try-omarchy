#!/bin/bash

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: macos/build-app.sh [--open] [--dmg] [--guest-dir DIR]
                                  [--configuration development|production]
                                  [--sign-identity IDENTITY]
                                  [--notarize-profile PROFILE]
                                  [--factory-download-url URL]

Build a self-contained Apple Silicon app. Development builds select a stable
local signing certificate automatically. Production builds require an explicit
signing identity. --dmg requires --configuration production.
--notarize-profile implies --dmg and names a notarytool keychain profile.

Development builds carry the compressed factory. Production builds, and any
build given --factory-download-url, carry a download manifest instead and write
the image's parts to dist/factory/ for upload beside the DMG. Production builds
default to the GitHub release of HEAD's vX.Y.Z tag.
EOF
  exit 64
}

open_app=0
build_dmg=0
guest_dir=
configuration=development
sign_identity=${OMARCHY_CODESIGN_IDENTITY:-auto}
notarize_profile=
factory_download_url=
while (($#)); do
  case "$1" in
    --open) open_app=1; shift ;;
    --dmg) build_dmg=1; shift ;;
    --configuration)
      (($# >= 2)) || usage
      configuration=$2
      shift 2
      ;;
    --guest-dir)
      (($# >= 2)) || usage
      guest_dir=$2
      shift 2
      ;;
    --sign-identity)
      (($# >= 2)) || usage
      sign_identity=$2
      shift 2
      ;;
    --notarize-profile)
      (($# >= 2)) || usage
      notarize_profile=$2
      build_dmg=1
      shift 2
      ;;
    --factory-download-url)
      (($# >= 2)) || usage
      factory_download_url=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

macos_major=$(sw_vers -productVersion | cut -d. -f1)
[[ $macos_major =~ ^[0-9]+$ ]] && (( macos_major >= 15 )) || {
  echo "build-app: macOS 15 or newer is required" >&2
  exit 1
}

macos_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$macos_dir/.." && pwd -P)
case "$configuration" in
  development)
    bundle_identifier=dev.tryomarchy.native.development
    app_display_name='Try Omarchy Dev'
    (( build_dmg == 0 )) || {
      echo 'build-app: --dmg requires --configuration production' >&2
      exit 1
    }
    sign_identity=$(python3 "$macos_dir/development-sign-identity.py" "$sign_identity")
    ;;
  production)
    bundle_identifier=dev.tryomarchy.native
    app_display_name='Try Omarchy'
    [[ $sign_identity != auto ]] || {
      echo 'build-app: production requires --sign-identity (use - for an explicit ad-hoc test build)' >&2
      exit 1
    }
    # The app downloads its factory from the release it ships in.
    if [[ -z $factory_download_url ]]; then
      release_tag=$(git -C "$repo_dir" describe --tags --exact-match --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null) || {
        echo 'build-app: production downloads the factory from the release of HEAD'"'"'s vX.Y.Z tag; tag HEAD or pass --factory-download-url' >&2
        exit 1
      }
      factory_download_url="https://github.com/omacom/try-omarchy/releases/download/$release_tag/"
    fi
    ;;
  *) usage ;;
esac
helper="$macos_dir/.build/release/omarchy-vm-helper"
legacy_app="$repo_dir/dist/Try Omarchy.app"
app="$repo_dir/dist/app.noindex/Try Omarchy.app"
if [[ $configuration == production ]]; then
  app="$repo_dir/dist/release.noindex/Try Omarchy.app"
fi
contents="$app/Contents"
bundled_qemu="$contents/Resources/runtime/bin/Try Omarchy"
module_cache="$macos_dir/.build/module-cache"
runtime_source="$macos_dir/.build/qemu-gpu-runtime"
guest_dir=${guest_dir:-"$repo_dir/dist/guest"}
firmware_source="$macos_dir/.build/firmware"
dependency_bundler="$macos_dir/bundle-macho-dependencies.sh"
compatibility_verifier="$macos_dir/verify-macos-compatibility.sh"
package_dmg="$macos_dir/package-dmg.sh"
app_icon_source="$macos_dir/OmarchyIcon.svg"
app_icon_renderer_source="$macos_dir/render-app-icon.swift"
app_icon_packer="$macos_dir/pack-app-icon.py"
icon_renderer="$macos_dir/.build/app-icon-renderer"
iconset="$macos_dir/.build/TryOmarchy.iconset"
generated_icon="$macos_dir/.build/TryOmarchy.icns"

[[ -d $runtime_source && ! -L $runtime_source ]] || {
  echo "build-app: missing staged QEMU runtime; run build-qemu-gpu-runtime.sh first" >&2
  exit 1
}
[[ -d $guest_dir && ! -L $guest_dir ]] || {
  echo "build-app: missing factory guest directory: $guest_dir" >&2
  exit 1
}
guest_dir=$(cd "$guest_dir" && pwd -P)
# The factory (guest/factory) boots through UEFI firmware; see docs/architecture.md.
[[ -f $guest_dir/factory.json && ! -L $guest_dir/factory.json ]] || {
  echo "build-app: $guest_dir has no factory.json; run make guest" >&2
  exit 1
}
guest_packages=${OMARCHY_GUEST_PACKAGES:-"$guest_dir/packages"}
[[ -f $firmware_source/edk2-aarch64-code.fd && -f $firmware_source/edk2-licenses.txt ]] || {
  echo "build-app: missing UEFI firmware; run make firmware" >&2
  exit 1
}
[[ -x $dependency_bundler && ! -L $dependency_bundler ]] || {
  echo "build-app: dependency bundler is missing or unsafe" >&2
  exit 1
}
[[ -x $compatibility_verifier && ! -L $compatibility_verifier ]] || {
  echo "build-app: compatibility verifier is missing or unsafe" >&2
  exit 1
}
[[ -f $app_icon_source && ! -L $app_icon_source ]] || {
  echo "build-app: app icon source is missing or unsafe" >&2
  exit 1
}
[[ -f $app_icon_renderer_source && ! -L $app_icon_renderer_source ]] || {
  echo "build-app: app icon renderer is missing or unsafe" >&2
  exit 1
}
[[ -f $app_icon_packer && ! -L $app_icon_packer ]] || {
  echo "build-app: app icon packer is missing or unsafe" >&2
  exit 1
}
for tool in python3 sips xcrun; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "build-app: $tool is required to render the app icon" >&2
    exit 1
  }
done
if [[ -n $notarize_profile && $sign_identity == - ]]; then
  echo "build-app: notarization requires --sign-identity with a Developer ID Application identity" >&2
  exit 1
fi
[[ -x $runtime_source/bin/zstd && ! -L $runtime_source/bin/zstd ]] || {
  echo "build-app: staged runtime is missing pinned zstd" >&2
  exit 1
}

if [[ -e $legacy_app || -L $legacy_app ]]; then
  lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  if [[ -x $lsregister ]]; then
    "$lsregister" -u "$legacy_app" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$legacy_app"
fi
mkdir -p "$(dirname "$app")"
# A .noindex container is the supported per-directory Spotlight exclusion.
# Removing and unregistering the legacy bundle above also prevents a previously
# indexed build at the old path from surviving this migration.
cd "$macos_dir"
mkdir -p "$module_cache/swift" "$module_cache/clang" "$module_cache/icon"
export SWIFT_MODULECACHE_PATH="$module_cache/swift"
export CLANG_MODULE_CACHE_PATH="$module_cache/clang"
export MACOSX_DEPLOYMENT_TARGET=15.0
swift build --disable-sandbox -c release -debug-info-format none

rm -rf "$iconset"
rm -f "$generated_icon"
mkdir "$iconset"
xcrun swiftc \
  -module-cache-path "$module_cache/icon" \
  -framework AppKit \
  "$app_icon_renderer_source" \
  -o "$icon_renderer"
"$icon_renderer" "$app_icon_source" "$iconset/icon_512x512@2x.png"
while IFS=$'\t' read -r icon_name icon_pixels; do
  sips \
    -z "$icon_pixels" "$icon_pixels" \
    "$iconset/icon_512x512@2x.png" \
    --out "$iconset/$icon_name" >/dev/null
done <<'ICON_SIZES'
icon_16x16.png	16
icon_16x16@2x.png	32
icon_32x32.png	32
icon_32x32@2x.png	64
icon_128x128.png	128
icon_128x128@2x.png	256
icon_256x256.png	256
icon_256x256@2x.png	512
icon_512x512.png	512
ICON_SIZES
python3 "$app_icon_packer" "$iconset" "$generated_icon"
[[ -f $generated_icon && ! -L $generated_icon ]] || {
  echo "build-app: generated app icon is missing or unsafe" >&2
  exit 1
}

rm -rf "$app"
mkdir -p \
  "$contents/MacOS" \
  "$contents/Resources/guest" \
  "$contents/Resources/runtime/bin" \
  "$contents/Resources/scripts"
bash "$macos_dir/network-helper/build.sh" "$contents/Resources/network"
mkdir -p "$contents/Library/LaunchDaemons"
install -m 0644 "$macos_dir/network-helper/dev.tryomarchy.network.plist" "$contents/Library/LaunchDaemons/dev.tryomarchy.network.plist"
python3 - "$contents/Library/LaunchDaemons/dev.tryomarchy.network.plist" <<'PYTHON'
import os, plistlib, sys
from pathlib import Path
path = Path(sys.argv[1])
service = os.environ.get("OMARCHY_NETWORK_SERVICE_NAME", "dev.tryomarchy.network")
value = plistlib.loads(path.read_bytes())
value["Label"] = service
value["MachServices"] = {service: True}
path.write_bytes(plistlib.dumps(value))
PYTHON
install -m 0644 "$macos_dir/network-helper/vendor/LICENSE" "$contents/Resources/network/LICENSE.socket_vmnet"
install -m 0755 "$helper" "$contents/MacOS/omarchy-vm-helper"
install -m 0644 "$macos_dir/Info.plist" "$contents/Info.plist"
python3 - "$contents/Info.plist" "$bundle_identifier" "$app_display_name" <<'PYTHON'
import plistlib, sys
from pathlib import Path
path = Path(sys.argv[1])
value = plistlib.loads(path.read_bytes())
value["CFBundleIdentifier"] = sys.argv[2]
value["CFBundleName"] = value["CFBundleDisplayName"] = sys.argv[3]
path.write_bytes(plistlib.dumps(value))
PYTHON
python3 "$repo_dir/scripts/app_version.py" \
  --root "$repo_dir" --plist "$contents/Info.plist"
install -m 0644 "$macos_dir/Credits.rtf" "$contents/Resources/Credits.rtf"
install -m 0644 "$repo_dir/LICENSE" "$contents/Resources/LICENSE"
install -m 0644 "$generated_icon" "$contents/Resources/TryOmarchy.icns"
ditto "$runtime_source" "$contents/Resources/runtime"
install -m 0755 "$macos_dir/run-qemu-gpu.sh" "$contents/Resources/scripts/run-qemu-gpu.sh"
install -m 0644 "$macos_dir/qemu-port-forwarding.sh" \
  "$contents/Resources/scripts/qemu-port-forwarding.sh"
install -m 0644 "$macos_dir/qemu-networking.sh" "$contents/Resources/scripts/qemu-networking.sh"
install -m 0644 "$macos_dir/network-identity.py" "$contents/Resources/scripts/network-identity.py"
compressed_name=$(/usr/bin/plutil -extract compressed.path raw -o - "$guest_dir/factory.json")
guest_resources=(factory.json packages.txt SHA256SUMS)
if [[ -n $factory_download_url ]]; then
  # The image is over GitHub's 2 GiB asset limit and is only needed for a new
  # VM, so the app downloads it (FactoryImageDownload.swift).
  python3 "$repo_dir/scripts/split-factory-image.py" \
    --guest-dir "$guest_dir" --base-url "$factory_download_url" \
    --output "$repo_dir/dist/factory" --manifest "$contents/Resources/guest/download.json"
  chmod 0644 "$contents/Resources/guest/download.json"
else
  guest_resources+=("$compressed_name")
fi
for guest_resource in "${guest_resources[@]}"; do
  [[ -f $guest_dir/$guest_resource && ! -L $guest_dir/$guest_resource ]] || {
    echo "build-app: factory guest resource is missing or unsafe: $guest_resource" >&2
    exit 1
  }
  cp -c "$guest_dir/$guest_resource" "$contents/Resources/guest/$guest_resource"
  chmod 0644 "$contents/Resources/guest/$guest_resource"
done
# The try-omarchy package the launcher offers the guest on every boot.
mkdir -p "$contents/Resources/guest-packages"
shopt -s nullglob
packages=("$guest_packages"/try-omarchy-*.pkg.tar.zst)
shopt -u nullglob
((${#packages[@]} == 1)) || {
  echo "build-app: expected exactly one try-omarchy package in $guest_packages" >&2
  exit 1
}
install -m 0644 "${packages[0]}" "$contents/Resources/guest-packages/"
mkdir -p "$contents/Resources/firmware"
install -m 0644 "$firmware_source/edk2-aarch64-code.fd" "$firmware_source/edk2-licenses.txt" \
  "$contents/Resources/firmware/"

mv "$contents/Resources/runtime/bin/qemu-system-aarch64" "$bundled_qemu"
"$dependency_bundler" --verify-only "$contents/Resources/runtime"

sign_options=(--force --sign "$sign_identity")
if [[ $sign_identity != - ]]; then
  sign_options+=(--options runtime)
  if [[ $configuration == production ]]; then
    sign_options+=(--timestamp)
  else
    # Local rebuilds need a stable identity, not a distribution timestamp.
    # Explicitly disable it: Developer ID identities otherwise request one
    # by default, including when selected as a development fallback.
    sign_options+=(--timestamp=none)
  fi
fi
app_sign_options=("${sign_options[@]}" --identifier "$bundle_identifier")
qemu_sign_options=("${sign_options[@]}" --identifier "$bundle_identifier")
for library in "$contents/Resources/runtime/lib"/*.dylib; do
  codesign "${sign_options[@]}" "$library"
done
codesign "${sign_options[@]}" "$contents/Resources/runtime/bin/zstd"
for network_binary in socket_vmnet omarchy-network-supervisor omarchy-network-client; do
  codesign "${sign_options[@]}" "$contents/Resources/network/$network_binary"
done
codesign "${qemu_sign_options[@]}" \
  --entitlements "$macos_dir/qemu-hvf.entitlements" \
  "$bundled_qemu"

bash "$macos_dir/network-helper/build-daemon.sh" "$contents"
codesign "${sign_options[@]}" "$contents/MacOS/omarchy-network-daemon"
codesign "${app_sign_options[@]}" \
  --entitlements "$macos_dir/omarchy-vm-helper.entitlements" \
  "$contents/MacOS/omarchy-vm-helper"

# The launcher must accept the factory it ships with.
OMARCHY_QEMU_GPU_INSPECT_ONLY=1 "$contents/Resources/scripts/run-qemu-gpu.sh" >/dev/null || {
  echo "build-app: the bundled launcher rejects the factory" >&2
  exit 1
}

codesign "${app_sign_options[@]}" \
  --entitlements "$macos_dir/omarchy-vm-helper.entitlements" \
  "$app"
codesign --verify --deep --strict --verbose=2 "$app"
"$compatibility_verifier" "$app"

echo "[native] Built $app"
if (( build_dmg )); then
  dmg="$repo_dir/dist/TryOmarchy.dmg"
  rm -f "$dmg"
  package_options=()
  if [[ $sign_identity != - ]]; then
    package_options+=(--sign-identity "$sign_identity")
  fi
  if [[ -n $notarize_profile ]]; then
    package_options+=(--notarize-profile "$notarize_profile")
  fi
  if ((${#package_options[@]})); then
    "$package_dmg" "${package_options[@]}" "$app" "$dmg"
  else
    "$package_dmg" "$app" "$dmg"
  fi
fi
if (( open_app )); then
  open "$app"
fi
