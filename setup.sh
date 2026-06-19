#!/bin/bash
# WStunnel + Caddy — Unified Setup Script
# Supports both Iran VPS (server) and Foreign VPS (client).

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

# ─────────────────────────────────────────────
# Input helpers
# ─────────────────────────────────────────────
ask() {
    # ask <varname> <prompt> [default]
    local varname="$1"
    local prompt="$2"
    local default="${3:-}"
    local value

    if [ -n "$default" ]; then
        read -rp "$(echo -e "  ${BOLD}${prompt}${RESET} [${YELLOW}${default}${RESET}]: ")" value
        value="${value:-$default}"
    else
        while true; do
            read -rp "$(echo -e "  ${BOLD}${prompt}${RESET}: ")" value
            [ -n "$value" ] && break
            warn "  This field is required."
        done
    fi

    printf -v "$varname" '%s' "$value"
}

confirm() {
    local answer
    read -rp "$(echo -e "${BOLD}${1:-Continue?} [y/N]${RESET}: ")" answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

pick_mode() {
    local varname="$1"
    local choice

    echo -e "  ${CYAN}1${RESET}) Iran VPS    — receives tunnel connections via Caddy  ${BOLD}(server)${RESET}"
    echo -e "  ${CYAN}2${RESET}) Foreign VPS — connects outbound to Iran VPS          ${BOLD}(client)${RESET}"
    echo ""

    while true; do
        read -rp "$(echo -e "  ${BOLD}Enter 1 or 2${RESET}: ")" choice
        case "$choice" in
            1) printf -v "$varname" 'server'; return ;;
            2) printf -v "$varname" 'client'; return ;;
            *) warn "  Please enter 1 or 2." ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Shared steps
# ─────────────────────────────────────────────
check_root() {
    [ "$EUID" -eq 0 ] || error "Run as root: sudo bash setup.sh"
}

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

setup_user() {
    if id "wstunnel" &>/dev/null; then
        info "User 'wstunnel' already exists, skipping."
    else
        useradd -r -s /bin/false wstunnel
        success "User 'wstunnel' created."
    fi
    mkdir -p /home/wstunnel
    chown wstunnel:wstunnel /home/wstunnel
    success "Directory /home/wstunnel ready."
}

# ─────────────────────────────────────────────
# Server flow (Iran VPS)
# ─────────────────────────────────────────────
flow_server() {
    echo ""
    echo -e "${BOLD}─── wstunnel ──────────────────────────────────────────${RESET}"
    ask WSTUNNEL_VERSION "wstunnel version to install" "10.5.5"
    ask SERVER_BIND_IP   "Bind IP for wstunnel server (keep 127.0.0.1 so only Caddy can reach it)" "127.0.0.1"
    ask SERVER_PORT      "Port wstunnel server listens on (must match Caddy reverse_proxy)" "2018"

    echo ""
    echo -e "${BOLD}─── Caddy / Domain ────────────────────────────────────${RESET}"
    ask DOMAIN "Tunnel subdomain pointing to this Iran VPS (e.g. tunnel.example.com)" ""

    # Summary
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━  Summary  ━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Mode             :  ${GREEN}Iran VPS — Server${RESET}"
    echo -e "  wstunnel version :  ${YELLOW}${WSTUNNEL_VERSION}${RESET}"
    echo -e "  Server listens   :  ${YELLOW}ws://${SERVER_BIND_IP}:${SERVER_PORT}${RESET}"
    echo -e "  Caddy domain     :  ${YELLOW}${DOMAIN}${RESET}"
    echo -e "  Caddy proxies    :  ${CYAN}${DOMAIN} → localhost:${SERVER_PORT}${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    confirm "Proceed with server installation?" || { info "Aborted."; exit 0; }
    echo ""

    install_wstunnel "$WSTUNNEL_VERSION"
    setup_user

    info "Writing /etc/systemd/system/wstunnel-server.service ..."
    cat > /etc/systemd/system/wstunnel-server.service <<EOF
[Unit]
Description=WStunnel Server
After=network.target

[Service]
Type=simple
User=wstunnel
Group=wstunnel
WorkingDirectory=/home/wstunnel
ExecStart=/usr/local/bin/wstunnel server ws://${SERVER_BIND_IP}:${SERVER_PORT}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable  wstunnel-server.service
    systemctl restart wstunnel-server.service

    echo ""
    systemctl status wstunnel-server.service --no-pager
    echo ""

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${YELLOW}ACTION REQUIRED — Add this block to your Caddyfile:${RESET}"
    echo ""
    echo -e "${CYAN}${DOMAIN} {${RESET}"
    echo -e "${CYAN}    reverse_proxy localhost:${SERVER_PORT}${RESET}"
    echo -e "${CYAN}}${RESET}"
    echo ""
    echo -e "Then reload Caddy:  ${CYAN}sudo systemctl reload caddy${RESET}"
    echo -e "View logs:          ${CYAN}sudo journalctl -u wstunnel-server.service -f${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    success "Iran VPS (server) setup complete."
}

