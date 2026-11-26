#!/bin/bash
#
# Checks a built kit the way an embedding app receives it (docs/vm-kit.md):
# the archive and its digest, the bundle and the signature of every Mach-O in
# it, no bundle identity, QEMU starting with its libraries, the manifest, the
# guest resources, the bridged-networking runtime, the launcher's self-check,
# and the run mode's refusals from the kit's own helper. Starts no VM.
#
#   tests/kit/check.sh [KIT_DIR]    (default: dist/kit.noindex, from make kit)
#
# KIT_TEAM_ID requires every Mach-O to be signed by that team, refusing an ad
# hoc kit. KIT_NOTARIZED=1 requires a notarized, stapled kit; KIT_NOTARIZED=0
# skips that check for a kit signed but not notarized. Unset, an ad hoc kit
# passes, and a Developer ID kit must be signed by RZC79MPD34 and notarized.

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd -P)
output=${1:-"$root/dist/kit.noindex"}
fail() {
  echo "kit-check: $*" >&2
  exit 1
}
[[ -d $output ]] || fail "no kit in $output; run make kit"
output=$(cd "$output" && pwd -P)
kit_name=TryOmarchyKit.bundle
kit="$output/$kit_name"
contents="$kit/Contents"
resources="$contents/Resources"
archive="$output/TryOmarchyKit.zip"
scratch=$(mktemp -d '/private/tmp/omarchy-kit-check.XXXXXX')
trap 'rm -rf "$scratch"' EXIT

for file in "$kit" "$archive" "$archive.sha256" "$output/TryOmarchyKit.json"; do
  [[ -e $file && ! -L $file ]] || fail "missing ${file#"$output/"}"
done

# The archive is what an app downloads: its digest, and the same signed kit.
(cd "$output" && /usr/bin/shasum -a 256 -c TryOmarchyKit.zip.sha256 >/dev/null) || fail "TryOmarchyKit.zip does not match its .sha256"
[[ $(wc -l <"$archive.sha256") -eq 1 ]] || fail "TryOmarchyKit.zip.sha256 must name one file"
ditto -x -k "$archive" "$scratch/unpacked"
[[ $(ls "$scratch/unpacked") == "$kit_name" && -d $scratch/unpacked/$kit_name ]] ||
  fail "the archive does not hold only $kit_name at its top"
diff -rq "$kit" "$scratch/unpacked/$kit_name" >/dev/null || fail "the archive's kit differs from the built kit"
codesign --verify --deep --strict "$scratch/unpacked/$kit_name" || fail "the archive's kit has an invalid signature"
codesign --verify --deep --strict "$kit" || fail "the kit has an invalid signature"
signature_options=()
case ${KIT_NOTARIZED:-} in
  0) signature_options=(--signature-only) ;;
  1) signature_options=(--require-notarization) ;;
  '') ;;
  *) fail "KIT_NOTARIZED must be 0 or 1" ;;
esac
python3 "$root/scripts/kit_signature.py" verify ${signature_options[@]+"${signature_options[@]}"} \
  "$scratch/unpacked/$kit_name" || fail "the archive's kit is not signed as one kit"
"$scratch/unpacked/$kit_name/Contents/Resources/runtime/bin/Try Omarchy" --version >/dev/null ||
  fail "the archive's QEMU does not start with its libraries"

python3 -I -c 'import plistlib, sys; assert plistlib.load(open(sys.argv[1], "rb")) == {
    "CFBundleExecutable": "omarchy-vm-helper", "CFBundlePackageType": "BNDL",
    "LSUIElement": True, "NSHighResolutionCapable": True}' "$contents/Info.plist" ||
  fail "the kit's Info.plist has more than its executable and presentation"
[[ $(codesign -dv "$kit" 2>&1 | sed -n 's/^Identifier=//p') == dev.tryomarchy.kit ]] ||
  fail "the kit is not signed as dev.tryomarchy.kit"

python3 "$root/scripts/kit_manifest.py" --root "$root" --check "$resources/kit.json" >/dev/null || fail "kit.json is invalid"
cmp -s "$resources/kit.json" "$output/TryOmarchyKit.json" || fail "TryOmarchyKit.json differs from the kit's kit.json"

# The kit carries its networking daemon for the embedding app to register
# under its own name, never a job of its own and never the full app's
# service. The daemon pins the runtime beside it.
[[ ! -e $contents/Library && -z $(find "$kit" -path '*LaunchDaemons*' -print -quit) ]] ||
  fail "the kit registers a launch daemon of its own"
[[ $(ls "$contents/MacOS" | tr '\n' ' ') == 'omarchy-network-daemon omarchy-vm-helper ' ]] ||
  fail "the kit's MacOS folder holds more than the helper and the networking daemon"
