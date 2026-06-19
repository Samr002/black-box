#!/bin/bash
# WStunnel + Caddy — Iran VPS (Server) Setup
# Run on the Iran VPS that has Caddy installed.

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
    [ "$EUID" -eq 0 ] || error "Run as root: sudo bash setup-server.sh"
}

check_caddy() {
    if ! command -v caddy &>/dev/null && ! systemctl list-units --full -q 2>/dev/null | grep -q caddy; then
        warn "Caddy does not seem to be installed on this machine."
        warn "This script configures wstunnel only. Install Caddy first, then update your Caddyfile."
    fi
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
    echo -e "${BOLD}║      WStunnel Setup — Iran VPS (Server)       ║${RESET}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  This script installs wstunnel in ${GREEN}server mode${RESET} on your"
    echo -e "  Iran VPS and prints the Caddy block you need to add."
    echo ""

    check_root
    check_caddy

    # ── Collect inputs ──────────────────────────────
    echo -e "${BOLD}─── wstunnel ──────────────────────────────────────${RESET}"
    ask WSTUNNEL_VERSION "wstunnel version to install" "10.5.5"
    ask SERVER_BIND_IP   "IP that wstunnel server binds to (keep 127.0.0.1 so only Caddy can reach it)" "127.0.0.1"
    ask SERVER_PORT      "Port wstunnel server listens on (must match Caddy reverse_proxy port)" "2018"

    echo ""
    echo -e "${BOLD}─── Caddy / Domain ────────────────────────────────${RESET}"
    ask DOMAIN "Tunnel subdomain pointing to this Iran VPS (e.g. tunnel.example.com)" ""

    # ── Summary ────────────────────────────────────
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━  Summary  ━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  wstunnel version : ${YELLOW}${WSTUNNEL_VERSION}${RESET}"
    echo -e "  Server listens   : ${YELLOW}ws://${SERVER_BIND_IP}:${SERVER_PORT}${RESET}"
    echo -e "  Caddy domain     : ${YELLOW}${DOMAIN}${RESET}"
    echo -e "  Caddy will proxy : ${CYAN}${DOMAIN} → localhost:${SERVER_PORT}${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    confirm "Proceed with installation?" || { info "Aborted."; exit 0; }

    # ── Install ────────────────────────────────────
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
    systemctl enable wstunnel-server.service
    systemctl restart wstunnel-server.service

    echo ""
    systemctl status wstunnel-server.service --no-pager
    echo ""

    # ── Post-install instructions ──────────────────
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${YELLOW}ACTION REQUIRED — Add this block to your Caddyfile:${RESET}"
    echo ""
    echo -e "${CYAN}${DOMAIN} {${RESET}"
    echo -e "${CYAN}    reverse_proxy localhost:${SERVER_PORT}${RESET}"
    echo -e "${CYAN}}${RESET}"
    echo ""
    echo -e "Then reload Caddy:"
    echo -e "  ${CYAN}sudo systemctl reload caddy${RESET}"
    echo ""
    echo -e "View logs:"
    echo -e "  ${CYAN}sudo journalctl -u wstunnel-server.service -f${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    success "Iran VPS (server) setup complete."
}

main "$@"
