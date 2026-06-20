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
declare -a PARSED_DOMAINS=()

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

remove_caddyfile_domain() {
    local domain="$1"
    local caddyfile="/etc/caddy/Caddyfile"
    [ -f "$caddyfile" ] || return
    python3 - "$caddyfile" "$domain" <<'PYEOF'
import sys, re
path, domain = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.read().split('\n')
result = []
i = 0
dom_pat = re.compile(r'^' + re.escape(domain) + r'\s*\{')
while i < len(lines):
    if dom_pat.match(lines[i]):
        depth = lines[i].count('{') - lines[i].count('}')
        i += 1
        while i < len(lines) and depth > 0:
            depth += lines[i].count('{') - lines[i].count('}')
            i += 1
        if i < len(lines) and not lines[i].strip():
            i += 1
    else:
        result.append(lines[i])
        i += 1
output = '\n'.join(result).strip()
with open(path, 'w') as f:
    f.write(output + '\n' if output else '')
PYEOF
    success "Domain ${domain} removed from Caddyfile."
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
    PARSED_DOMAIN="" PARSED_WSS_PORT="443" PARSED_FLAGS=()
    if [ ! -f "$svc_file" ]; then
        warn "Client service file not found — some values will be empty"
        return
    fi
    local exec_line wss_url
    exec_line=$(grep "^ExecStart=" "$svc_file" | sed 's/^ExecStart=//')
    wss_url=$(echo "$exec_line" | grep -oE 'wss://[^[:space:]]+')
    PARSED_DOMAIN=$(echo "$wss_url"   | sed 's|wss://||' | sed 's|:[0-9]*$||')
    PARSED_WSS_PORT=$(echo "$wss_url" | grep -oE '[0-9]+$')
    [ -z "$PARSED_WSS_PORT" ] && PARSED_WSS_PORT="443"
    PARSED_FLAGS=()
    while IFS= read -r f; do
        [ -n "$f" ] && PARSED_FLAGS+=("$f")
    done < <(echo "$exec_line" | grep -oE 'tcp://[^[:space:]]+')
}

parse_server_service() {
    local svc_file="/etc/systemd/system/wstunnel-server.service"
    PARSED_BIND_IP="127.0.0.1" PARSED_BIND_PORT="2018"
    if [ ! -f "$svc_file" ]; then
        warn "Server service file not found — using default values for diagnostics"
        return
    fi
    local exec_line ws_url
    exec_line=$(grep "^ExecStart=" "$svc_file" | sed 's/^ExecStart=//')
    ws_url=$(echo "$exec_line" | grep -oE 'ws://[^[:space:]]+')
    PARSED_BIND_IP=$(echo "$ws_url"   | sed 's|ws://||' | sed 's|:[0-9]*$||')
    PARSED_BIND_PORT=$(echo "$ws_url" | grep -oE '[0-9]+$')
}

