#!/bin/bash
# WStunnel + Caddy — Unified Setup Script
# Traffic flow (-R reverse tunnel):
#   User → Iran VPS:PORT → WSS tunnel → Foreign VPS:PORT (VPN service lives here)

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

info()       { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()       { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()      { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
check_ok()   { echo -e "  ${GREEN}[✓]${RESET} $*"; }
check_fail() { echo -e "  ${RED}[✗]${RESET} $*"; }
check_warn() { echo -e "  ${YELLOW}[!]${RESET} $*"; }

# ─────────────────────────────────────────────
# Global parsed state
# ─────────────────────────────────────────────
PARSED_DOMAIN=""
PARSED_WSS_PORT=""
declare -a PARSED_FLAGS=()
PARSED_BIND_IP=""
PARSED_BIND_PORT=""
PARSED_UPGRADE_PATH=""
declare -a PARSED_RESTRICT_TO=()

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
    echo -e "  ${CYAN}2${RESET}) ${BOLD}Install${RESET}   — Foreign VPS  (wstunnel client, hosts the VPN service)"
    echo -e "  ${CYAN}3${RESET}) ${BOLD}Diagnose${RESET}  — check tunnel health layer by layer"
    echo -e "  ${CYAN}4${RESET}) ${BOLD}Edit${RESET}      — manage ports and domain on this machine"
    echo -e "  ${CYAN}5${RESET}) ${BOLD}Update${RESET}    — upgrade wstunnel binary to a newer version"
    echo -e "  ${CYAN}6${RESET}) ${BOLD}Uninstall${RESET} — remove wstunnel completely from this machine"
    echo ""
    while true; do
        read -rp "$(echo -e "  ${BOLD}Enter 1-6${RESET}: ")" choice
        case "$choice" in
            1) printf -v "$varname" 'server';    return ;;
            2) printf -v "$varname" 'client';    return ;;
            3) printf -v "$varname" 'diagnose';  return ;;
            4) printf -v "$varname" 'edit';      return ;;
            5) printf -v "$varname" 'update';    return ;;
            6) printf -v "$varname" 'uninstall'; return ;;
            *) warn "  Please enter a number between 1 and 6." ;;
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
    # بررسی اسم‌های استاندارد
    for svc in wstunnel-server.service wstunnel-client.service; do
        [ -f "/etc/systemd/system/${svc}" ] && _out+=("$svc")
    done
    # اگر هیچکدام پیدا نشد، هر فایل سرویس حاوی wstunnel را پیدا کن
    if [ ${#_out[@]} -eq 0 ]; then
        while IFS= read -r f; do
            [ -f "$f" ] && _out+=("$(basename "$f")")
        done < <(grep -rl "wstunnel" /etc/systemd/system/ 2>/dev/null | grep '\.service$' || true)
    fi
}

# مسیر دقیق باینری wstunnel را برمی‌گرداند (حتی اگر در PATH نباشد)
wstunnel_bin() {
    if   [ -x "/usr/local/bin/wstunnel" ]; then echo "/usr/local/bin/wstunnel"
    elif [ -x "/usr/bin/wstunnel" ];       then echo "/usr/bin/wstunnel"
    elif command -v wstunnel &>/dev/null;  then command -v wstunnel
    else echo ""
    fi
}

# مسیر دقیق باینری caddy را برمی‌گرداند
caddy_bin() {
    if   [ -x "/usr/bin/caddy" ];       then echo "/usr/bin/caddy"
    elif [ -x "/usr/local/bin/caddy" ]; then echo "/usr/local/bin/caddy"
    elif command -v caddy &>/dev/null;  then command -v caddy
    else echo ""
    fi
}

# نصب Caddy روی سیستم‌های Debian/Ubuntu
install_caddy() {
    local bin
    bin=$(caddy_bin)
    if [ -n "$bin" ]; then
        info "Caddy already installed: $("$bin" version 2>&1 | head -n1)  [$bin]"
        return
    fi

    info "Installing Caddy..."
    local caddy_ok=false

    # روش اول: apt از مخزن رسمی Caddy
    info "Trying apt (official Caddy repo)..."
    if apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl \
        && curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
        && curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null \
        && apt-get update -qq \
        && apt-get install -y caddy; then
        caddy_ok=true
        success "Caddy installed via apt."
    else
        warn "apt install failed — trying binary download from GitHub..."
    fi

    # روش دوم: دانلود باینری از GitHub
    if ! $caddy_ok; then
        local arch; arch=$(uname -m)
        case "$arch" in
            x86_64)  arch="amd64" ;;
            aarch64) arch="arm64" ;;
            *) error "Unsupported architecture: $arch" ;;
        esac
        local ver="2.9.1"
        local url="https://github.com/caddyserver/caddy/releases/download/v${ver}/caddy_${ver}_linux_${arch}.tar.gz"
        info "Downloading Caddy v${ver}..."
        cd /tmp
        wget -q --show-progress "$url" -O caddy_dl.tar.gz || error "Failed to download Caddy: $url"
        tar xzf caddy_dl.tar.gz caddy
        mv -f caddy /usr/local/bin/caddy
        chmod +x /usr/local/bin/caddy
        rm -f caddy_dl.tar.gz

        # ایجاد کاربر و دایرکتوری
        getent group caddy &>/dev/null  || groupadd --system caddy
        id caddy &>/dev/null || useradd --system --gid caddy \
            --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy
        mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
        chown caddy:caddy /var/lib/caddy /var/log/caddy

        # نوشتن فایل سرویس systemd
        cat > /etc/systemd/system/caddy.service <<'CADDY_SVC'
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
CADDY_SVC
        systemctl daemon-reload
        caddy_ok=true
        success "Caddy binary installed: $(/usr/local/bin/caddy version 2>&1 | head -n1)"
    fi
}

