#!/usr/bin/env bash
# Stop llama-swap whether it's running as the systemd unit or a bare process.
#
# Tries (in order):
#   1. Best-effort unload of any currently-loaded upstream model (frees GPU
#      cleanly before the supervisor exits).
#   2. If the systemd unit is active, `systemctl stop llamaswap`.
#   3. Otherwise, SIGTERM any bare ./llama-swap process; SIGKILL if it doesn't
#      exit within a few seconds.
set -euo pipefail

cd "$(dirname "$0")"

PORT="${LLAMA_SWAP_PORT:-8090}"
SERVICE_NAME="llamaswap"

# 1. Tell the supervisor to unload its upstream(s). Ignore failures — the
# server may already be down, or curl may not be installed.
if command -v curl >/dev/null 2>&1; then
    curl -fsS -X POST "http://127.0.0.1:${PORT}/api/unload" >/dev/null 2>&1 || true
fi

# 2. Prefer systemd if the unit is active.
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "Stopping systemd unit: ${SERVICE_NAME}"
    sudo systemctl stop "$SERVICE_NAME"
    echo "Stopped."
    exit 0
fi

# 3. Fall back to killing the bare process.
pids="$(pgrep -f '\./llama-swap --config' || true)"
if [ -z "$pids" ]; then
    echo "No llama-swap process found (and systemd unit is not active)."
    exit 0
fi

echo "Sending SIGTERM to: $pids"
kill $pids
for _ in 1 2 3 4 5; do
    sleep 1
    pgrep -f '\./llama-swap --config' >/dev/null || { echo "Stopped."; exit 0; }
done

echo "Process did not exit after SIGTERM; sending SIGKILL." >&2
kill -9 $pids 2>/dev/null || true
echo "Killed."
