#!/bin/bash
# WStunnel — Foreign VPS (Client) Setup
# Run on the Foreign VPS that connects outbound to the Iran VPS.

set -euo pipefail

# ─────────────────────────────────────────────
# Colors
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }

ask() {
    local varname="$1"
    local prompt="$2"
    local default="$3"
    local value

    if [ -n "$default" ]; then
        read -rp "$(echo -e "${BOLD}${prompt}${RESET} [${YELLOW}${default}${RESET}]: ")" value
        value="${value:-$default}"
    else
        while true; do
            read -rp "$(echo -e "${BOLD}${prompt}${RESET}: ")" value
            [ -n "$value" ] && break
            warn "This field is required."
        done
    fi

    printf -v "$varname" '%s' "$value"
}

confirm() {
    local prompt="${1:-Are you sure?}"
    local answer
    read -rp "$(echo -e "${BOLD}${prompt} [y/N]${RESET}: ")" answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ─────────────────────────────────────────────
# Checks
# ─────────────────────────────────────────────
check_root() {
    [ "$EUID" -eq 0 ] || error "Run as root: sudo bash setup-client.sh"
}

# ─────────────────────────────────────────────
# Install wstunnel
# ─────────────────────────────────────────────
install_wstunnel() {
    local version="$1"
    local arch

    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *)        error "Unsupported architecture: $arch" ;;
    esac

    local tarball="wstunnel_${version}_linux_${arch}.tar.gz"
    local url="https://github.com/erebe/wstunnel/releases/download/v${version}/${tarball}"

    info "Downloading wstunnel v${version} (${arch})..."
    cd /tmp
    wget -q --show-progress "$url" -O "$tarball" || error "Download failed: $url"
    tar xzf "$tarball"
    mv -f wstunnel /usr/local/bin/wstunnel
    chmod +x /usr/local/bin/wstunnel
    rm -f "$tarball"

    success "wstunnel installed: $(wstunnel --version 2>&1 | head -n1)"
}

# ─────────────────────────────────────────────
# Setup system user
# ─────────────────────────────────────────────
setup_user() {
    if id "wstunnel" &>/dev/null; then
        info "User 'wstunnel' already exists, skipping."
    else
        useradd -r -s /bin/false wstunnel
        success "User 'wstunnel' created."
    fi
    mkdir -p /home/wstunnel
    chown wstunnel:wstunnel /home/wstunnel
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
main() {
    clear
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║    WStunnel Setup — Foreign VPS (Client)      ║${RESET}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  This script installs wstunnel in ${GREEN}client mode${RESET} on your"
    echo -e "  Foreign VPS and connects it to the Iran VPS via WSS."
    echo ""

    check_root

    # ── Collect inputs ──────────────────────────────
    echo -e "${BOLD}─── wstunnel ──────────────────────────────────────${RESET}"
    ask WSTUNNEL_VERSION "wstunnel version to install" "10.5.5"

    echo ""
    echo -e "${BOLD}─── Iran VPS connection ───────────────────────────${RESET}"
    ask IRAN_DOMAIN "Tunnel domain on Iran VPS (e.g. tunnel.example.com)" ""
    ask IRAN_WSS_PORT "WSS port on Iran VPS (Caddy HTTPS port)" "443"

    echo ""
    echo -e "${BOLD}─── Port forwarding on this Foreign VPS ───────────${RESET}"
    echo -e "  Traffic arriving at ${YELLOW}LISTEN_IP:EXPOSE_PORT${RESET} will be forwarded"
    echo -e "  through the tunnel to ${YELLOW}TARGET_HOST:TARGET_PORT${RESET} on the Iran VPS."
    echo ""
    ask LISTEN_IP   "IP to listen on (0.0.0.0 = all interfaces, 127.0.0.1 = local only)" "0.0.0.0"
    ask EXPOSE_PORT "Port to expose on this Foreign VPS" "8443"
    ask TARGET_HOST "Target host on Iran VPS side (usually localhost)" "localhost"
    ask TARGET_PORT "Target port on Iran VPS side" "8443"

    # ── Summary ────────────────────────────────────
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━  Summary  ━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  wstunnel version : ${YELLOW}${WSTUNNEL_VERSION}${RESET}"
    echo -e ""
    echo -e "  Connect to Iran  : ${YELLOW}wss://${IRAN_DOMAIN}:${IRAN_WSS_PORT}${RESET}"
    echo -e ""
    echo -e "  Traffic flow:"
    echo -e "    Foreign VPS ${CYAN}${LISTEN_IP}:${EXPOSE_PORT}${RESET}"
    echo -e "        ↓  (WSS tunnel through Caddy on Iran VPS)"
    echo -e "    Iran VPS    ${CYAN}${TARGET_HOST}:${TARGET_PORT}${RESET}"
    echo -e ""
    echo -e "  ExecStart:"
    echo -e "    ${CYAN}/usr/local/bin/wstunnel client \\${RESET}"
    echo -e "      ${CYAN}-R tcp://${LISTEN_IP}:${EXPOSE_PORT}:${TARGET_HOST}:${TARGET_PORT} \\${RESET}"
    echo -e "      ${CYAN}wss://${IRAN_DOMAIN}:${IRAN_WSS_PORT}${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    confirm "Proceed with installation?" || { info "Aborted."; exit 0; }

    # ── Install ────────────────────────────────────
    install_wstunnel "$WSTUNNEL_VERSION"
    setup_user

    info "Writing /etc/systemd/system/wstunnel-client.service ..."
    cat > /etc/systemd/system/wstunnel-client.service <<EOF
[Unit]
Description=WStunnel Client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=wstunnel
Group=wstunnel
WorkingDirectory=/home/wstunnel
ExecStart=/usr/local/bin/wstunnel client -R tcp://${LISTEN_IP}:${EXPOSE_PORT}:${TARGET_HOST}:${TARGET_PORT} wss://${IRAN_DOMAIN}:${IRAN_WSS_PORT}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wstunnel-client.service
    systemctl restart wstunnel-client.service

    echo ""
    systemctl status wstunnel-client.service --no-pager
    echo ""

    # ── Post-install verification ──────────────────
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "Verify tunnel is active:"
    echo -e "  ${CYAN}ss -tlnp | grep ${EXPOSE_PORT}${RESET}"
    echo -e ""
    echo -e "Test connectivity:"
    echo -e "  ${CYAN}curl -k https://localhost:${EXPOSE_PORT}${RESET}"
    echo -e ""
    echo -e "View logs:"
    echo -e "  ${CYAN}sudo journalctl -u wstunnel-client.service -f${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    success "Foreign VPS (client) setup complete."
}

main "$@"