# نوشتن یا به‌روز‌رسانی بلاک دامنه در Caddyfile
configure_caddyfile() {
    local domain="$1" port="$2"
    local caddyfile="/etc/caddy/Caddyfile"

    mkdir -p "$(dirname "$caddyfile")"

    local block
    block="${domain} {
    header -Server
    reverse_proxy localhost:${port}
}"

    if [ ! -f "$caddyfile" ] || [ ! -s "$caddyfile" ]; then
        # فایل وجود ندارد یا خالی است — از صفر بنویس
        echo "$block" > "$caddyfile"
        success "Caddyfile created."
    elif grep -q "^${domain}" "$caddyfile" 2>/dev/null; then
        # بلاک این دامنه از قبل وجود دارد — پورت را به‌روز کن
        info "Domain ${domain} already in Caddyfile — updating reverse_proxy port..."
        # با sed بلاک موجود را جایگزین کن
        python3 - "$caddyfile" "$domain" "$port" <<'PYEOF'
import sys, re
path, domain, port = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    lines = f.read().split('\n')
result = []
i = 0
replaced = False
dom_pat = re.compile(r'^' + re.escape(domain) + r'\s*\{')
while i < len(lines):
    if dom_pat.match(lines[i]):
        # Skip the entire block by counting brace depth
        depth = lines[i].count('{') - lines[i].count('}')
        i += 1
        while i < len(lines) and depth > 0:
            depth += lines[i].count('{') - lines[i].count('}')
            i += 1
        # Insert updated block
        result.append(f"{domain} {{\n    header -Server\n    reverse_proxy localhost:{port}\n}}")
        replaced = True
    else:
        result.append(lines[i])
        i += 1
if not replaced:
    result.append(f"\n{domain} {{\n    header -Server\n    reverse_proxy localhost:{port}\n}}")
with open(path, 'w') as f:
    f.write('\n'.join(result))
PYEOF
        success "Caddyfile updated."
    else
        # فایل وجود دارد و دامنه دیگری دارد — اضافه کن
        echo "" >> "$caddyfile"
        echo "$block" >> "$caddyfile"
        success "Domain block appended to existing Caddyfile."
    fi

    # اعتبارسنجی کانفیگ
    local bin
    bin=$(caddy_bin)
    if "$bin" validate --config "$caddyfile" &>/dev/null 2>&1; then
        success "Caddyfile is valid."
    else
        warn "Caddyfile validation warning — check with: $bin validate --config $caddyfile"
    fi
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
    PARSED_DOMAIN="" PARSED_WSS_PORT="443" PARSED_FLAGS=() PARSED_UPGRADE_PATH=""
    if [ ! -f "$svc_file" ]; then
        warn "Client service file not found — some values will be empty"
        return
    fi
    local exec_line wss_url
    exec_line=$(grep "^ExecStart=" "$svc_file" | sed 's/^ExecStart=//')
    wss_url=$(echo "$exec_line" | grep -oE 'wss://[^[:space:]]+')
    PARSED_DOMAIN=$(echo "$wss_url"   | sed 's|wss://||' | sed 's|:[0-9]*$||')
    PARSED_WSS_PORT=$(echo "$wss_url" | grep -oE '[0-9]+$')
    PARSED_FLAGS=()
    while IFS= read -r f; do
        [ -n "$f" ] && PARSED_FLAGS+=("$f")
    done < <(echo "$exec_line" | grep -oE 'tcp://[^[:space:]]+')
    # استخراج secret path
    local prev=""
    for tok in $exec_line; do
        [ "$prev" = "--http-upgrade-path-prefix" ] && PARSED_UPGRADE_PATH="$tok"
        prev="$tok"
    done
}

parse_server_service() {
    local svc_file="/etc/systemd/system/wstunnel-server.service"
    PARSED_BIND_IP="127.0.0.1" PARSED_BIND_PORT="2018"
    PARSED_UPGRADE_PATH="" PARSED_RESTRICT_TO=()
    if [ ! -f "$svc_file" ]; then
        warn "Server service file not found — using default values for diagnostics"
        return
    fi
    local exec_line ws_url
    exec_line=$(grep "^ExecStart=" "$svc_file" | sed 's/^ExecStart=//')
    ws_url=$(echo "$exec_line" | grep -oE 'ws://[^[:space:]]+')
    PARSED_BIND_IP=$(echo "$ws_url"   | sed 's|ws://||' | sed 's|:[0-9]*$||')
    PARSED_BIND_PORT=$(echo "$ws_url" | grep -oE '[0-9]+$')
    # استخراج secret path و restrict-to
    local prev=""
    for tok in $exec_line; do
        [ "$prev" = "--restrict-http-upgrade-path-prefix" ] && PARSED_UPGRADE_PATH="$tok"
        [ "$prev" = "--restrict-to" ] && PARSED_RESTRICT_TO+=("$tok")
        prev="$tok"
    done
}