parse_server_domains() {
    PARSED_DOMAINS=()
    local caddyfile="/etc/caddy/Caddyfile"
    [ -f "$caddyfile" ] || return
    local bind_port="${PARSED_BIND_PORT:-2018}"
    while IFS= read -r d; do
        [ -n "$d" ] && PARSED_DOMAINS+=("$d")
    done < <(python3 - "$caddyfile" "$bind_port" <<'PYEOF'
import sys, re
path, port = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        lines = f.read().split('\n')
except Exception:
    sys.exit(0)
i = 0
while i < len(lines):
    m = re.match(r'^(\S+)\s*\{', lines[i])
    if m:
        domain = m.group(1)
        block = [lines[i]]
        depth = lines[i].count('{') - lines[i].count('}')
        i += 1
        while i < len(lines) and depth > 0:
            depth += lines[i].count('{') - lines[i].count('}')
            block.append(lines[i])
            i += 1
        if f'reverse_proxy localhost:{port}' in '\n'.join(block):
            print(domain)
    else:
        i += 1
PYEOF
)
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

show_server_state() {
    echo -e "  ${BOLD}wstunnel listens :${RESET}  ${YELLOW}ws://${PARSED_BIND_IP}:${PARSED_BIND_PORT}${RESET}"
    echo ""
    echo -e "  ${BOLD}Domains (Caddyfile):${RESET}"
    if [ ${#PARSED_DOMAINS[@]} -eq 0 ]; then
        echo -e "    ${YELLOW}(no domains configured)${RESET}"
    else
        for i in "${!PARSED_DOMAINS[@]}"; do
            echo -e "    ${CYAN}#$((i+1))${RESET}  ${PARSED_DOMAINS[$i]}  →  :443  →  localhost:${PARSED_BIND_PORT}"
        done
    fi
}

build_client_exec() {
    local result="/usr/local/bin/wstunnel client"
    result+=" --websocket-ping-frequency-sec 20"
    result+=" --connection-min-idle 3"
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
    systemctl enable wstunnel-client.service
    systemctl restart wstunnel-client.service
    echo ""
    systemctl status wstunnel-client.service --no-pager
    echo ""
    success "Service updated and restarted."
}

write_server_service() {
    local exec_flags="--websocket-ping-frequency-sec 20"

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
    systemctl enable wstunnel-server.service
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
        local caddyfile="/etc/caddy/Caddyfile"
        if "$cbin" validate --config "$caddyfile" &>/dev/null 2>&1; then
            check_ok "Caddyfile is valid"
        else
            check_fail "Caddyfile has errors — run: $cbin validate --config $caddyfile"
        fi
        # بررسی محتوای Caddyfile
        if [ -f "$caddyfile" ]; then
            if grep -q "respond 404" "$caddyfile" 2>/dev/null; then
                check_fail "Caddyfile has 'respond 404' — this blocks all wstunnel connections!"
                echo -e "         ${RED}Fix on Iran VPS:${RESET}"
                echo -e "         ${CYAN}cat > /etc/caddy/Caddyfile <<'EOF'${RESET}"
                echo -e "         ${CYAN}<your-domain> {${RESET}"
                echo -e "         ${CYAN}    header -Server${RESET}"
                echo -e "         ${CYAN}    reverse_proxy localhost:${PARSED_BIND_PORT}${RESET}"
                echo -e "         ${CYAN}}${RESET}"
                echo -e "         ${CYAN}EOF${RESET}"
                echo -e "         ${CYAN}systemctl reload caddy${RESET}"
            elif grep -q "reverse_proxy localhost:${PARSED_BIND_PORT}" "$caddyfile" 2>/dev/null; then
                check_ok "Caddyfile correctly proxies to localhost:${PARSED_BIND_PORT}"
            else
                check_warn "Caddyfile may not proxy to localhost:${PARSED_BIND_PORT}"
                echo -e "         ${YELLOW}→ cat /etc/caddy/Caddyfile${RESET}"
            fi
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

    # 8. بررسی مستقیم service file برای --restrict-to
    local svc_file="/etc/systemd/system/wstunnel-server.service"
    if [ -f "$svc_file" ] && grep -q -- '--restrict-to' "$svc_file"; then
        check_fail "--restrict-to found in service file — this BLOCKS all reverse tunnel (-R) connections"
        echo -e "         ${RED}wstunnel v10 --restrict-to only allows forward Tcp, not ReverseTcp.${RESET}"
        echo -e "         ${YELLOW}→ Fix now:${RESET}"
        echo -e "         ${CYAN}   sed -i 's/ --restrict-to [^ ]*//g' ${svc_file}${RESET}"
        echo -e "         ${CYAN}   systemctl daemon-reload && systemctl restart wstunnel-server.service${RESET}"
    fi

    # 9. بررسی لاگ برای خطاهای رایج
    local recent_logs
    recent_logs=$(journalctl -u wstunnel-server.service -n 30 --no-pager 2>/dev/null || true)

    if echo "$recent_logs" | grep -q "Rejecting connection with not allowed destination"; then
        check_fail "Recent logs confirm: reverse tunnel connections are being REJECTED"
        echo -e "         ${YELLOW}→ Run the fix above (remove --restrict-to) and restart service${RESET}"
    fi

    if echo "$recent_logs" | grep -q "Invalid protocol version"; then
        check_warn "Some non-WebSocket clients are connecting (normal — browsers/scanners)"
    fi

    echo ""
    echo -e "  ${BOLD}Last 15 log lines:${RESET}"
    echo "$recent_logs" | tail -15 | sed 's/^/    /'

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
    local wbin; wbin=$(wstunnel_bin)
    if [ -n "$wbin" ]; then
        check_ok "wstunnel binary: $("$wbin" --version 2>&1 | head -n1)  [$wbin]"
    else
        check_fail "wstunnel binary not found (checked /usr/local/bin and /usr/bin)"
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
    local http_code caddy_broken=false wstunnel_rejecting=false
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        --max-time 6 \
        "https://${PARSED_DOMAIN}:${PARSED_WSS_PORT}" 2>/dev/null || echo "000")
    case "$http_code" in
        "000")
            check_fail "Cannot reach https://${PARSED_DOMAIN}:${PARSED_WSS_PORT} (timeout/refused)"
            echo -e "         ${YELLOW}→ Is Caddy running on Iran VPS?${RESET}"
            echo -e "         ${YELLOW}→ Is port 443 open in Iran VPS firewall?${RESET}"
            echo -e "         ${YELLOW}→ Does DNS point to Iran VPS?${RESET}"
            ;;
        "400")
            check_fail "Iran VPS returns 400 — wstunnel is rejecting the WebSocket upgrade"
            echo -e "         ${RED}Most likely: --restrict-to or --restrict-http-upgrade-path-prefix flag on Iran VPS${RESET}"
            echo -e "         ${YELLOW}→ On Iran VPS remove --restrict-to:${RESET}"
            echo -e "         ${CYAN}   sed -i 's/ --restrict-to [^ ]*//g' /etc/systemd/system/wstunnel-server.service${RESET}"
            echo -e "         ${YELLOW}→ Also remove --restrict-http-upgrade-path-prefix if present:${RESET}"
            echo -e "         ${CYAN}   sed -i 's/ --restrict-http-upgrade-path-prefix [^ ]*//g' /etc/systemd/system/wstunnel-server.service${RESET}"
            echo -e "         ${CYAN}   systemctl daemon-reload && systemctl restart wstunnel-server.service${RESET}"
            wstunnel_rejecting=true
            ;;
        "404")
            check_fail "Iran VPS returns 404 — Caddyfile is misconfigured or has 'respond 404'"
            echo -e "         ${RED}Caddy is running but blocking WebSocket connections!${RESET}"
            echo -e "         ${YELLOW}→ On Iran VPS fix Caddyfile:${RESET}"
            echo -e "         ${CYAN}           reverse_proxy localhost:2018  (remove @ws and respond 404)${RESET}"
            echo -e "         ${YELLOW}→ Then: systemctl reload caddy${RESET}"
            caddy_broken=true
            ;;
        *)
            check_ok "Iran VPS reachable at https://${PARSED_DOMAIN}:${PARSED_WSS_PORT} (HTTP ${http_code})"
            ;;
    esac

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
    if $caddy_broken; then
        echo -e "  ${RED}Root cause: Caddyfile on Iran VPS is returning 404.${RESET}"
        echo -e "  wstunnel cannot connect because Caddy rejects all requests."
        echo ""
        echo -e "  ${YELLOW}Fix on Iran VPS:${RESET}"
        echo -e "  ${CYAN}cat > /etc/caddy/Caddyfile <<'EOF'${RESET}"
        echo -e "  ${CYAN}<your-domain> { header -Server; reverse_proxy localhost:2018 }${RESET}"
        echo -e "  ${CYAN}EOF${RESET}"
        echo -e "  ${CYAN}systemctl reload caddy${RESET}"
    elif $wstunnel_rejecting; then
        echo -e "  ${RED}Root cause: wstunnel server on Iran VPS returning HTTP 400.${RESET}"
        echo -e "  The WebSocket handshake is being rejected — likely --restrict-to"
        echo -e "  is blocking ReverseTcp connections."
        echo ""
        echo -e "  ${YELLOW}Fix on Iran VPS:${RESET}"
        echo -e "  ${CYAN}sed -i 's/ --restrict-to [^ ]*//g' /etc/systemd/system/wstunnel-server.service${RESET}"
        echo -e "  ${CYAN}systemctl daemon-reload && systemctl restart wstunnel-server.service${RESET}"
    elif $any_missing; then
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
    echo -e "${BOLD}─── Caddy / Domains ───────────────────────────────────${RESET}"
    echo -e "  ${YELLOW}Each domain must have a DNS A record pointing to this Iran VPS IP.${RESET}"
    echo -e "  ${YELLOW}You can add multiple domains for domain rotation or multi-location.${RESET}"
    echo ""

    PARSED_DOMAINS=()
    local count=0
    while true; do
        count=$((count + 1))
        ask NEW_DOMAIN "Domain #${count} (e.g. tunnel.example.com)" ""
        PARSED_DOMAINS+=("${NEW_DOMAIN}")
        echo ""
        confirm "Add another domain?" || break
        echo ""
    done

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━  Summary  ━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Mode             :  ${GREEN}Iran VPS — Server${RESET}"
    echo -e "  wstunnel version :  ${YELLOW}${WSTUNNEL_VERSION}${RESET}"
    echo ""
    show_server_state
    echo ""
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
    for dom in "${PARSED_DOMAINS[@]+"${PARSED_DOMAINS[@]}"}"; do
        configure_caddyfile "$dom" "$PARSED_BIND_PORT"
    done

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
    parse_server_domains
    local changed=false
    local old_ip="${PARSED_BIND_IP}" old_port="${PARSED_BIND_PORT}"
    local -a DOMAINS_TO_REMOVE=()

    while true; do
        echo ""
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━  Edit Server  ━━━━━━━━━━━━━━━━━━━${RESET}"
        show_server_state
        echo ""
        echo -e "${BOLD}─── Options ───────────────────────────────────────────${RESET}"
        echo -e "  ${CYAN}1${RESET}) Add domain"
        echo -e "  ${CYAN}2${RESET}) Remove domain"
        echo -e "  ${CYAN}3${RESET}) Change bind IP / port"
        echo -e "  ${CYAN}4${RESET}) Apply changes"
        echo -e "  ${CYAN}5${RESET}) Cancel"
        echo ""

        local choice
        read -rp "$(echo -e "  ${BOLD}Enter 1-5${RESET}: ")" choice

        case "$choice" in
            1)
                echo ""
                ask NEW_DOMAIN "New domain (e.g. tunnel2.example.com)" ""
                local dup=false
                for d in "${PARSED_DOMAINS[@]+"${PARSED_DOMAINS[@]}"}"; do
                    [ "$d" = "${NEW_DOMAIN}" ] && dup=true && break
                done
                if $dup; then
                    warn "Domain ${NEW_DOMAIN} is already configured."
                else
                    PARSED_DOMAINS+=("${NEW_DOMAIN}")
                    changed=true
                    success "Domain ${NEW_DOMAIN} added (apply to save)."
                fi
                ;;
            2)
                [ ${#PARSED_DOMAINS[@]} -eq 0 ] && { warn "No domains configured."; continue; }
                echo ""
                echo -e "  Which domain to remove?"
                for i in "${!PARSED_DOMAINS[@]}"; do
                    echo -e "    ${CYAN}$((i+1))${RESET}  ${PARSED_DOMAINS[$i]}"
                done
                echo ""
                local r_idx
                read -rp "$(echo -e "  ${BOLD}Enter number${RESET}: ")" r_idx
                if [[ "$r_idx" =~ ^[0-9]+$ ]] && (( r_idx >= 1 && r_idx <= ${#PARSED_DOMAINS[@]} )); then
                    local rm_dom="${PARSED_DOMAINS[$((r_idx-1))]}"
                    DOMAINS_TO_REMOVE+=("$rm_dom")
                    local nf=()
                    for j in "${!PARSED_DOMAINS[@]}"; do
                        [ "$j" -ne "$((r_idx-1))" ] && nf+=("${PARSED_DOMAINS[$j]}")
                    done
                    PARSED_DOMAINS=()
                    for f in "${nf[@]+"${nf[@]}"}"; do PARSED_DOMAINS+=("$f"); done
                    changed=true
                    success "Domain ${rm_dom} will be removed on apply."
                else
                    warn "Invalid selection."
                fi
                ;;
            3)
                echo ""
                ask NEW_BIND_IP   "Bind IP"   "${PARSED_BIND_IP}"
                ask NEW_BIND_PORT "Bind port" "${PARSED_BIND_PORT}"
                if [ "${NEW_BIND_IP}" != "${PARSED_BIND_IP}" ] || [ "${NEW_BIND_PORT}" != "${PARSED_BIND_PORT}" ]; then
                    PARSED_BIND_IP="${NEW_BIND_IP}"
                    PARSED_BIND_PORT="${NEW_BIND_PORT}"
                    changed=true
                    success "Bind address updated (apply to save)."
                else
                    info "No changes."
                fi
                ;;
            4)
                ! $changed && { info "No changes to apply."; continue; }
                echo ""
                echo -e "${BOLD}─── New Configuration ─────────────────────────────────${RESET}"
                show_server_state
                echo ""
                confirm "Apply changes?" || continue
                echo ""

                # wstunnel service — only restart if bind address changed
                if [ "${PARSED_BIND_IP}" != "${old_ip}" ] || [ "${PARSED_BIND_PORT}" != "${old_port}" ]; then
                    write_server_service
                fi

                # Caddyfile — update all remaining domains (handles port change + new domains)
                for dom in "${PARSED_DOMAINS[@]+"${PARSED_DOMAINS[@]}"}"; do
                    configure_caddyfile "$dom" "${PARSED_BIND_PORT}"
                done
                # Remove deleted domains from Caddyfile
                for dom in "${DOMAINS_TO_REMOVE[@]+"${DOMAINS_TO_REMOVE[@]}"}"; do
                    remove_caddyfile_domain "$dom"
                done

                local cbin; cbin=$(caddy_bin)
                if [ -n "$cbin" ]; then
                    systemctl reload caddy && success "Caddy reloaded."
                else
                    warn "Caddy binary not found — reload manually: systemctl reload caddy"
                fi
                return
                ;;
            5)
                info "No changes applied."; return ;;
            *)
                warn "Please enter a number between 1 and 5." ;;
        esac
    done
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
        echo -e "  ${CYAN}5${RESET}) Apply changes and restart service"
        echo -e "  ${CYAN}6${RESET}) Cancel (discard all changes)"
        echo ""

        local choice
        read -rp "$(echo -e "  ${BOLD}Enter 1-6${RESET}: ")" choice

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
                ! $changed && { info "No changes to apply."; continue; }
                if [ ${#PARSED_FLAGS[@]} -eq 0 ]; then
                    warn "No port mappings configured — wstunnel will start with no -R flags."
                    confirm "Apply anyway?" || continue
                fi
                echo ""
                echo -e "${BOLD}─── New Configuration ────────────────────────────────${RESET}"
                show_client_state
                echo ""
                echo -e "  ExecStart:  ${CYAN}$(build_client_exec)${RESET}"
                echo ""
                confirm "Apply and restart service?" || continue
                echo ""
                write_client_service
                if [ ${#PARSED_FLAGS[@]} -gt 0 ]; then
                    echo ""
                    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━  Reminders  ━━━━━━━━━━━━━━━━━━━━${RESET}"
                    echo -e "  ${YELLOW}Ensure these ports are open in Iran VPS firewall:${RESET}"
                    for flag in "${PARSED_FLAGS[@]+"${PARSED_FLAGS[@]}"}"; do
                        local addr="${flag#tcp://}"
                        local bp; bp=$(echo "$addr" | cut -d: -f2)
                        echo -e "    ${CYAN}sudo ufw allow ${bp}/tcp${RESET}   (on Iran VPS)"
                    done
                    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
                fi
                return
                ;;
            6)
                info "No changes applied."; return ;;
            *)
                warn "Please enter a number between 1 and 6." ;;
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

    # ── wstunnel detection ──────────────────────
    local wbin; wbin=$(wstunnel_bin)
    local wstunnel_bin_exists=false; [ -n "$wbin" ] && wstunnel_bin_exists=true
    local wstunnel_user_exists=false; id "wstunnel" &>/dev/null && wstunnel_user_exists=true

    # Detect if this is an Iran VPS (server) install
    local has_server=false
    for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
        [[ "$svc" == *server* ]] && has_server=true
    done

    # Read server config NOW (before service files are deleted)
    local saved_bind_port="2018"
    if $has_server; then
        parse_server_service
        saved_bind_port="${PARSED_BIND_PORT:-2018}"
    fi

    # ── Caddy detection ─────────────────────────
    # Binary-install marker : /usr/local/bin/caddy + /etc/systemd/system/caddy.service (we wrote both)
    # Apt-install marker    : /etc/apt/sources.list.d/caddy-stable.list (we added this)
    # Pre-existing Caddy    : caddy binary present but none of our markers
    local caddy_ours_binary=false caddy_ours_apt=false caddy_preexisting=false
    if $has_server; then
        if [ -x "/usr/local/bin/caddy" ] && [ -f "/etc/systemd/system/caddy.service" ]; then
            caddy_ours_binary=true
        elif [ -f "/etc/apt/sources.list.d/caddy-stable.list" ]; then
            caddy_ours_apt=true
        elif [ -n "$(caddy_bin)" ]; then
            caddy_preexisting=true
        fi
    fi

    # ── Nothing to do? ──────────────────────────
    if [ ${#FOUND_SVCS[@]} -eq 0 ] && ! $wstunnel_bin_exists && ! $wstunnel_user_exists \
        && ! $caddy_ours_binary && ! $caddy_ours_apt; then
        info "Nothing to remove — wstunnel is not installed on this machine."; exit 0
    fi

    # ── Preview ─────────────────────────────────
    echo -e "${BOLD}─── Will be removed ───────────────────────────────────${RESET}"
    echo ""
    for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
        local st; st=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        echo -e "  ${CYAN}wstunnel service${RESET}  /etc/systemd/system/${svc}  [${st}]"
    done
    $wstunnel_bin_exists  && echo -e "  ${CYAN}wstunnel binary${RESET}   ${wbin}"
    $wstunnel_user_exists && echo -e "  ${CYAN}wstunnel user${RESET}     wstunnel  +  /home/wstunnel/"

    if $caddy_ours_binary; then
        local cst; cst=$(systemctl is-active caddy 2>/dev/null || echo "inactive")
        echo -e "  ${CYAN}Caddy service${RESET}     /etc/systemd/system/caddy.service  [${cst}]"
        echo -e "  ${CYAN}Caddy binary${RESET}      /usr/local/bin/caddy"
        echo -e "  ${CYAN}Caddy user${RESET}        caddy  +  /var/lib/caddy/  /var/log/caddy/"
        echo -e "  ${CYAN}Caddy config${RESET}      /etc/caddy/"
    elif $caddy_ours_apt; then
        local cst; cst=$(systemctl is-active caddy 2>/dev/null || echo "inactive")
        echo -e "  ${CYAN}Caddy package${RESET}     caddy (apt remove --purge)  [${cst}]"
        echo -e "  ${CYAN}Caddy config${RESET}      /etc/caddy/"
        echo -e "  ${CYAN}Caddy apt repo${RESET}    /etc/apt/sources.list.d/caddy-stable.list"
        echo -e "  ${CYAN}              ${RESET}    /usr/share/keyrings/caddy-stable-archive-keyring.gpg"
    elif $caddy_preexisting; then
        echo -e "  ${YELLOW}Caddy pre-existed — only our reverse_proxy block will be removed from Caddyfile${RESET}"
    fi
    echo ""
    echo -e "  ${RED}All items above will be permanently removed.${RESET}"
    echo ""
    confirm "Are you sure?" || { info "Aborted."; exit 0; }
    echo ""

    # ── 1. wstunnel services ────────────────────
    for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
        info "Stopping and disabling ${svc} ..."
        systemctl stop    "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}"
        success "Removed /etc/systemd/system/${svc}"
    done

    # ── 2. Caddy ────────────────────────────────
    if $caddy_ours_binary; then
        info "Removing Caddy (binary install)..."
        systemctl stop    caddy 2>/dev/null || true
        systemctl disable caddy 2>/dev/null || true
        rm -f /etc/systemd/system/caddy.service
        rm -f /usr/local/bin/caddy
        rm -rf /etc/caddy /var/lib/caddy /var/log/caddy
        if id caddy &>/dev/null; then
            userdel caddy 2>/dev/null || true
        fi
        if getent group caddy &>/dev/null; then
            groupdel caddy 2>/dev/null || true
        fi
        # Clean up any leftover apt repo files from failed apt attempt
        rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
              /etc/apt/sources.list.d/caddy-stable.list
        success "Caddy removed completely."

    elif $caddy_ours_apt; then
        info "Removing Caddy (apt)..."
        apt-get remove --purge -y caddy 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
        rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
              /etc/apt/sources.list.d/caddy-stable.list
        rm -rf /etc/caddy
        success "Caddy removed via apt."

    elif $caddy_preexisting; then
        # Caddy was pre-existing — only remove the block we added to Caddyfile
        info "Removing our domain block from Caddyfile..."
        local caddyfile="/etc/caddy/Caddyfile"
        if [ -f "$caddyfile" ]; then
            python3 - "$caddyfile" "$saved_bind_port" <<'PYEOF'
import sys
path, port = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.read().split('\n')
result = []
i = 0
while i < len(lines):
    # detect start of a top-level block
    if lines[i] and lines[i][0] not in (' ', '\t', '#', '}') and '{' in lines[i]:
        block = [lines[i]]
        depth = lines[i].count('{') - lines[i].count('}')
        i += 1
        while i < len(lines) and depth > 0:
            depth += lines[i].count('{') - lines[i].count('}')
            block.append(lines[i])
            i += 1
        # skip block if it contains our reverse_proxy line
        if any(f'reverse_proxy localhost:{port}' in ln for ln in block):
            pass
        else:
            result.extend(block)
    else:
        result.append(lines[i])
        i += 1
output = '\n'.join(result).strip()
with open(path, 'w') as f:
    f.write(output + '\n' if output else '')
PYEOF
            local cbin; cbin=$(caddy_bin)
            if [ -n "$cbin" ]; then
                systemctl reload caddy 2>/dev/null || true
                success "Domain block removed; Caddy reloaded."
            else
                success "Domain block removed from Caddyfile."
            fi
        fi
    fi

    # ── 3. systemctl reload ─────────────────────
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    # ── 4. wstunnel binary ──────────────────────
    if $wstunnel_bin_exists; then
        rm -f "$wbin"
        success "Removed ${wbin}"
    fi

    # ── 5. wstunnel user ────────────────────────
    if $wstunnel_user_exists; then
        rm -rf /home/wstunnel
        userdel wstunnel 2>/dev/null || true
        success "Removed user 'wstunnel' and /home/wstunnel/"
    fi

    echo ""
    success "wstunnel and all related components removed from this machine."
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
