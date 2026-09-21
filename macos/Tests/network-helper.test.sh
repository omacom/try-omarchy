#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../network-helper" && pwd -P)
output=$(mktemp -d /private/tmp/omarchy-network-unit.XXXXXX)
trap 'rm -rf "$output"' EXIT
bash "$root/build.sh" "$output"
/usr/bin/clang -Wall -Wextra -Werror -Wno-deprecated-declarations "$root/payload-check.test.c" -o "$output/payload-check-test"
"$output/payload-check-test"
/usr/bin/clang -Wall -Wextra -Werror -mmacosx-version-min=15.0 "$root/stream.test.c" -o "$output/stream-test"
mkdir -p "$output/Contents/Resources/network" "$output/Contents/MacOS"
cp "$output/socket_vmnet" "$output/omarchy-network-supervisor" "$output/omarchy-network-client" "$output/Contents/Resources/network/"
codesign --force --sign - "$output/Contents/Resources/network/omarchy-network-client"
bash "$root/build-daemon.sh" "$output/Contents"
if "$output/Contents/MacOS/omarchy-network-daemon"; then
  echo 'network-helper.test: daemon accepted an unprivileged launch' >&2
  exit 1
fi
"$output/stream-test"
/usr/bin/clang -Wall -Wextra -Werror -mmacosx-version-min=15.0 -DVERSION='"test"' \
  -framework vmnet "$root/recovery.test.c" "$root/vendor/cli.c" -o "$output/recovery-test"
"$output/recovery-test"
if "$output/omarchy-network-supervisor" run; then
  echo 'network-helper.test: invalid invocation accepted' >&2
  exit 1
fi
echo 'network-helper.test: PASS'