# ─────────────────────────────────────────────
# Display / build helpers
# ─────────────────────────────────────────────
show_client_state() {
    echo -e "  ${BOLD}Iran VPS domain :${RESET}  ${YELLOW}wss://${PARSED_DOMAIN}:${PARSED_WSS_PORT}${RESET}"
    if [ -n "${PARSED_UPGRADE_PATH:-}" ]; then
        echo -e "  ${BOLD}Secret path     :${RESET}  ${YELLOW}${PARSED_UPGRADE_PATH}${RESET}"
    else
        echo -e "  ${BOLD}Secret path     :${RESET}  ${YELLOW}(none — not recommended)${RESET}"
    fi
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
    result+=" --websocket-ping-frequency-sec 20"
    result+=" --connection-min-idle 3"
    if [ -n "${PARSED_UPGRADE_PATH:-}" ]; then
        result+=" --http-upgrade-path-prefix ${PARSED_UPGRADE_PATH}"
    fi
    for flag in "${PARSED_FLAGS[@]+"${PARSED_FLAGS[@]}"}"; do
        result+=" -R ${flag}"
    done
    result+=" wss://${PARSED_DOMAIN}:${PARSED_WSS_PORT}"
    echo "$result"
}

# ─────────────────────────────────────────────
# Write & restart helpers
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
StartLimitIntervalSec=0

[Service]
Type=simple
User=wstunnel
Group=wstunnel
WorkingDirectory=/home/wstunnel
ExecStart=${exec_full}
Restart=always
RestartSec=3
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
    # ساخت رشته flags به صورت پویا
    local exec_flags="--websocket-ping-frequency-sec 20"
    if [ -n "${PARSED_UPGRADE_PATH:-}" ]; then
        exec_flags+=" --restrict-http-upgrade-path-prefix ${PARSED_UPGRADE_PATH}"
    fi
    for r in "${PARSED_RESTRICT_TO[@]+"${PARSED_RESTRICT_TO[@]}"}"; do
        exec_flags+=" --restrict-to ${r}"
    done

    info "Writing /etc/systemd/system/wstunnel-server.service ..."
    cat > /etc/systemd/system/wstunnel-server.service <<EOF
