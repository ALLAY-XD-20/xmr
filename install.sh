#!/bin/bash
# ================================================================
# XMR Mining Manager
# Commands:
#   install | update | start | stop | restart | status | logs
#   balance | setup
# ================================================================

set -e

# -------------------- Configuration --------------------

WALLET_ADDRESS="4BA3H4JyDWpWtKDCHT1mZKjhwSRpid9XTDj8YwSuGbkvBZ6maroonoR6U4yq6YZtyxGM9to6piVFLLH5HuNvpUihAvgCyzR"

POOL_ADDRESS="xmr-eu1.nanopool.org:14444"
# Other regions:
# xmr-us-east1.nanopool.org:14444
# xmr-asia1.nanopool.org:14444

WORKER_NAME="worker-$(hostname)"
THREADS="$(nproc)"
XMRIG_VERSION="6.20.0"

INSTALL_DIR="$HOME/xmr-mining"
BIN="$INSTALL_DIR/xmrig"
LOG_FILE="$INSTALL_DIR/mining.log"

SERVICE_NAME="xmrig-miner"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# -------------------- Colors --------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok() {
    echo -e "${GREEN}[✓]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

err() {
    echo -e "${RED}[✗]${NC} $1"
}

# -------------------- Install XMRig --------------------

install_xmrig() {
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    if [ -f "$BIN" ]; then
        ok "XMRig already installed at $BIN"
        return
    fi

    warn "Downloading XMRig v${XMRIG_VERSION}..."

    URLS=(
        "https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VERSION}/xmrig-${XMRIG_VERSION}-linux-static-x64.tar.gz"
        "https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VERSION}/xmrig-${XMRIG_VERSION}-linux-x64.tar.gz"
        "https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VERSION}/xmrig-${XMRIG_VERSION}-xenial-x64.tar.gz"
    )

    for URL in "${URLS[@]}"; do
        echo "  Trying: $URL"

        if curl -L -f -s "$URL" -o xmrig.tar.gz && [ -s xmrig.tar.gz ]; then

            tar -xzf xmrig.tar.gz 2>/dev/null || true

            if [ ! -f xmrig ] && ls xmrig-* >/dev/null 2>&1; then
                mv xmrig-*/* . 2>/dev/null || true
                rm -rf xmrig-*
            fi

            rm -f xmrig.tar.gz

            if [ -f xmrig ]; then
                chmod +x xmrig
                ok "XMRig installed successfully"
                return
            fi
        fi

        rm -f xmrig.tar.gz
    done

    err "Automatic XMRig download failed."
    echo "Download manually from:"
    echo "https://github.com/xmrig/xmrig/releases"
    exit 1
}

# -------------------- Update XMRig --------------------

update_xmrig() {
    warn "Removing old XMRig binary..."
    rm -f "$BIN"

    install_xmrig
}

# -------------------- MSR Optimization --------------------

try_msr_fix() {
    if [ "$EUID" -ne 0 ]; then
        return
    fi

    if ! lsmod | grep -q "^msr"; then
        if modprobe msr 2>/dev/null; then
            ok "Loaded msr kernel module"
        else
            warn "Could not load msr module"
            warn "This is normal on many VPS/VM systems"
        fi
    fi
}

# -------------------- Write Configuration --------------------

write_config() {
    mkdir -p "$INSTALL_DIR"

    cat > "$INSTALL_DIR/config.json" <<EOF
{
    "autosave": true,
    "cpu": true,
    "opencl": false,
    "cuda": false,
    "donate-level": 1,
    "pools": [
        {
            "algo": "rx/0",
            "url": "${POOL_ADDRESS}",
            "user": "${WALLET_ADDRESS}",
            "pass": "${WORKER_NAME}",
            "keepalive": true,
            "tls": false
        }
    ]
}
EOF

    ok "Config written to $INSTALL_DIR/config.json"
    ok "Pool: $POOL_ADDRESS"
    ok "Worker: $WORKER_NAME"
    ok "Threads: $THREADS"
}

# -------------------- Systemd Service --------------------

setup_service() {
    if [ "$EUID" -ne 0 ]; then
        warn "Not running as root"
        warn "Skipping systemd service"
        return 1
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemd is not available"
        warn "Using background mode instead"
        return 1
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=XMRig Miner
After=network.target

[Service]
Type=simple
ExecStart=${BIN} -c ${INSTALL_DIR}/config.json -t ${THREADS} -l ${LOG_FILE}
Restart=always
RestartSec=10
Nice=10
WorkingDirectory=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1

    ok "Systemd service installed"
    ok "Mining will auto-start after reboot"

    return 0
}

# -------------------- Start Mining --------------------

start_mining() {
    if [ ! -f "$BIN" ]; then
        err "XMRig is not installed."
        echo "Run: $0 install"
        exit 1
    fi

    if [ ! -f "$INSTALL_DIR/config.json" ]; then
        write_config
    fi

    try_msr_fix

    if setup_service; then

        systemctl restart "$SERVICE_NAME"

        sleep 2

        if systemctl is-active --quiet "$SERVICE_NAME"; then
            ok "Mining started via systemd"
        else
            err "Service failed to start"
            echo
            echo "Check logs with:"
            echo "journalctl -u $SERVICE_NAME -n 50"
            exit 1
        fi

    else

        if pgrep -f "$BIN" >/dev/null 2>&1; then
            warn "XMRig is already running"
            return
        fi

        cd "$INSTALL_DIR"

        nohup "$BIN" \
            -c config.json \
            -t "$THREADS" \
            -l "$LOG_FILE" \
            >/dev/null 2>&1 &

        disown

        sleep 2

        if pgrep -f "$BIN" >/dev/null 2>&1; then
            PID="$(pgrep -f "$BIN" | head -1)"
            ok "Mining started in background"
            ok "PID: $PID"
        else
            err "Failed to start XMRig"
            echo "Check: $LOG_FILE"
            exit 1
        fi
    fi
}

# -------------------- Stop Mining --------------------

stop_mining() {
    if command -v systemctl >/dev/null 2>&1 &&
       systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    fi

    pkill -f "$BIN" 2>/dev/null || true

    ok "Mining stopped"
}

# -------------------- Status --------------------

status_mining() {
    if command -v systemctl >/dev/null 2>&1 &&
       systemctl list-unit-files | grep -q "$SERVICE_NAME"; then

        systemctl status "$SERVICE_NAME" --no-pager -l | head -15

    elif pgrep -f "$BIN" >/dev/null 2>&1; then

        PID="$(pgrep -f "$BIN" | head -1)"
        ok "XMRig is running"
        echo "PID: $PID"

    else

        warn "XMRig is not running"

    fi
}

# -------------------- Logs --------------------

show_logs() {
    if command -v systemctl >/dev/null 2>&1 &&
       systemctl list-unit-files | grep -q "$SERVICE_NAME"; then

        journalctl -u "$SERVICE_NAME" -f

    else

        if [ -f "$LOG_FILE" ]; then
            tail -f "$LOG_FILE"
        else
            warn "Log file does not exist yet:"
            echo "$LOG_FILE"
        fi

    fi
}

# -------------------- Balance --------------------

check_balance() {
    warn "Checking Nanopool account..."

    EXISTS="$(
        curl -s \
        "https://api.nanopool.org/v1/xmr/accountexist/${WALLET_ADDRESS}"
    )"

    echo "Account exists:"
    echo "$EXISTS"
    echo

    INFO="$(
        curl -s \
        "https://api.nanopool.org/v1/xmr/user/${WALLET_ADDRESS}"
    )"

    if command -v python3 >/dev/null 2>&1; then
        echo "$INFO" | python3 -m json.tool
    else
        echo "$INFO"
    fi

    echo

    warn "If worker is empty or hashrate is 0,"
    warn "no valid shares may have been accepted yet."
}

# -------------------- Command Handler --------------------

case "${1:-}" in

    install)
        install_xmrig
        write_config
        ;;

    update)
        update_xmrig
        ;;

    start)
        start_mining
        ;;

    stop)
        stop_mining
        ;;

    restart)
        stop_mining
        sleep 1
        start_mining
        ;;

    status)
        status_mining
        ;;

    logs)
        show_logs
        ;;

    balance)
        check_balance
        ;;

    setup)
        install_xmrig
        write_config
        start_mining
        ;;

    *)
        echo
        echo "XMR Mining Manager"
        echo
        echo "Usage:"
        echo "  $0 install"
        echo "  $0 update"
        echo "  $0 start"
        echo "  $0 stop"
        echo "  $0 restart"
        echo "  $0 status"
        echo "  $0 logs"
        echo "  $0 balance"
        echo "  $0 setup"
        echo
        exit 1
        ;;

esac
