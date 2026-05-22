#!/usr/bin/env bash
# Install llama-swap binary for Jetson AGX Xavier (linux/arm64).
#
# Pins to a specific version so this is reproducible. Bump VERSION below
# to upgrade and re-run.
set -euo pipefail

cd "$(dirname "$0")"

VERSION="216"
ASSET="llama-swap_${VERSION}_linux_arm64.tar.gz"
URL="https://github.com/mostlygeek/llama-swap/releases/download/v${VERSION}/${ASSET}"

if [ -x ./llama-swap ]; then
    echo "llama-swap already installed:"
    ./llama-swap --version || ./llama-swap -version || true
    echo
    echo "Re-running install: will overwrite ./llama-swap with v${VERSION}."
    read -rp "Continue? [y/N] " yn
    [[ "${yn,,}" == "y" ]] || exit 0
fi

echo "Downloading $URL"
curl -fL "$URL" -o "/tmp/${ASSET}"

echo "Extracting..."
tar -xzf "/tmp/${ASSET}" -C /tmp llama-swap
mv /tmp/llama-swap ./llama-swap
chmod +x ./llama-swap

rm -f "/tmp/${ASSET}"

echo
echo "Installed:"
./llama-swap --version 2>/dev/null || ./llama-swap -version 2>/dev/null || echo "  (run with -h to inspect)"
echo
echo "Next: ./start.sh"