[Unit]
Description=WStunnel Server
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=wstunnel
Group=wstunnel
WorkingDirectory=/home/wstunnel
ExecStart=/usr/local/bin/wstunnel server ${exec_flags} ws://${PARSED_BIND_IP}:${PARSED_BIND_PORT}
Restart=always
RestartSec=3
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
# Diagnose — Iran VPS (server)
# ─────────────────────────────────────────────
diagnose_server() {
    parse_server_service

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━  Iran VPS (Server) Diagnostics  ━━━━━━━━━━━${RESET}"
    echo ""

    # 1. Binary
    local wbin
    wbin=$(wstunnel_bin)
    if [ -n "$wbin" ]; then
        check_ok "wstunnel binary: $("$wbin" --version 2>&1 | head -n1)  [$wbin]"
    else
        check_fail "wstunnel binary not found (checked /usr/local/bin and /usr/bin)"
    fi

    # 2. Service running
    if systemctl is-active wstunnel-server.service &>/dev/null; then
        check_ok "wstunnel-server.service is running"
    else
        check_fail "wstunnel-server.service is NOT running"
        echo -e "         ${YELLOW}→ sudo systemctl start wstunnel-server.service${RESET}"
    fi

    # 3. wstunnel port bound
    if ss -tlnp 2>/dev/null | grep -q ":${PARSED_BIND_PORT} "; then
        check_ok "wstunnel is bound to port ${PARSED_BIND_PORT}"
    else
        check_fail "wstunnel is NOT bound to port ${PARSED_BIND_PORT} — service may have crashed"
        echo -e "         ${YELLOW}→ sudo journalctl -u wstunnel-server.service -n 30${RESET}"
    fi

    # 4. Caddy running
    if systemctl is-active caddy &>/dev/null; then
        check_ok "Caddy is running"
    else
        check_fail "Caddy is NOT running"
        echo -e "         ${YELLOW}→ sudo systemctl start caddy${RESET}"
    fi

    # 5. Port 443 open
    if ss -tlnp 2>/dev/null | grep -q ":443 "; then
        check_ok "Port 443 is listening (Caddy/HTTPS ready)"
    else
        check_fail "Port 443 is NOT listening — Caddy may not be configured for HTTPS"
    fi

    # 6. Caddy binary + config check
    local cbin
    cbin=$(caddy_bin)
    if [ -n "$cbin" ]; then
        check_ok "Caddy binary found: [$cbin]"
        if "$cbin" validate --config /etc/caddy/Caddyfile &>/dev/null 2>&1; then
            check_ok "Caddyfile is valid"
        else
            check_fail "Caddyfile has errors"
            echo -e "         ${YELLOW}→ $cbin validate --config /etc/caddy/Caddyfile${RESET}"
        fi
    else
        check_fail "Caddy is NOT installed"
        echo -e "         ${YELLOW}→ Run Install (option 1) to install Caddy automatically${RESET}"
    fi

    # 7. Firewall — check if common tools exist and show status
    echo ""
    echo -e "  ${BOLD}Firewall:${RESET}"
    if command -v ufw &>/dev/null; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -1)
        echo -e "    ufw: ${YELLOW}${ufw_status}${RESET}"
        echo -e "    ${YELLOW}→ Make sure port 443 and your forwarded ports are allowed${RESET}"
        echo -e "    ${YELLOW}→ sudo ufw allow 443/tcp${RESET}"
    elif command -v iptables &>/dev/null; then
        check_warn "iptables detected — manually verify port 443 is open"
        echo -e "    ${YELLOW}→ iptables -L INPUT -n | grep 443${RESET}"
    else
        check_warn "No firewall tool detected (ufw/iptables)"
    fi

    # 8. Recent logs
    echo ""
    echo -e "  ${BOLD}Last 15 log lines:${RESET}"
    journalctl -u wstunnel-server.service -n 15 --no-pager 2>/dev/null \
        | sed 's/^/    /' \
        || echo -e "    ${YELLOW}(no logs available)${RESET}"

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# ─────────────────────────────────────────────
# Diagnose — Foreign VPS (client)
# ─────────────────────────────────────────────
diagnose_client() {
    parse_client_service

    echo ""
    echo -e "${BOLD}━━━━━━━━━  Foreign VPS (Client) Diagnostics  ━━━━━━━━━━${RESET}"
    echo ""

    # 1. Binary
    if command -v wstunnel &>/dev/null; then
        check_ok "wstunnel binary: $(wstunnel --version 2>&1 | head -n1)"
    else
        check_fail "wstunnel binary not found at /usr/local/bin/wstunnel"
    fi

    # 2. Service running
    if systemctl is-active wstunnel-client.service &>/dev/null; then
        check_ok "wstunnel-client.service is running"
    else
        check_fail "wstunnel-client.service is NOT running"
        echo -e "         ${YELLOW}→ sudo systemctl start wstunnel-client.service${RESET}"
    fi

    # 3. DNS resolution
    local resolved=""
    if resolved=$(getent hosts "${PARSED_DOMAIN}" 2>/dev/null | awk '{print $1}' | head -1) && [ -n "$resolved" ]; then
        check_ok "DNS: ${PARSED_DOMAIN} → ${resolved}"
    else
        check_fail "DNS cannot resolve ${PARSED_DOMAIN}"
        echo -e "         ${YELLOW}→ Check domain A record points to Iran VPS IP${RESET}"
        echo -e "         ${YELLOW}→ nslookup ${PARSED_DOMAIN}${RESET}"
    fi

    # 4. HTTPS reachability to Iran VPS
    local http_code
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        --max-time 6 \
        "https://${PARSED_DOMAIN}:${PARSED_WSS_PORT}" 2>/dev/null || echo "000")
    if [ "$http_code" != "000" ]; then
        check_ok "Iran VPS reachable at https://${PARSED_DOMAIN}:${PARSED_WSS_PORT} (HTTP ${http_code})"
    else
        check_fail "Cannot reach https://${PARSED_DOMAIN}:${PARSED_WSS_PORT} (timeout/refused)"
        echo -e "         ${YELLOW}→ Is Caddy running on Iran VPS?${RESET}"
        echo -e "         ${YELLOW}→ Is port 443 open in Iran VPS firewall?${RESET}"
        echo -e "         ${YELLOW}→ Does DNS point to Iran VPS?${RESET}"
    fi

    # 5. VPN service listening check (local side — traffic arrives here via -R)
    echo ""
    echo -e "  ${BOLD}Local VPN service check (traffic arrives on THIS machine):${RESET}"
    echo -e "  ${YELLOW}(With -R, ports open on Iran VPS; your VPN service must run HERE)${RESET}"
    echo ""

    local any_missing=false
    for flag in "${PARSED_FLAGS[@]+"${PARSED_FLAGS[@]}"}"; do
        local addr="${flag#tcp://}"
        local bh bp dh dp
        bh=$(echo "$addr" | cut -d: -f1)
        bp=$(echo "$addr" | cut -d: -f2)
        dh=$(echo "$addr" | cut -d: -f3)
        dp=$(echo "$addr" | cut -d: -f4)

        if ss -tlnp 2>/dev/null | grep -qE ":${dp} "; then
            local proc
            proc=$(ss -tlnp 2>/dev/null | grep ":${dp} " | grep -oP 'users:\(\("\K[^"]+' | head -1 || echo "?")
            check_ok "Port ${dp} is listening  [process: ${proc}]  ← Iran VPS:${bp} forwards here"
        else
            check_fail "NOTHING is listening on ${dh}:${dp}"
            echo -e "         ${RED}Your VPN/proxy service is NOT running on this port!${RESET}"
            echo -e "         ${YELLOW}→ Iran VPS:${bp} will forward traffic here but no service accepts it${RESET}"
            echo -e "         ${YELLOW}→ Start your VPN service (Xray, V2Ray, etc.) on port ${dp}${RESET}"
            any_missing=true
        fi
    done

    # 6. Tunnel connectivity self-test
    echo ""
    echo -e "  ${BOLD}Tunnel self-test (5 s timeout):${RESET}"
    local tunnel_ok=false
    for flag in "${PARSED_FLAGS[@]+"${PARSED_FLAGS[@]}"}"; do
        local addr="${flag#tcp://}"
        local bp dp
        bp=$(echo "$addr" | cut -d: -f2)
        dp=$(echo "$addr" | cut -d: -f4)

        # Try to connect through the tunnel: connect to Iran VPS:bp → should arrive at local:dp
        if timeout 5 bash -c "echo >/dev/tcp/${PARSED_DOMAIN}/${bp}" 2>/dev/null; then
            check_ok "Tunnel port ${bp} on Iran VPS is reachable from here"
            tunnel_ok=true
        else
            check_fail "Iran VPS:${bp} is NOT reachable (tunnel port closed or firewall blocking)"
            echo -e "         ${YELLOW}→ On Iran VPS run: sudo ufw allow ${bp}/tcp${RESET}"
            echo -e "         ${YELLOW}→ Check wstunnel-server logs on Iran VPS${RESET}"
        fi
    done

    # 7. Recent logs
    echo ""
    echo -e "  ${BOLD}Last 20 log lines:${RESET}"
    journalctl -u wstunnel-client.service -n 20 --no-pager 2>/dev/null \
        | sed 's/^/    /' \
        || echo -e "    ${YELLOW}(no logs available)${RESET}"

    # 8. Summary verdict
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━  Verdict  ━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    if $any_missing; then
        echo -e "  ${RED}Most likely cause: VPN service not running on this Foreign VPS.${RESET}"
        echo -e "  The wstunnel tunnel may be working fine, but there is nothing"
        echo -e "  listening on the destination port to accept the forwarded traffic."
        echo ""
        echo -e "  ${YELLOW}Fix: start your VPN/proxy (Xray, V2Ray, Shadowsocks, etc.)${RESET}"
        echo -e "  ${YELLOW}and make sure it listens on the local port shown above.${RESET}"
    elif ! $tunnel_ok; then
        echo -e "  ${RED}Most likely cause: Iran VPS firewall blocking the forward port(s).${RESET}"
        echo -e "  The tunnel control channel (WSS/443) seems reachable, but the"
        echo -e "  reverse-forwarded port(s) are not accessible."
        echo ""
        echo -e "  ${YELLOW}Fix: open the port(s) in Iran VPS firewall (ufw/iptables).${RESET}"
    else
        echo -e "  ${GREEN}Tunnel appears healthy. If VPN still fails, check VPN client config.${RESET}"
        echo -e "  Make sure the VPN client points to Iran VPS IP and the correct port."
    fi
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# ─────────────────────────────────────────────
# flow_diagnose — detect and route
# ─────────────────────────────────────────────
flow_diagnose() {
    declare -a FOUND_SVCS=()
    detect_services FOUND_SVCS

    local has_server=false has_client=false
    for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
        [[ "$svc" == "wstunnel-server.service" ]] && has_server=true
        [[ "$svc" == "wstunnel-client.service" ]] && has_client=true
    done

    # اگر هیچ سرویسی پیدا نشد، از کاربر بپرس
    if ! $has_server && ! $has_client; then
        echo ""
        warn "No wstunnel service files found at /etc/systemd/system/"
        echo -e "  (wstunnel may have been installed manually)"
        echo ""
        echo -e "  ${BOLD}Which VPS is this?${RESET}"
        echo ""
        echo -e "  ${CYAN}1${RESET}) Iran VPS   — server (wstunnel server + Caddy)"
        echo -e "  ${CYAN}2${RESET}) Foreign VPS — client (wstunnel client, VPN service)"
        echo ""
        local ch
        while true; do
            read -rp "$(echo -e "  ${BOLD}Enter 1 or 2${RESET}: ")" ch
            case "$ch" in
                1) diagnose_server; return ;;
                2) diagnose_client; return ;;
                *) warn "Please enter 1 or 2." ;;
            esac
        done
    fi

    $has_server && diagnose_server
    $has_client && diagnose_client
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
    echo -e "${BOLD}─── Security ──────────────────────────────────────────${RESET}"
    echo -e "  ${YELLOW}Secret path:${RESET} hides WebSocket endpoint from scanners."
    echo -e "  Enter ${CYAN}'none'${RESET} to disable (not recommended)."
    ask PARSED_UPGRADE_PATH "Secret WebSocket path" "/wst-api"
    [ "${PARSED_UPGRADE_PATH}" = "none" ] && PARSED_UPGRADE_PATH=""

    echo ""
    echo -e "  ${YELLOW}Restrict tunnels:${RESET} only allow specified ports (prevents open-proxy abuse)."
    echo -e "  Enter comma-separated ports or ${CYAN}'none'${RESET} to allow all (not recommended)."
    ask RESTRICT_PORTS_INPUT "Allowed tunnel ports on Iran VPS (e.g. 8443,1080)" "8443"
    PARSED_RESTRICT_TO=()
    if [ "${RESTRICT_PORTS_INPUT}" != "none" ]; then
        IFS=',' read -ra _rp <<< "${RESTRICT_PORTS_INPUT}"
        for _p in "${_rp[@]}"; do
            _p=$(echo "$_p" | tr -d ' ')
            [ -n "$_p" ] && PARSED_RESTRICT_TO+=("0.0.0.0:${_p}")
        done
    fi

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━  Summary  ━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Mode             :  ${GREEN}Iran VPS — Server${RESET}"
    echo -e "  wstunnel version :  ${YELLOW}${WSTUNNEL_VERSION}${RESET}"
    echo -e "  wstunnel listens :  ${YELLOW}ws://${PARSED_BIND_IP}:${PARSED_BIND_PORT}${RESET}"
    echo -e "  Caddy domain     :  ${YELLOW}${DOMAIN}${RESET}"
    echo -e "  Caddy proxies    :  ${CYAN}${DOMAIN}:443  →  localhost:${PARSED_BIND_PORT}${RESET}"
    echo -e "  Secret path      :  ${YELLOW}${PARSED_UPGRADE_PATH:-"(none)"}${RESET}"
    echo -e "  Restrict to      :  ${YELLOW}${PARSED_RESTRICT_TO[*]:-"(unrestricted)"}${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    confirm "Proceed with server installation?" || { info "Aborted."; exit 0; }
    echo ""

    # ── ۱. نصب wstunnel ────────────────────────────────
    install_wstunnel_binary "$WSTUNNEL_VERSION"
    setup_user
    write_server_service

    # ── ۲. نصب و کانفیگ Caddy ──────────────────────────
    echo ""
    echo -e "${BOLD}─── Caddy ─────────────────────────────────────────────${RESET}"
    install_caddy
    configure_caddyfile "$DOMAIN" "$PARSED_BIND_PORT"

    info "Enabling and starting Caddy..."
    systemctl enable caddy
    systemctl restart caddy
    sleep 1
    if systemctl is-active caddy &>/dev/null; then
        success "Caddy is running."
    else
        warn "Caddy failed to start — check logs:"
        journalctl -u caddy -n 20 --no-pager | sed 's/^/    /'
    fi

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  wstunnel logs:  ${CYAN}sudo journalctl -u wstunnel-server.service -f${RESET}"
    echo -e "  Caddy logs:     ${CYAN}sudo journalctl -u caddy -f${RESET}"
    echo -e "  Caddyfile:      ${CYAN}/etc/caddy/Caddyfile${RESET}"
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
    echo -e "${BOLD}─── Security ──────────────────────────────────────────${RESET}"
    echo -e "  ${YELLOW}Must match the secret path configured on Iran VPS.${RESET}"
    echo -e "  Enter ${CYAN}'none'${RESET} if Iran VPS has no secret path."
    ask PARSED_UPGRADE_PATH "Secret WebSocket path" "/wst-api"
    [ "${PARSED_UPGRADE_PATH}" = "none" ] && PARSED_UPGRADE_PATH=""

    echo ""
    echo -e "${BOLD}─── Port mappings ─────────────────────────────────────${RESET}"
    echo -e "  How ${BOLD}-R${RESET} works:"
    echo -e "    [User] → ${YELLOW}Iran VPS${RESET}:IRAN_PORT  →  WSS tunnel  →  ${GREEN}this VPS${RESET}:LOCAL_PORT"
    echo -e "  Ports open on Iran VPS. Your VPN service must run on LOCAL_PORT here."
    echo ""

    PARSED_FLAGS=()
    declare -a IRAN_PORTS=()
    local count=0

    while true; do
        count=$((count + 1))
        echo -e "  ${BOLD}── Mapping #${count} ──${RESET}"
        ask IRAN_BIND_IP "Bind IP on Iran VPS (0.0.0.0 = public)" "0.0.0.0"
        ask IRAN_PORT    "Port to open on Iran VPS (users connect here)" "8443"
        ask LOCAL_HOST   "Local host on this Foreign VPS (VPN service listens here)" "localhost"
        ask LOCAL_PORT   "Local port on this Foreign VPS (VPN service listens here)" "${IRAN_PORT}"
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
    echo -e "  Secret path      :  ${YELLOW}${PARSED_UPGRADE_PATH:-"(none)"}${RESET}"
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
    echo -e "${YELLOW}REQUIRED STEPS after this:${RESET}"
    echo ""
    echo -e "  ${BOLD}1. Open these ports in Iran VPS firewall:${RESET}"
    for port in "${IRAN_PORTS[@]}"; do
        echo -e "     ${CYAN}sudo ufw allow ${port}/tcp${RESET}   (on Iran VPS)"
    done
    echo ""
    echo -e "  ${BOLD}2. Make sure your VPN service runs on this Foreign VPS:${RESET}"
    for flag in "${PARSED_FLAGS[@]}"; do
        local addr="${flag#tcp://}"
        local dp
        dp=$(echo "$addr" | cut -d: -f4)
        echo -e "     ${CYAN}port ${dp} must be listening here${RESET} (Xray, V2Ray, etc.)"
    done
    echo ""
    echo -e "  ${BOLD}3. Run Diagnose (option 3) to verify everything is working.${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    success "Foreign VPS (client) setup complete."
}

