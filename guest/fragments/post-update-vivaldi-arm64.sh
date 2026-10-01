#!/bin/bash

# Refresh signed ARM64 Vivaldi through the local [try-omarchy] repository when
# the user has already installed it. Newer stables are authenticated with the
# pinned Vivaldi package key; see install-vivaldi-arm64 --follow-stable.
set -euo pipefail

pacman -Q vivaldi >/dev/null 2>&1 || exit 0

echo -e "\e[32m\nUpdate Vivaldi\e[0m"
/usr/local/lib/try-omarchy/install-vivaldi-arm64 --follow-stable