[[ ! -e $contents/Frameworks ]] || fail "the kit carries frameworks; its embedding app owns updates"
job="$resources/network/launchd.plist"
service=$(/usr/bin/plutil -extract Label raw -o - "$job" 2>/dev/null) || fail "the kit has no networking job"
[[ $service == dev.tryomarchy.kit.network ]] || fail "the kit's networking service is $service"
python3 -I -c 'import plistlib, sys; job = plistlib.load(open(sys.argv[1], "rb"))
assert job["MachServices"] == {job["Label"]: True} and job["BundleProgram"] == "Contents/MacOS/omarchy-network-daemon"' "$job" ||
  fail "the kit's networking job does not name its service and daemon"
[[ $("$contents/MacOS/omarchy-network-daemon" check) == "$service" ]] || fail "the kit's networking daemon rejects its runtime"
grep -aq "$service" "$resources/network/omarchy-network-client" &&
  ! grep -aq 'dev[.]tryomarchy[.]network' "$resources/network/omarchy-network-client" ||
  fail "the kit's networking client does not ask for the kit's service"

for file in runtime/bin/"Try Omarchy" runtime/bin/zstd scripts/run-qemu-gpu.sh firmware/edk2-aarch64-code.fd \
  guest/factory.json guest/download.json guest/packages.txt guest/SHA256SUMS TryOmarchy.icns; do
  [[ -f $resources/$file && ! -L $resources/$file ]] || fail "the kit has no $file"
done
shopt -s nullglob
packages=("$resources"/guest-packages/*)
shopt -u nullglob
((${#packages[@]} == 1)) && [[ ${packages[0]##*/} =~ ^try-omarchy-[0-9][A-Za-z0-9._+-]*-(aarch64|any)\.pkg\.tar\.zst$ ]] ||
  fail "the kit must carry exactly one try-omarchy package"

# A kit downloads its image: the manifest names the factory's image, and the
# image itself is not in the kit.
python3 -I - "$resources/guest" <<'PY' || fail "the kit's download manifest does not describe its factory"
import json, re, sys
from pathlib import Path
from urllib.parse import urlsplit
guest = Path(sys.argv[1])
factory = json.loads((guest / "factory.json").read_text())
download = json.loads((guest / "download.json").read_text())
digest = re.compile(r"[0-9a-f]{64}")
parts = download["parts"]
assert download["format"] == 1 and download["kind"] == "try-omarchy-factory-download"
assert download["identity"] == factory["disk"]["sha256"]
assert download["image"]["sha256"] == factory["compressed"]["sha256"]
assert 1 <= len(parts) <= 64 and sum(part["bytes"] for part in parts) == download["image"]["bytes"]
def allowed(url):
    url = urlsplit(url)
    return url.scheme == "https" or (url.scheme == "http" and url.hostname in ("127.0.0.1", "localhost"))
assert all(allowed(part["url"]) and digest.fullmatch(part["sha256"]) for part in parts)
assert not (guest / factory["compressed"]["path"]).exists()
PY

# The launcher accepts the factory it describes (as build-kit.sh checks).
expected=$(python3 -I -c 'import json, sys; disk = json.load(open(sys.argv[1]))["disk"]; print(disk["sha256"] + "\t" + str(disk["bytes"]))' "$resources/guest/factory.json")
record=$(OMARCHY_QEMU_GPU_INSPECT_ONLY=1 "$resources/scripts/run-qemu-gpu.sh") || fail "the kit's launcher rejects its factory"
[[ $record == "$expected" ]] || fail "the kit's launcher reports $record, not the factory's $expected"

# The kit's own helper speaks the run-mode protocol and refuses what it
# cannot run before it starts anything. Its input stays open, as an app's
# does: the end of input means shut down.
mkdir -p "$scratch/home"
CFFIXED_USER_HOME="$scratch/home" OMARCHY_QEMU_GPU_STATE_ROOT="$scratch/vm" OMARCHY_VM_RUN_TEST_SKIP_PREFLIGHT=1 \
  python3 -I - "$contents/MacOS/omarchy-vm-helper" <<'PY' || fail "the kit's run mode did not refuse what it cannot run"
import json, subprocess, sys
for line, code, status in [
    ('{"version":1}', "invalid-configuration", 64),
    ('{"version":1,"productName":"Kit Check","bridges":[],"network":"bridged"}', "bridged-network-unavailable", 1),
]:
    helper = subprocess.Popen([sys.argv[1], "--run-vm"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL)
    helper.stdin.write(line.encode() + b"\n")
    helper.stdin.flush()
    events = [json.loads(event) for event in helper.stdout]
    helper.stdin.close()
    helper.wait(timeout=30)
    assert [(event["event"], event.get("code")) for event in events] == [("error", code), ("exited", None)], events
    assert events[-1]["status"] == status == helper.returncode, (events, helper.returncode)
PY
[[ ! -e $scratch/vm ]] || fail "a refused run created the VM folder"

echo "kit-check: PASS ($(python3 -I -c 'import json, sys; m = json.load(open(sys.argv[1])); print(m["version"], "protocol", m["runProtocolVersion"])' "$resources/kit.json"))"