# ─────────────────────────────────────────────
# Edit — server
# ─────────────────────────────────────────────
edit_server() {
    parse_server_service
    local cur_ports=""
    for r in "${PARSED_RESTRICT_TO[@]+"${PARSED_RESTRICT_TO[@]}"}"; do
        local _p="${r##*:}"; cur_ports+="${_p},"; done
    cur_ports="${cur_ports%,}"

    echo ""
    echo -e "${BOLD}─── Current Server Configuration ─────────────────────${RESET}"
    echo -e "  ${BOLD}wstunnel listens :${RESET}  ${YELLOW}ws://${PARSED_BIND_IP}:${PARSED_BIND_PORT}${RESET}"
    echo -e "  ${BOLD}Secret path      :${RESET}  ${YELLOW}${PARSED_UPGRADE_PATH:-"(none)"}${RESET}"
    echo -e "  ${BOLD}Restrict to      :${RESET}  ${YELLOW}${cur_ports:-"(unrestricted)"}${RESET}"
    echo ""

    ask NEW_BIND_IP   "Bind IP"   "${PARSED_BIND_IP}"
    ask NEW_BIND_PORT "Bind port" "${PARSED_BIND_PORT}"

    echo ""
    echo -e "  Enter ${CYAN}'none'${RESET} to disable secret path."
    ask NEW_UPGRADE_PATH "Secret WebSocket path" "${PARSED_UPGRADE_PATH:-none}"
    [ "${NEW_UPGRADE_PATH}" = "none" ] && NEW_UPGRADE_PATH=""

    echo ""
    echo -e "  Comma-separated ports, or ${CYAN}'none'${RESET} to allow all."
    ask NEW_RESTRICT "Allowed tunnel ports (e.g. 8443,1080)" "${cur_ports:-none}"

    PARSED_BIND_IP="${NEW_BIND_IP}"
    PARSED_BIND_PORT="${NEW_BIND_PORT}"
    PARSED_UPGRADE_PATH="${NEW_UPGRADE_PATH}"
    PARSED_RESTRICT_TO=()
    if [ "${NEW_RESTRICT}" != "none" ] && [ -n "${NEW_RESTRICT}" ]; then
        IFS=',' read -ra _rp <<< "${NEW_RESTRICT}"
        for _p in "${_rp[@]}"; do
            _p=$(echo "$_p" | tr -d ' ')
            [ -n "$_p" ] && PARSED_RESTRICT_TO+=("0.0.0.0:${_p}")
        done
    fi

    echo ""
    echo -e "${BOLD}─── New Configuration ─────────────────────────────────${RESET}"
    echo -e "  wstunnel listens :  ${CYAN}ws://${PARSED_BIND_IP}:${PARSED_BIND_PORT}${RESET}"
    echo -e "  Secret path      :  ${CYAN}${PARSED_UPGRADE_PATH:-"(none)"}${RESET}"
    echo -e "  Restrict to      :  ${CYAN}${PARSED_RESTRICT_TO[*]:-"(unrestricted)"}${RESET}"
    echo ""
    confirm "Apply and restart service?" || { info "Cancelled."; return; }
    echo ""
    write_server_service
    if [ "${NEW_BIND_PORT}" != "2018" ]; then
        warn "Port changed — update your Caddyfile: reverse_proxy localhost:${PARSED_BIND_PORT}"
        echo -e "  Then: ${CYAN}sudo systemctl reload caddy${RESET}"
    fi
}

