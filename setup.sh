#!/bin/bash
# WStunnel + Caddy — Unified Setup Script
# Traffic flow (-R reverse tunnel):
#   User → Iran VPS:PORT → WSS tunnel → Foreign VPS:PORT (service lives here)

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
# Global state (populated by parse_* functions)
# ─────────────────────────────────────────────
PARSED_DOMAIN=""
PARSED_WSS_PORT=""
declare -a PARSED_FLAGS=()
PARSED_BIND_IP=""
PARSED_BIND_PORT=""

# ─────────────────────────────────────────────
# Input helpers
# ─────────────────────────────────────────────
ask() {
    local varname="$1" prompt="$2" default="${3:-}" value
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

pick_action() {
    local varname="$1" choice
    echo -e "  ${CYAN}1${RESET}) ${BOLD}Install${RESET}   — Iran VPS     (wstunnel server + Caddy entry point)"
    echo -e "  ${CYAN}2${RESET}) ${BOLD}Install${RESET}   — Foreign VPS  (wstunnel client, hosts the actual service)"
    echo -e "  ${CYAN}3${RESET}) ${BOLD}Edit${RESET}      — manage ports and domain on this machine"
    echo -e "  ${CYAN}4${RESET}) ${BOLD}Update${RESET}    — upgrade wstunnel binary to a newer version"
    echo -e "  ${CYAN}5${RESET}) ${BOLD}Uninstall${RESET} — remove wstunnel completely from this machine"
    echo ""
    while true; do
        read -rp "$(echo -e "  ${BOLD}Enter 1-5${RESET}: ")" choice
        case "$choice" in
            1) printf -v "$varname" 'server';    return ;;
            2) printf -v "$varname" 'client';    return ;;
            3) printf -v "$varname" 'edit';      return ;;
            4) printf -v "$varname" 'update';    return ;;
            5) printf -v "$varname" 'uninstall'; return ;;
            *) warn "  Please enter a number between 1 and 5." ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Shared helpers
# ─────────────────────────────────────────────
check_root() {
    [ "$EUID" -eq 0 ] || error "Run as root: sudo bash setup.sh"
}

detect_services() {
    local -n _out=$1
    _out=()
    for svc in wstunnel-server.service wstunnel-client.service; do
        [ -f "/etc/systemd/system/${svc}" ] && _out+=("$svc")
    done
}

install_wstunnel_binary() {
    local version="$1" arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) error "Unsupported architecture: $arch" ;;
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
# Parse helpers
# ─────────────────────────────────────────────
parse_client_service() {
    local svc_file="/etc/systemd/system/wstunnel-client.service"
    [ -f "$svc_file" ] || error "Client service not found: $svc_file"
    local exec_line
    exec_line=$(grep "^ExecStart=" "$svc_file" | sed 's/^ExecStart=//')
    local wss_url
    wss_url=$(echo "$exec_line" | grep -oE 'wss://[^[:space:]]+')
    PARSED_DOMAIN=$(echo "$wss_url"   | sed 's|wss://||' | sed 's|:[0-9]*$||')
    PARSED_WSS_PORT=$(echo "$wss_url" | grep -oE '[0-9]+$')
    PARSED_FLAGS=()
    while IFS= read -r f; do
        [ -n "$f" ] && PARSED_FLAGS+=("$f")
    done < <(echo "$exec_line" | grep -oE 'tcp://[^[:space:]]+')
}

parse_server_service() {
    local svc_file="/etc/systemd/system/wstunnel-server.service"
    [ -f "$svc_file" ] || error "Server service not found: $svc_file"
    local exec_line ws_url
    exec_line=$(grep "^ExecStart=" "$svc_file" | sed 's/^ExecStart=//')
    ws_url=$(echo "$exec_line" | grep -oE 'ws://[^[:space:]]+')
    PARSED_BIND_IP=$(echo "$ws_url"   | sed 's|ws://||' | sed 's|:[0-9]*$||')
    PARSED_BIND_PORT=$(echo "$ws_url" | grep -oE '[0-9]+$')
}

