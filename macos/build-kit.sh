#!/bin/bash
#
# Derives the kit from a built app: the helper bundle another app embeds to
# run the VM through the helper's run mode (docs/vm-kit.md). It has no bundle
# identity, downloads its factory, and carries a bridged-networking daemon
# under its own service name that the embedding app registers as itself.
#
#   macos/build-kit.sh --app APP --output DIR [--sign-identity IDENTITY] [--notarize-profile PROFILE]
#
# Writes DIR/TryOmarchyKit.bundle, DIR/TryOmarchyKit.zip, its digest
# DIR/TryOmarchyKit.zip.sha256, and DIR/TryOmarchyKit.json, a copy of the
# kit's manifest. Every Mach-O in the kit is signed with IDENTITY
# (scripts/kit_signature.py). With PROFILE, a notarytool keychain profile, the
# archive is notarized and rebuilt from the stapled kit, so the digest is of
# the published bytes. An embedding app re-signs its own copy.

set -euo pipefail

fail() {
  echo "build-kit: $*" >&2
  exit 1
}
usage() {
  sed -n '7p' "$0" | sed 's/^# *//' >&2
  exit 64
}

app=''
output=''
sign_identity=-
notarize_profile=''
while (($#)); do
  case $1 in
    --app) (($# >= 2)) || usage; app=$2; shift 2 ;;
    --output) (($# >= 2)) || usage; output=$2; shift 2 ;;
    --sign-identity) (($# >= 2)) || usage; sign_identity=$2; shift 2 ;;
    --notarize-profile) (($# >= 2)) || usage; notarize_profile=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n $app && -n $output ]] || usage
[[ -d $app && ! -L $app ]] || fail "no app at $app"
[[ -z $notarize_profile || $sign_identity == "Developer ID Application:"* ]] ||
  fail "notarization requires a Developer ID Application identity"
macos_dir=$(cd "$(dirname "$0")" && pwd -P)
repo_dir=$(cd "$macos_dir/.." && pwd -P)
app=$(cd "$app" && pwd -P)
mkdir -p "$output"
output=$(cd "$output" && pwd -P)

kit_name=TryOmarchyKit.bundle
kit="$output/$kit_name"
archive="$output/TryOmarchyKit.zip"
contents="$kit/Contents"
guest="$contents/Resources/guest"

manifest="$output/TryOmarchyKit.json"
rm -rf "$kit" "$archive" "$archive.sha256" "$manifest"
ditto "$app" "$kit"
# The embedding app owns its updates, so the kit drops Sparkle; the helper
# links it weakly.
rm -rf "$contents/_CodeSignature" "$contents/Library" "$contents/MacOS/omarchy-network-daemon" \
  "$contents/Frameworks"

[[ -f $guest/download.json && ! -L $guest/download.json ]] ||
  fail "the app carries no factory download manifest; build it with --configuration production"
compressed=$(/usr/bin/plutil -extract compressed.path raw -o - "$guest/factory.json")
[[ ! -e $guest/$compressed ]] || fail "the app carries its factory image; a kit downloads it"

# No identifier or name: macOS files preferences, permissions and Launch
# Services records under those, and the kit runs as the app that starts it.
python3 - "$contents/Info.plist" <<'PYTHON'
import plistlib, sys
from pathlib import Path
path = Path(sys.argv[1])
app = plistlib.loads(path.read_bytes())
path.write_bytes(plistlib.dumps({
    "CFBundleExecutable": app["CFBundleExecutable"],
    "CFBundlePackageType": "BNDL",
    "LSUIElement": True,
    "NSHighResolutionCapable": True,
}))
PYTHON
python3 "$repo_dir/scripts/kit_manifest.py" --root "$repo_dir" --app "$app" --output "$contents/Resources/kit.json"

team=()
[[ ! $sign_identity =~ \(([A-Z0-9]+)\)$ ]] || team=(--team "${BASH_REMATCH[1]}")

# The kit's own networking service, so an app that embeds it never shares the
# full app's registration. The daemon pins the client and payloads it is
# built with, so they are signed before it, and nobody re-signs them after.
network_service=dev.tryomarchy.kit.network
network="$contents/Resources/network"
network_daemon="$contents/MacOS/omarchy-network-daemon"
network_build=$(mktemp -d /private/tmp/omarchy-kit-network.XXXXXX)
trap 'rm -rf "$network_build"' EXIT
OMARCHY_NETWORK_SERVICE_NAME=$network_service bash "$macos_dir/network-helper/build.sh" "$network_build"
install -m 0755 "$network_build/omarchy-network-client" "$network/omarchy-network-client"
python3 "$repo_dir/scripts/kit_signature.py" sign --pinned --identity "$sign_identity" "$kit"
OMARCHY_NETWORK_SERVICE_NAME=$network_service \
  bash "$macos_dir/network-helper/build-daemon.sh" "$network_daemon" "$contents/Resources"
python3 - "$macos_dir/network-helper/dev.tryomarchy.network.plist" "$network/launchd.plist" \
  "$network_service" "${network_daemon#"$kit/"}" <<'PYTHON'
import plistlib, sys
from pathlib import Path
source, destination, service, program = sys.argv[1:]
value = plistlib.loads(Path(source).read_bytes())
value.update(Label=service, MachServices={service: True}, BundleProgram=program)
Path(destination).write_bytes(plistlib.dumps(value))
PYTHON

python3 "$repo_dir/scripts/kit_signature.py" sign --identity "$sign_identity" "$kit"
python3 "$repo_dir/scripts/kit_signature.py" verify --signature-only ${team[@]+"${team[@]}"} "$kit"

# The kit's launcher must accept the factory it describes.
OMARCHY_QEMU_GPU_INSPECT_ONLY=1 "$contents/Resources/scripts/run-qemu-gpu.sh" >/dev/null ||
  fail "the kit's launcher rejects its factory"

(cd "$output" && ditto -c -k --keepParent "$kit_name" "$archive")
if [[ -n $notarize_profile ]]; then
  python3 "$repo_dir/scripts/kit_signature.py" notarize --profile "$notarize_profile" "$archive"
  python3 "$repo_dir/scripts/kit_signature.py" staple "$kit"
  rm "$archive"
  (cd "$output" && ditto -c -k --keepParent "$kit_name" "$archive")
  python3 "$repo_dir/scripts/kit_signature.py" verify --require-notarization ${team[@]+"${team[@]}"} "$kit"
fi
digest=$(/usr/bin/shasum -a 256 "$archive" | cut -d' ' -f1)
printf '%s  %s\n' "$digest" "${archive##*/}" >"$archive.sha256"
cp "$contents/Resources/kit.json" "$manifest"
echo "[kit] Built $archive ($digest)"
