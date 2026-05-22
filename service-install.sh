#!/usr/bin/env bash
# Manage the llama-swap systemd service.
#
# Usage:
#   ./service-install.sh             # show current status
#   ./service-install.sh install     # install + enable + start at boot
#   ./service-install.sh uninstall   # stop + disable + remove unit file
#
# Runs as the user who invoked install (not root) so it inherits CUDA / GPU
# access the same way ./start.sh does interactively.
set -euo pipefail

cd "$(dirname "$0")"
REPO_DIR="$(pwd)"
SERVICE_NAME="llamaswap"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

cmd="${1:-status}"

show_status() {
    if [ ! -f "$UNIT_PATH" ]; then
        echo "service: not installed"
        echo "  unit:    $UNIT_PATH (missing)"
        echo "  install: ./service-install.sh install"
        return 0
    fi
    enabled="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
    active="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
    echo "service: installed"
    echo "  unit:    $UNIT_PATH"
    echo "  enabled: ${enabled:-unknown}"
    echo "  active:  ${active:-unknown}"
    echo
    systemctl --no-pager --lines=5 status "$SERVICE_NAME" 2>&1 || true
}

do_install() {
    [ -x "$REPO_DIR/llama-swap" ] || { echo "llama-swap binary missing; run ./install.sh first" >&2; exit 1; }
    [ -x "$REPO_DIR/bin/llama-server" ] || { echo "bin/llama-server missing; run ./install.sh first" >&2; exit 1; }

    local run_user run_group
    run_user="${SUDO_USER:-$USER}"
    run_group="$(id -gn "$run_user")"

    echo "Writing $UNIT_PATH (User=$run_user, WorkingDirectory=$REPO_DIR)"
    sudo tee "$UNIT_PATH" >/dev/null <<EOF
[Unit]
Description=llama-swap (Jetson LLM endpoint)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${run_user}
Group=${run_group}
WorkingDirectory=${REPO_DIR}
ExecStart=${REPO_DIR}/start.sh
Restart=on-failure
RestartSec=5
# Pass through env if start.sh callers want to override defaults.
# Environment=LLAMA_SWAP_HOST=0.0.0.0
# Environment=LLAMA_SWAP_PORT=8090

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"

    echo
    echo "Installed. Status:"
    show_status
}

do_uninstall() {
    if [ ! -f "$UNIT_PATH" ]; then
        echo "Not installed; nothing to do."
        return 0
    fi
    sudo systemctl disable --now "$SERVICE_NAME" || true
    sudo rm -f "$UNIT_PATH"
    sudo systemctl daemon-reload
    sudo systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
    echo "Uninstalled."
}

case "$cmd" in
    status)    show_status ;;
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *)
        echo "usage: $0 [install|uninstall]   (no arg = status)" >&2
        exit 2
        ;;
esac
