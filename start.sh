#!/usr/bin/env bash
# Launch llama-swap with our config. Listens on :8090 by default.
#
# Env vars:
#   LLAMA_SWAP_PORT  - HTTP port (default 8090)
#   LLAMA_SWAP_HOST  - bind address (default 127.0.0.1; use 0.0.0.0 for LAN)
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -x ./llama-swap ]; then
    echo "llama-swap binary not found. Run ./install.sh first." >&2
    exit 1
fi

PORT="${LLAMA_SWAP_PORT:-8090}"
HOST="${LLAMA_SWAP_HOST:-127.0.0.1}"

# llama-server is built into ./bin by install.sh.
LLS=./bin/llama-server
[ -x "$LLS" ] || {
    echo "llama-server not found at $LLS" >&2
    echo "Run ./install.sh first to build it." >&2
    exit 1
}

echo "Starting llama-swap on http://${HOST}:${PORT}"
echo "  config:  $(pwd)/config.yaml"
echo "  upstream: $LLS"
echo "  UI:      http://${HOST}:${PORT}/ui/"
echo "  logs:    http://${HOST}:${PORT}/logs/stream"
echo

exec ./llama-swap --config config.yaml --listen "${HOST}:${PORT}"
