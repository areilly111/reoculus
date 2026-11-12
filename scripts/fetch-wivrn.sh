#!/bin/sh
# Fetch the WiVRn 26.9 server Flatpak bundle shipped inside the AppImage.
# The bundle is an upstream binary (GPLv3, see CREDITS.md) and is NOT
# stored in git; run this before packaging an AppImage.
set -eu
cd "$(dirname "$0")/.."
mkdir -p vendor
URL="https://github.com/WiVRn/WiVRn/releases/download/v26.9/wivrn-server.flatpak"
if [ -s vendor/wivrn-server.flatpak ]; then
  echo "vendor/wivrn-server.flatpak already present, skipping download."
  exit 0
fi
curl -fL -o vendor/wivrn-server.flatpak "$URL"
echo "Downloaded vendor/wivrn-server.flatpak ($(du -h vendor/wivrn-server.flatpak | cut -f1))."
