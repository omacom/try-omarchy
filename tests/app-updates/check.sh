#!/bin/bash
#
# Checks the updater a built app carries (docs/app-updates.md): Sparkle with
# its license and without its XPC services, linked weakly so the kit's helper
# runs without it, and signed by the same team as the app. Starts nothing.
#
#   tests/app-updates/check.sh APP

set -euo pipefail

fail() {
  echo "app-updates-check: $*" >&2
  exit 1
}
(($# == 1)) && [[ -d $1 ]] || fail "usage: tests/app-updates/check.sh APP"
app=$(cd "$1" && pwd -P)
sparkle="$app/Contents/Frameworks/Sparkle.framework"
current="$sparkle/Versions/B"
helper="$app/Contents/MacOS/omarchy-vm-helper"
root=$(cd "$(dirname "$0")/../.." && pwd -P)

[[ -d $sparkle && ! -L $sparkle ]] || fail "the app has no Sparkle.framework"
version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$sparkle/Resources/Info.plist")
pinned=$(/usr/bin/plutil -extract pins.0.state.version raw -o - "$root/macos/Package.resolved")
[[ $version == "$pinned" ]] || fail "the app has Sparkle $version, not the pinned $pinned"
[[ -s $sparkle/Resources/LICENSE ]] || fail "Sparkle has no license"
[[ -z $(find "$sparkle" -name '*.xpc' -o -name XPCServices) ]] || fail "Sparkle has XPC services"

loads=$(otool -l "$helper")
[[ $(awk '$1 == "cmd" { command = $2 } $1 == "name" && /Sparkle[.]framework/ { print command }' <<<"$loads") == LC_LOAD_WEAK_DYLIB ]] || fail "the helper does not link Sparkle weakly"
[[ $loads == *'path @executable_path/../Frameworks '* ]] || fail "the helper does not look for frameworks in the app"

team() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
for part in "$current/Autoupdate" "$current/Updater.app" "$sparkle"; do
  codesign --verify --strict "$part" || fail "${part##*/} has an invalid signature"
  [[ $(team "$part") == "$(team "$app")" ]] || fail "${part##*/} is signed by another team than the app"
done

echo "app-updates-check: PASS (Sparkle $version)"