# ─────────────────────────────────────────────
# Display / build helpers
# ─────────────────────────────────────────────
show_client_state() {
    echo -e "  ${BOLD}Iran VPS domain :${RESET}  ${YELLOW}wss://${PARSED_DOMAIN}:${PARSED_WSS_PORT}${RESET}"
    echo ""
    echo -e "  ${BOLD}Port mappings:${RESET}"
    if [ ${#PARSED_FLAGS[@]} -eq 0 ]; then
        echo -e "    ${YELLOW}(no port mappings configured)${RESET}"
    else
        for i in "${!PARSED_FLAGS[@]}"; do
            local addr="${PARSED_FLAGS[$i]#tcp://}"
            local bh bp dh dp
            bh=$(echo "$addr" | cut -d: -f1)
            bp=$(echo "$addr" | cut -d: -f2)
            dh=$(echo "$addr" | cut -d: -f3)
            dp=$(echo "$addr" | cut -d: -f4)
            echo -e "    ${CYAN}#$((i+1))${RESET}  Iran VPS ${bh}:${bp}  →  this VPS ${dh}:${dp}"
        done
    fi
}

build_client_exec() {
    local result="/usr/local/bin/wstunnel client"
    for flag in "${PARSED_FLAGS[@]+"${PARSED_FLAGS[@]}"}"; do
        result+=" -R ${flag}"
    done
    result+=" wss://${PARSED_DOMAIN}:${PARSED_WSS_PORT}"
    echo "$result"
}

# ─────────────────────────────────────────────
# Write & restart service helpers
# ─────────────────────────────────────────────
write_client_service() {
    local exec_full
    exec_full=$(build_client_exec)
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
ExecStart=${exec_full}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl restart wstunnel-client.service
    echo ""
    systemctl status wstunnel-client.service --no-pager
    echo ""
    success "Service updated and restarted."
}

write_server_service() {
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
ExecStart=/usr/local/bin/wstunnel server ws://${PARSED_BIND_IP}:${PARSED_BIND_PORT}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl restart wstunnel-server.service
    echo ""
    systemctl status wstunnel-server.service --no-pager
    echo ""
    success "Service updated and restarted."
}

# ─────────────────────────────────────────────
# Install — Iran VPS (server)
# ─────────────────────────────────────────────
flow_server() {
    echo ""
    echo -e "${BOLD}─── wstunnel ──────────────────────────────────────────${RESET}"
    ask WSTUNNEL_VERSION "wstunnel version to install" "10.5.5"
    ask PARSED_BIND_IP   "Bind IP (keep 127.0.0.1 so only Caddy can reach it)" "127.0.0.1"
    ask PARSED_BIND_PORT "Port wstunnel server listens on" "2018"

    echo ""
    echo -e "${BOLD}─── Caddy / Domain ────────────────────────────────────${RESET}"
    ask DOMAIN "Tunnel subdomain pointing to this Iran VPS (e.g. tunnel.example.com)" ""

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━  Summary  ━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Mode             :  ${GREEN}Iran VPS — Server${RESET}"
    echo -e "  wstunnel version :  ${YELLOW}${WSTUNNEL_VERSION}${RESET}"
    echo -e "  wstunnel listens :  ${YELLOW}ws://${PARSED_BIND_IP}:${PARSED_BIND_PORT}${RESET}"
    echo -e "  Caddy domain     :  ${YELLOW}${DOMAIN}${RESET}"
    echo -e "  Caddy proxies    :  ${CYAN}${DOMAIN}:443  →  localhost:${PARSED_BIND_PORT}${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    confirm "Proceed with server installation?" || { info "Aborted."; exit 0; }
    echo ""

    install_wstunnel_binary "$WSTUNNEL_VERSION"
    setup_user
    write_server_service

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${YELLOW}ACTION REQUIRED — Add this block to your Caddyfile:${RESET}"
    echo ""
    echo -e "${CYAN}${DOMAIN} {${RESET}"
    echo -e "${CYAN}    reverse_proxy localhost:${PARSED_BIND_PORT}${RESET}"
    echo -e "${CYAN}}${RESET}"
    echo ""
    echo -e "Then reload Caddy:  ${CYAN}sudo systemctl reload caddy${RESET}"
    echo -e "View logs:          ${CYAN}sudo journalctl -u wstunnel-server.service -f${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    success "Iran VPS (server) setup complete."
}

# ─────────────────────────────────────────────
# Install — Foreign VPS (client)
# ─────────────────────────────────────────────
flow_client() {
    echo ""
    echo -e "${BOLD}─── wstunnel ──────────────────────────────────────────${RESET}"
    ask WSTUNNEL_VERSION "wstunnel version to install" "10.5.5"

    echo ""
    echo -e "${BOLD}─── Iran VPS connection ───────────────────────────────${RESET}"
    ask PARSED_DOMAIN   "Tunnel domain on Iran VPS (e.g. tunnel.example.com)" ""
    ask PARSED_WSS_PORT "WSS port on Iran VPS (Caddy HTTPS port)" "443"

    echo ""
    echo -e "${BOLD}─── Port mappings ─────────────────────────────────────${RESET}"
    echo -e "  How ${BOLD}-R${RESET} works:  [User] → ${YELLOW}Iran VPS${RESET}:PORT → tunnel → ${GREEN}this VPS${RESET}:PORT"
    echo ""

    PARSED_FLAGS=()
    declare -a IRAN_PORTS=()
    local count=0

    while true; do
        count=$((count + 1))
        echo -e "  ${BOLD}── Mapping #${count} ──${RESET}"
        ask IRAN_BIND_IP "Bind IP on Iran VPS (0.0.0.0 = public)" "0.0.0.0"
        ask IRAN_PORT    "Port to open on Iran VPS (users connect here)" "8443"
        ask LOCAL_HOST   "Local host on this Foreign VPS" "localhost"
        ask LOCAL_PORT   "Local port on this Foreign VPS" "${IRAN_PORT}"
        PARSED_FLAGS+=("tcp://${IRAN_BIND_IP}:${IRAN_PORT}:${LOCAL_HOST}:${LOCAL_PORT}")
        IRAN_PORTS+=("${IRAN_PORT}")
        echo ""
        confirm "Add another port mapping?" || break
        echo ""
    done

    local exec_full
    exec_full=$(build_client_exec)

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━  Summary  ━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Mode             :  ${GREEN}Foreign VPS — Client${RESET}"
    echo -e "  wstunnel version :  ${YELLOW}${WSTUNNEL_VERSION}${RESET}"
    echo -e "  Connect to Iran  :  ${YELLOW}wss://${PARSED_DOMAIN}:${PARSED_WSS_PORT}${RESET}"
    echo ""
    show_client_state
    echo ""
    echo -e "  ExecStart:  ${CYAN}${exec_full}${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    confirm "Proceed with client installation?" || { info "Aborted."; exit 0; }
    echo ""

    install_wstunnel_binary "$WSTUNNEL_VERSION"
    setup_user
    write_client_service

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${YELLOW}ACTION REQUIRED — Open these ports in Iran VPS firewall:${RESET}"
    echo ""
    for port in "${IRAN_PORTS[@]}"; do
        echo -e "  ${CYAN}sudo ufw allow ${port}/tcp${RESET}"
    done
    echo ""
    echo -e "View logs:  ${CYAN}sudo journalctl -u wstunnel-client.service -f${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    success "Foreign VPS (client) setup complete."
}

# ─────────────────────────────────────────────
# Edit — server (Iran VPS)
# ─────────────────────────────────────────────
edit_server() {
    parse_server_service

    echo ""
    echo -e "${BOLD}─── Current Server Configuration ─────────────────────${RESET}"
    echo -e "  ${BOLD}wstunnel listens :${RESET}  ${YELLOW}ws://${PARSED_BIND_IP}:${PARSED_BIND_PORT}${RESET}"
    echo ""

    ask NEW_BIND_IP   "New bind IP" "${PARSED_BIND_IP}"
    ask NEW_BIND_PORT "New bind port" "${PARSED_BIND_PORT}"

    if [ "$NEW_BIND_IP" = "$PARSED_BIND_IP" ] && [ "$NEW_BIND_PORT" = "$PARSED_BIND_PORT" ]; then
        info "No changes made."
        return
    fi

    PARSED_BIND_IP="$NEW_BIND_IP"
    PARSED_BIND_PORT="$NEW_BIND_PORT"

    echo ""
    echo -e "  New config: ${CYAN}ws://${PARSED_BIND_IP}:${PARSED_BIND_PORT}${RESET}"
    echo ""
    confirm "Apply and restart service?" || { info "Cancelled."; return; }
    echo ""

    write_server_service

    if [ "$NEW_BIND_PORT" != "2018" ]; then
        echo ""
        warn "Port changed — also update your Caddyfile:"
        echo -e "  ${CYAN}reverse_proxy localhost:${PARSED_BIND_PORT}${RESET}"
        echo -e "  Then: ${CYAN}sudo systemctl reload caddy${RESET}"
    fi
}

# ─────────────────────────────────────────────
# Edit — client (Foreign VPS)
# ─────────────────────────────────────────────
edit_client() {
    parse_client_service

    local changed=false

    while true; do
        echo ""
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━  Edit Client  ━━━━━━━━━━━━━━━━━━━${RESET}"
        show_client_state
        echo ""
        echo -e "${BOLD}─── Options ───────────────────────────────────────────${RESET}"
        echo -e "  ${CYAN}1${RESET}) Add new port mapping"
        echo -e "  ${CYAN}2${RESET}) Edit an existing port mapping"
        echo -e "  ${CYAN}3${RESET}) Remove a port mapping"
        echo -e "  ${CYAN}4${RESET}) Change Iran VPS domain / WSS port"
        if $changed; then
            echo -e "  ${CYAN}5${RESET}) ${GREEN}Apply changes and restart service${RESET}"
        else
            echo -e "  ${CYAN}5${RESET}) Apply changes and restart service"
        fi
        echo -e "  ${CYAN}6${RESET}) Cancel (discard all changes)"
        echo ""

        local choice
        read -rp "$(echo -e "  ${BOLD}Enter 1-6${RESET}: ")" choice

        case "$choice" in

            1)  # ── Add port ──────────────────────────────────────
                echo ""
                echo -e "  ${BOLD}── New Port Mapping ──${RESET}"
                ask IRAN_BIND_IP "Bind IP on Iran VPS" "0.0.0.0"
                ask IRAN_PORT    "Port to open on Iran VPS (users connect here)" "8443"
                ask LOCAL_HOST   "Local host on this Foreign VPS" "localhost"
                ask LOCAL_PORT   "Local port on this Foreign VPS" "${IRAN_PORT}"
                PARSED_FLAGS+=("tcp://${IRAN_BIND_IP}:${IRAN_PORT}:${LOCAL_HOST}:${LOCAL_PORT}")
                changed=true
                success "Port mapping added."
                ;;

            2)  # ── Edit port ─────────────────────────────────────
                if [ ${#PARSED_FLAGS[@]} -eq 0 ]; then
                    warn "No port mappings to edit."; continue
                fi
                echo ""
                echo -e "  Which mapping to edit?"
                for i in "${!PARSED_FLAGS[@]}"; do
                    local addr="${PARSED_FLAGS[$i]#tcp://}"
                    echo -e "    ${CYAN}$((i+1))${RESET}  $(echo "$addr" | cut -d: -f1):$(echo "$addr" | cut -d: -f2)  →  $(echo "$addr" | cut -d: -f3):$(echo "$addr" | cut -d: -f4)"
                done
                echo ""
                local e_idx
                read -rp "$(echo -e "  ${BOLD}Enter number${RESET}: ")" e_idx
                if [[ "$e_idx" =~ ^[0-9]+$ ]] && (( e_idx >= 1 && e_idx <= ${#PARSED_FLAGS[@]} )); then
                    local idx=$((e_idx - 1))
                    local old_addr="${PARSED_FLAGS[$idx]#tcp://}"
                    local old_bh old_bp old_dh old_dp
                    old_bh=$(echo "$old_addr" | cut -d: -f1)
                    old_bp=$(echo "$old_addr" | cut -d: -f2)
                    old_dh=$(echo "$old_addr" | cut -d: -f3)
                    old_dp=$(echo "$old_addr" | cut -d: -f4)
                    echo ""
                    ask IRAN_BIND_IP "Bind IP on Iran VPS"               "$old_bh"
                    ask IRAN_PORT    "Port to open on Iran VPS"           "$old_bp"
                    ask LOCAL_HOST   "Local host on this Foreign VPS"     "$old_dh"
                    ask LOCAL_PORT   "Local port on this Foreign VPS"     "$old_dp"
                    PARSED_FLAGS[$idx]="tcp://${IRAN_BIND_IP}:${IRAN_PORT}:${LOCAL_HOST}:${LOCAL_PORT}"
                    changed=true
                    success "Mapping #${e_idx} updated."
                else
                    warn "Invalid selection."
                fi
                ;;

            3)  # ── Remove port ───────────────────────────────────
                if [ ${#PARSED_FLAGS[@]} -eq 0 ]; then
                    warn "No port mappings to remove."; continue
                fi
                echo ""
                echo -e "  Which mapping to remove?"
                for i in "${!PARSED_FLAGS[@]}"; do
                    local addr="${PARSED_FLAGS[$i]#tcp://}"
                    echo -e "    ${CYAN}$((i+1))${RESET}  $(echo "$addr" | cut -d: -f1):$(echo "$addr" | cut -d: -f2)  →  $(echo "$addr" | cut -d: -f3):$(echo "$addr" | cut -d: -f4)"
                done
                echo ""
                local r_idx
                read -rp "$(echo -e "  ${BOLD}Enter number${RESET}: ")" r_idx
                if [[ "$r_idx" =~ ^[0-9]+$ ]] && (( r_idx >= 1 && r_idx <= ${#PARSED_FLAGS[@]} )); then
                    local rm=$((r_idx - 1))
                    local new_flags=()
                    for j in "${!PARSED_FLAGS[@]}"; do
                        [ "$j" -ne "$rm" ] && new_flags+=("${PARSED_FLAGS[$j]}")
                    done
                    PARSED_FLAGS=()
                    for f in "${new_flags[@]+"${new_flags[@]}"}"; do
                        PARSED_FLAGS+=("$f")
                    done
                    changed=true
                    success "Mapping #${r_idx} removed."
                else
                    warn "Invalid selection."
                fi
                ;;

            4)  # ── Change domain ─────────────────────────────────
                echo ""
                ask NEW_DOMAIN   "New Iran VPS domain" "${PARSED_DOMAIN}"
                ask NEW_WSS_PORT "New WSS port"        "${PARSED_WSS_PORT}"
                if [ "$NEW_DOMAIN" != "$PARSED_DOMAIN" ] || [ "$NEW_WSS_PORT" != "$PARSED_WSS_PORT" ]; then
                    PARSED_DOMAIN="$NEW_DOMAIN"
                    PARSED_WSS_PORT="$NEW_WSS_PORT"
                    changed=true
                    success "Domain updated."
                else
                    info "No changes."
                fi
                ;;

            5)  # ── Apply ─────────────────────────────────────────
                if ! $changed; then
                    info "No changes to apply."
                    continue
                fi
                echo ""
                echo -e "${BOLD}─── New Configuration ────────────────────────────────${RESET}"
                show_client_state
                echo ""
                echo -e "  ExecStart:  ${CYAN}$(build_client_exec)${RESET}"
                echo ""
                confirm "Apply these changes and restart service?" || continue
                echo ""
                write_client_service
                return
                ;;

            6)  # ── Cancel ────────────────────────────────────────
                info "No changes applied."
                return
                ;;

            *)
                warn "Please enter a number between 1 and 6."
                ;;
        esac
    done
}

# ─────────────────────────────────────────────
# flow_edit — detect service and route
# ─────────────────────────────────────────────
flow_edit() {
    declare -a FOUND_SVCS=()
    detect_services FOUND_SVCS

    if [ ${#FOUND_SVCS[@]} -eq 0 ]; then
        error "No wstunnel services found on this machine. Run Install (option 1 or 2) first."
    fi

    local has_server=false has_client=false
    for svc in "${FOUND_SVCS[@]}"; do
        [[ "$svc" == "wstunnel-server.service" ]] && has_server=true
        [[ "$svc" == "wstunnel-client.service" ]] && has_client=true
    done

    if $has_server && $has_client; then
        echo ""
        echo -e "${BOLD}Both services found. Which one to edit?${RESET}"
        echo ""
        echo -e "  ${CYAN}1${RESET}) Iran VPS   — wstunnel-server.service  (bind IP / port)"
        echo -e "  ${CYAN}2${RESET}) Foreign VPS — wstunnel-client.service  (ports + domain)"
        echo ""
        local sc
        while true; do
            read -rp "$(echo -e "  ${BOLD}Enter 1 or 2${RESET}: ")" sc
            case "$sc" in
                1) edit_server; return ;;
                2) edit_client; return ;;
                *) warn "Please enter 1 or 2." ;;
            esac
        done
    elif $has_server; then
        edit_server
    else
        edit_client
    fi
}

# ─────────────────────────────────────────────
# Update — upgrade wstunnel binary
# ─────────────────────────────────────────────
flow_update() {
    echo ""
    if command -v wstunnel &>/dev/null; then
        info "Current version: $(wstunnel --version 2>&1 | head -n1)"
    else
        error "wstunnel is not installed. Use Install (option 1 or 2) first."
    fi

    declare -a FOUND_SVCS=()
    detect_services FOUND_SVCS

    if [ ${#FOUND_SVCS[@]} -gt 0 ]; then
        echo -e "  Services found:"
        for svc in "${FOUND_SVCS[@]}"; do
            local st
            st=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
            echo -e "    ${CYAN}${svc}${RESET}  [${st}]"
        done
    fi

    echo ""
    ask NEW_VERSION "Version to upgrade to" "10.5.5"

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━  Summary  ━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Action         :  ${GREEN}Update wstunnel binary${RESET}"
    echo -e "  Target version :  ${YELLOW}${NEW_VERSION}${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    confirm "Proceed with update?" || { info "Aborted."; exit 0; }
    echo ""

    for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
        info "Stopping ${svc} ..."
        systemctl stop "$svc" || true
    done

    install_wstunnel_binary "$NEW_VERSION"

    for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
        info "Restarting ${svc} ..."
        systemctl start "$svc"
        systemctl status "$svc" --no-pager
        echo ""
    done

    success "Update complete: $(wstunnel --version 2>&1 | head -n1)"
}

# ─────────────────────────────────────────────
# Uninstall — remove wstunnel completely
# ─────────────────────────────────────────────
flow_uninstall() {
    echo ""
    declare -a FOUND_SVCS=()
    detect_services FOUND_SVCS

    local binary_exists=false user_exists=false
    command -v wstunnel &>/dev/null && binary_exists=true
    id "wstunnel" &>/dev/null        && user_exists=true

    if [ ${#FOUND_SVCS[@]} -eq 0 ] && ! $binary_exists && ! $user_exists; then
        info "Nothing to remove — wstunnel is not installed on this machine."
        exit 0
    fi

    echo -e "${BOLD}─── Will be removed ───────────────────────────────────${RESET}"
    echo ""
    for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
        local st
        st=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        echo -e "  ${CYAN}service${RESET}  /etc/systemd/system/${svc}  [${st}]"
    done
    $binary_exists && echo -e "  ${CYAN}binary${RESET}   /usr/local/bin/wstunnel"
    $user_exists   && echo -e "  ${CYAN}user${RESET}     wstunnel  +  /home/wstunnel/"
    echo ""
    echo -e "${RED}  All items above will be permanently removed.${RESET}"
    echo ""

    confirm "Are you sure you want to uninstall wstunnel completely?" || { info "Aborted."; exit 0; }
    echo ""

    for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
        info "Stopping and disabling ${svc} ..."
        systemctl stop    "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}"
        success "Removed /etc/systemd/system/${svc}"
    done

    [ ${#FOUND_SVCS[@]} -gt 0 ] && systemctl daemon-reload && systemctl reset-failed 2>/dev/null || true

    if $binary_exists; then
        rm -f /usr/local/bin/wstunnel
        success "Removed /usr/local/bin/wstunnel"
    fi

    if $user_exists; then
        rm -rf /home/wstunnel
        userdel wstunnel 2>/dev/null || true
        success "Removed user 'wstunnel' and /home/wstunnel/"
    fi

    echo ""
    success "wstunnel has been completely removed from this machine."
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
    echo -e "  Quick install:"
    echo -e "  ${CYAN}bash <(curl -fsSL https://raw.githubusercontent.com/Samr002/black-box/main/setup.sh)${RESET}"
    echo ""

    check_root

    echo -e "${BOLD}What would you like to do?${RESET}"
    echo ""
    pick_action ACTION

    case "$ACTION" in
        server)    flow_server    ;;
        client)    flow_client    ;;
        edit)      flow_edit      ;;
        update)    flow_update    ;;
        uninstall) flow_uninstall ;;
    esac
}

main "$@"