# ─────────────────────────────────────────────
# Edit — client
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
        echo -e "  ${CYAN}5${RESET}) Change secret WebSocket path"
        echo -e "  ${CYAN}6${RESET}) Apply changes and restart service"
        echo -e "  ${CYAN}7${RESET}) Cancel (discard all changes)"
        echo ""

        local choice
        read -rp "$(echo -e "  ${BOLD}Enter 1-7${RESET}: ")" choice

        case "$choice" in
            1)
                echo ""
                echo -e "  ${BOLD}── New Port Mapping ──${RESET}"
                ask IRAN_BIND_IP "Bind IP on Iran VPS" "0.0.0.0"
                ask IRAN_PORT    "Port to open on Iran VPS" "8443"
                ask LOCAL_HOST   "Local host on this Foreign VPS" "localhost"
                ask LOCAL_PORT   "Local port on this Foreign VPS" "${IRAN_PORT}"
                PARSED_FLAGS+=("tcp://${IRAN_BIND_IP}:${IRAN_PORT}:${LOCAL_HOST}:${LOCAL_PORT}")
                changed=true
                success "Port mapping added."
                ;;
            2)
                [ ${#PARSED_FLAGS[@]} -eq 0 ] && { warn "No port mappings to edit."; continue; }
                echo ""
                echo -e "  Which mapping to edit?"
                for i in "${!PARSED_FLAGS[@]}"; do
                    local a="${PARSED_FLAGS[$i]#tcp://}"
                    echo -e "    ${CYAN}$((i+1))${RESET}  $(echo "$a"|cut -d: -f1):$(echo "$a"|cut -d: -f2)  →  $(echo "$a"|cut -d: -f3):$(echo "$a"|cut -d: -f4)"
                done
                echo ""
                local e_idx
                read -rp "$(echo -e "  ${BOLD}Enter number${RESET}: ")" e_idx
                if [[ "$e_idx" =~ ^[0-9]+$ ]] && (( e_idx >= 1 && e_idx <= ${#PARSED_FLAGS[@]} )); then
                    local idx=$((e_idx - 1))
                    local oa="${PARSED_FLAGS[$idx]#tcp://}"
                    echo ""
                    ask IRAN_BIND_IP "Bind IP on Iran VPS"           "$(echo "$oa"|cut -d: -f1)"
                    ask IRAN_PORT    "Port on Iran VPS"               "$(echo "$oa"|cut -d: -f2)"
                    ask LOCAL_HOST   "Local host on this Foreign VPS" "$(echo "$oa"|cut -d: -f3)"
                    ask LOCAL_PORT   "Local port on this Foreign VPS" "$(echo "$oa"|cut -d: -f4)"
                    PARSED_FLAGS[$idx]="tcp://${IRAN_BIND_IP}:${IRAN_PORT}:${LOCAL_HOST}:${LOCAL_PORT}"
                    changed=true; success "Mapping #${e_idx} updated."
                else
                    warn "Invalid selection."
                fi
                ;;
            3)
                [ ${#PARSED_FLAGS[@]} -eq 0 ] && { warn "No port mappings to remove."; continue; }
                echo ""
                echo -e "  Which mapping to remove?"
                for i in "${!PARSED_FLAGS[@]}"; do
                    local a="${PARSED_FLAGS[$i]#tcp://}"
                    echo -e "    ${CYAN}$((i+1))${RESET}  $(echo "$a"|cut -d: -f1):$(echo "$a"|cut -d: -f2)  →  $(echo "$a"|cut -d: -f3):$(echo "$a"|cut -d: -f4)"
                done
                echo ""
                local r_idx
                read -rp "$(echo -e "  ${BOLD}Enter number${RESET}: ")" r_idx
                if [[ "$r_idx" =~ ^[0-9]+$ ]] && (( r_idx >= 1 && r_idx <= ${#PARSED_FLAGS[@]} )); then
                    local rm=$((r_idx - 1))
                    local nf=()
                    for j in "${!PARSED_FLAGS[@]}"; do
                        [ "$j" -ne "$rm" ] && nf+=("${PARSED_FLAGS[$j]}")
                    done
                    PARSED_FLAGS=()
                    for f in "${nf[@]+"${nf[@]}"}"; do PARSED_FLAGS+=("$f"); done
                    changed=true; success "Mapping #${r_idx} removed."
                else
                    warn "Invalid selection."
                fi
                ;;
            4)
                echo ""
                ask NEW_DOMAIN   "New Iran VPS domain"  "${PARSED_DOMAIN}"
                ask NEW_WSS_PORT "New WSS port"         "${PARSED_WSS_PORT}"
                if [ "$NEW_DOMAIN" != "$PARSED_DOMAIN" ] || [ "$NEW_WSS_PORT" != "$PARSED_WSS_PORT" ]; then
                    PARSED_DOMAIN="$NEW_DOMAIN"
                    PARSED_WSS_PORT="$NEW_WSS_PORT"
                    changed=true; success "Domain updated."
                else
                    info "No changes."
                fi
                ;;
            5)
                echo ""
                echo -e "  Current: ${YELLOW}${PARSED_UPGRADE_PATH:-"(none)"}${RESET}"
                echo -e "  Enter ${CYAN}'none'${RESET} to disable secret path."
                ask NEW_PATH "Secret WebSocket path" "${PARSED_UPGRADE_PATH:-none}"
                [ "${NEW_PATH}" = "none" ] && NEW_PATH=""
                if [ "${NEW_PATH}" != "${PARSED_UPGRADE_PATH}" ]; then
                    PARSED_UPGRADE_PATH="${NEW_PATH}"
                    changed=true; success "Secret path updated."
                else
                    info "No changes."
                fi
                ;;
            6)
                ! $changed && { info "No changes to apply."; continue; }
                echo ""
                echo -e "${BOLD}─── New Configuration ────────────────────────────────${RESET}"
                show_client_state
                echo ""
                echo -e "  ExecStart:  ${CYAN}$(build_client_exec)${RESET}"
                echo ""
                confirm "Apply and restart service?" || continue
                echo ""
                write_client_service
                return
                ;;
            7)
                info "No changes applied."; return ;;
            *)
                warn "Please enter a number between 1 and 7." ;;
        esac
    done
}

# ─────────────────────────────────────────────
# flow_edit
# ─────────────────────────────────────────────
flow_edit() {
    declare -a FOUND_SVCS=()
    detect_services FOUND_SVCS

    local has_server=false has_client=false
    for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
        [[ "$svc" == *server* ]] && has_server=true
        [[ "$svc" == *client* ]] && has_client=true
    done

    # اگر سرویسی پیدا نشد، از کاربر بپرس
    if ! $has_server && ! $has_client; then
        echo ""
        warn "No wstunnel service files found — which VPS is this?"
        echo ""
        echo -e "  ${CYAN}1${RESET}) Iran VPS    — server (bind IP / wstunnel port)"
        echo -e "  ${CYAN}2${RESET}) Foreign VPS  — client (tunnel ports + domain)"
        echo ""
        local ch
        while true; do
            read -rp "$(echo -e "  ${BOLD}Enter 1 or 2${RESET}: ")" ch
            case "$ch" in
                1) edit_server; return ;;
                2) edit_client; return ;;
                *) warn "Please enter 1 or 2." ;;
            esac
        done
    fi

    if $has_server && $has_client; then
        echo ""
        echo -e "${BOLD}Both services found. Which to edit?${RESET}"
        echo ""
        echo -e "  ${CYAN}1${RESET}) Iran VPS   — wstunnel-server (bind IP / port)"
        echo -e "  ${CYAN}2${RESET}) Foreign VPS — wstunnel-client (ports + domain)"
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
    elif $has_server; then edit_server
    else edit_client
    fi
}

