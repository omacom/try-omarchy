#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd -P)
out=${1:?output directory required}
service=${OMARCHY_NETWORK_SERVICE_NAME:-dev.tryomarchy.network}
[[ $service =~ ^[A-Za-z0-9]+([.][A-Za-z0-9-]+)+$ ]] || { echo "Invalid networking service name" >&2; exit 1; }
mkdir -p "$out"
/usr/bin/clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=15.0 \
  -DVERSION='"v1.2.2"' -framework vmnet \
  "$root/vendor/main.c" "$root/vendor/cli.c" -o "$out/socket_vmnet"
/usr/bin/clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=15.0 \
  -framework vmnet "$root/supervisor.c" -o "$out/omarchy-network-supervisor"

/usr/bin/clang -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations -fblocks -mmacosx-version-min=15.0 \
  -DNETWORK_SERVICE_NAME=\""$service"\" "$root/client.c" -o "$out/omarchy-network-client"