# ─────────────────────────────────────────────
# Client flow (Foreign VPS)
# ─────────────────────────────────────────────
flow_client() {
    echo ""
    echo -e "${BOLD}─── wstunnel ──────────────────────────────────────────${RESET}"
    ask WSTUNNEL_VERSION "wstunnel version to install" "10.5.5"

    echo ""
    echo -e "${BOLD}─── Iran VPS connection ───────────────────────────────${RESET}"
    ask IRAN_DOMAIN   "Tunnel domain on Iran VPS (e.g. tunnel.example.com)" ""
    ask IRAN_WSS_PORT "HTTPS/WSS port on Iran VPS (Caddy listens here)" "443"

    echo ""
    echo -e "${BOLD}─── Port forwarding on this Foreign VPS ───────────────${RESET}"
    echo -e "  Traffic on ${YELLOW}LISTEN_IP:EXPOSE_PORT${RESET} will be forwarded through"
    echo -e "  the tunnel to ${YELLOW}TARGET_HOST:TARGET_PORT${RESET} on the Iran VPS side."
    echo ""
    ask LISTEN_IP   "IP to expose tunnel on (0.0.0.0 = all interfaces, 127.0.0.1 = local only)" "0.0.0.0"
    ask EXPOSE_PORT "Port to expose on this Foreign VPS" "8443"
    ask TARGET_HOST "Target host on Iran VPS side" "localhost"
    ask TARGET_PORT "Target port on Iran VPS side" "8443"

    # Summary
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━  Summary  ━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Mode             :  ${GREEN}Foreign VPS — Client${RESET}"
    echo -e "  wstunnel version :  ${YELLOW}${WSTUNNEL_VERSION}${RESET}"
    echo -e ""
    echo -e "  Connect to Iran  :  ${YELLOW}wss://${IRAN_DOMAIN}:${IRAN_WSS_PORT}${RESET}"
    echo -e ""
    echo -e "  Traffic flow:"
    echo -e "    ${CYAN}${LISTEN_IP}:${EXPOSE_PORT}${RESET}  (this Foreign VPS)"
    echo -e "         ↓  WSS tunnel through Caddy on Iran VPS"
    echo -e "    ${CYAN}${TARGET_HOST}:${TARGET_PORT}${RESET}  (Iran VPS side)"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    confirm "Proceed with client installation?" || { info "Aborted."; exit 0; }
    echo ""

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
    systemctl enable  wstunnel-client.service
    systemctl restart wstunnel-client.service

    echo ""
    systemctl status wstunnel-client.service --no-pager
    echo ""

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "Verify tunnel is active:"
    echo -e "  ${CYAN}ss -tlnp | grep ${EXPOSE_PORT}${RESET}"
    echo -e ""
    echo -e "Test connectivity:"
    echo -e "  ${CYAN}curl -k https://localhost:${EXPOSE_PORT}${RESET}"
    echo -e ""
    echo -e "View logs:"
    echo -e "  ${CYAN}sudo journalctl -u wstunnel-client.service -f${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    success "Foreign VPS (client) setup complete."
}

# ─────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────
main() {
    clear
    echo ""
    echo -e "${BOLD}╔═════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║         WStunnel + Caddy — Interactive Setup        ║${RESET}"
    echo -e "${BOLD}╚═════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  Quick install (run on any VPS):"
    echo -e "  ${CYAN}bash <(curl -fsSL https://raw.githubusercontent.com/Samr002/black-box/main/setup.sh)${RESET}"
    echo ""

    check_root

    echo -e "${BOLD}Which server are you setting up?${RESET}"
    echo ""
    pick_mode MODE

    case "$MODE" in
        server) flow_server ;;
        client) flow_client ;;
    esac
}

main "$@"