# ─────────────────────────────────────────────
# Update
# ─────────────────────────────────────────────
flow_update() {
    echo ""
    local bin
    bin=$(wstunnel_bin)
    if [ -n "$bin" ]; then
        info "Current version: $("$bin" --version 2>&1 | head -n1)  [$bin]"
    else
        warn "wstunnel binary not found — will install fresh."
    fi

    declare -a FOUND_SVCS=()
    detect_services FOUND_SVCS

    if [ ${#FOUND_SVCS[@]} -gt 0 ]; then
        echo -e "  Services found:"
        for svc in "${FOUND_SVCS[@]}"; do
            local st; st=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
            echo -e "    ${CYAN}${svc}${RESET}  [${st}]"
        done
    else
        warn "No service files found — binary will be updated but no services to restart."
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
    success "Update complete: $(/usr/local/bin/wstunnel --version 2>&1 | head -n1)"
}

# ─────────────────────────────────────────────
# Uninstall
# ─────────────────────────────────────────────
flow_uninstall() {
    echo ""
    declare -a FOUND_SVCS=()
    detect_services FOUND_SVCS

    local bin user_exists=false
    bin=$(wstunnel_bin)
    local binary_exists=false
    [ -n "$bin" ] && binary_exists=true
    id "wstunnel" &>/dev/null && user_exists=true

    if [ ${#FOUND_SVCS[@]} -eq 0 ] && ! $binary_exists && ! $user_exists; then
        info "Nothing to remove — wstunnel is not installed on this machine."; exit 0
    fi

    echo -e "${BOLD}─── Will be removed ───────────────────────────────────${RESET}"
    echo ""
    for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
        local st; st=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        echo -e "  ${CYAN}service${RESET}  /etc/systemd/system/${svc}  [${st}]"
    done
    $binary_exists && echo -e "  ${CYAN}binary${RESET}   ${bin}"
    $user_exists   && echo -e "  ${CYAN}user${RESET}     wstunnel  +  /home/wstunnel/"
    echo ""
    echo -e "  ${RED}All items above will be permanently removed.${RESET}"
    echo ""
    confirm "Are you sure?" || { info "Aborted."; exit 0; }
    echo ""

    for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
        info "Stopping and disabling ${svc} ..."
        systemctl stop    "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}"
        success "Removed /etc/systemd/system/${svc}"
    done
    if [ ${#FOUND_SVCS[@]} -gt 0 ]; then
        systemctl daemon-reload
        systemctl reset-failed 2>/dev/null || true
    fi

    if $binary_exists; then
        rm -f "$bin"
        success "Removed ${bin}"
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
        diagnose)  flow_diagnose  ;;
        edit)      flow_edit      ;;
        update)    flow_update    ;;
        uninstall) flow_uninstall ;;
    esac
}

main "$@"
