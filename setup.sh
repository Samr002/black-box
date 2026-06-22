#!/bin/bash
# WStunnel + Caddy — Unified Setup Script
# Traffic flow (-R reverse tunnel):
#   User → Iran VPS:PORT → WSS tunnel → Foreign VPS:PORT (VPN service lives here)

set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/Samr002/black-box/main/setup.sh"
WS_BIN="/usr/local/bin/ws"

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

_show_header() {
    clear
    echo ""
    echo -e "${BOLD}╔═════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║         WStunnel + Caddy — Interactive Setup        ║${RESET}"
    echo -e "${BOLD}╚═════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

_press_enter() {
    echo ""
    read -rp "$(echo -e "  ${BOLD}Press Enter to return to main menu...${RESET}")"
}
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
PARSED_UPGRADE_PATH=""

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
    echo -e "  ${CYAN}6${RESET}) ${BOLD}Restart${RESET}   — manually restart all tunnel services"
    echo -e "  ${CYAN}7${RESET}) ${BOLD}Uninstall${RESET} — remove wstunnel completely from this machine"
    echo -e "  ${CYAN}8${RESET}) ${BOLD}Exit${RESET}"
    echo ""
    while true; do
        read -rp "$(echo -e "  ${BOLD}Enter 1-8${RESET}: ")" choice
        case "$choice" in
            1) printf -v "$varname" 'server';    return ;;
            2) printf -v "$varname" 'client';    return ;;
            3) printf -v "$varname" 'diagnose';  return ;;
            4) printf -v "$varname" 'edit';      return ;;
            5) printf -v "$varname" 'update';    return ;;
            6) printf -v "$varname" 'restart';   return ;;
            7) printf -v "$varname" 'uninstall'; return ;;
            8) echo ""; info "Goodbye."; exit 0 ;;
            *) warn "  Please enter a number between 1 and 8." ;;
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

# تولید path تصادفی شبیه API واقعی برای obfuscation
gen_upgrade_path() {
    local seg1 seg2 hex
    local segs1=("api" "v1" "v2" "app" "ws" "live" "svc" "net")
    local segs2=("stream" "connect" "socket" "data" "relay" "pipe" "link" "sync")
    seg1="${segs1[$((RANDOM % ${#segs1[@]}))]}"
    seg2="${segs2[$((RANDOM % ${#segs2[@]}))]}"
    hex=$(printf '%06x' $((RANDOM * RANDOM % 16777216)))
    echo "/${seg1}/${seg2}/${hex}"
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
    local domain="$1" port="$2" upgrade_path="${3:-}"
    local caddyfile="/etc/caddy/Caddyfile"

    mkdir -p "$(dirname "$caddyfile")"

    local global_block
    global_block='{
    servers {
        protocols h1
        enable_full_duplex
        timeouts {
            read_header 10s
            idle        0
        }
    }
}'

    local block
    if [ -n "$upgrade_path" ]; then
        # Path obfuscation: Caddy only accepts WebSocket upgrades to the secret path.
        # wstunnel must NOT use --restrict-http-upgrade-path-prefix — it breaks ReverseTcp.
        block="${domain} {
    tls internal
    header -Server
    @wstunnel {
        path ${upgrade_path}*
        header Connection *Upgrade*
        header Upgrade websocket
    }
    reverse_proxy @wstunnel 127.0.0.1:${port} {
        flush_interval -1
        transport http {
            response_header_timeout 0
        }
    }
    respond 404
}"
    else
        block="${domain} {
    tls internal
    header -Server
    reverse_proxy 127.0.0.1:${port} {
        flush_interval -1
        transport http {
            response_header_timeout 0
        }
    }
}"
    fi

    if [ ! -f "$caddyfile" ] || [ ! -s "$caddyfile" ]; then
        # فایل وجود ندارد یا خالی است — از صفر بنویس
        printf '%s\n\n%s\n' "$global_block" "$block" > "$caddyfile"
        success "Caddyfile created with domain ${domain}."
    elif grep -qF "${domain} {" "$caddyfile" 2>/dev/null; then
        # بلاک این دامنه از قبل وجود دارد — با block جدید جایگزین کن
        info "Updating ${domain} in Caddyfile..."
        local _block_tmp; _block_tmp=$(mktemp)
        printf '%s\n' "$block" > "$_block_tmp"
        python3 - "$caddyfile" "$domain" "$_block_tmp" <<'PYEOF'
import sys, re
cfile, domain, block_file = sys.argv[1], sys.argv[2], sys.argv[3]
with open(block_file) as f:
    new_block_lines = f.read().rstrip('\n').split('\n')
with open(cfile) as f:
    lines = f.read().split('\n')
result = []
i = 0
replaced = False
dom_pat = re.compile(r'^' + re.escape(domain) + r'\s*\{')
while i < len(lines):
    if not replaced and dom_pat.match(lines[i]):
        depth = lines[i].count('{') - lines[i].count('}')
        i += 1
        while i < len(lines) and depth > 0:
            depth += lines[i].count('{') - lines[i].count('}')
            i += 1
        result.extend(new_block_lines)
        replaced = True
    else:
        result.append(lines[i])
        i += 1
if not replaced:
    result.extend([''] + new_block_lines)
output = '\n'.join(result)
if not output.endswith('\n'):
    output += '\n'
with open(cfile, 'w') as f:
    f.write(output)
PYEOF
        rm -f "$_block_tmp"
        success "Caddyfile updated for ${domain}."
    else
        # فایل وجود دارد و دامنه دیگری دارد — اضافه کن
        # اطمینان از وجود global block
        if ! grep -q 'enable_full_duplex' "$caddyfile" 2>/dev/null; then
            printf '%s\n\n' "$global_block" | cat - "$caddyfile" > "${caddyfile}.tmp" && mv "${caddyfile}.tmp" "$caddyfile"
        fi
        printf '\n%s\n' "$block" >> "$caddyfile"
        success "Domain ${domain} added to Caddyfile."
    fi

    # اعتبارسنجی کانفیگ
    local cbin; cbin=$(caddy_bin)
    if [ -n "$cbin" ]; then
        if "$cbin" validate --config "$caddyfile" &>/dev/null 2>&1; then
            success "Caddyfile is valid."
        else
            warn "Caddyfile validation failed — check: $cbin validate --config $caddyfile"
        fi
    fi
}

remove_caddyfile_domain() {
    local domain="$1"
    local caddyfile="/etc/caddy/Caddyfile"
    [ -f "$caddyfile" ] || return
    # اگه دامنه اصلاً در فایل نیست، کاری نکن
    if ! grep -qF "${domain} {" "$caddyfile" 2>/dev/null; then
        info "Domain ${domain} not found in Caddyfile — nothing to remove."
        return
    fi
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
        # Consume the entire block
        depth = lines[i].count('{') - lines[i].count('}')
        i += 1
        while i < len(lines) and depth > 0:
            depth += lines[i].count('{') - lines[i].count('}')
            i += 1
        # Skip one blank line after the block (separator)
        if i < len(lines) and not lines[i].strip():
            i += 1
    else:
        result.append(lines[i])
        i += 1
# Strip trailing blank lines, write clean file
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
    PARSED_DOMAIN="" PARSED_WSS_PORT="443" PARSED_FLAGS=() PARSED_UPGRADE_PATH=""
    if [ ! -f "$svc_file" ]; then
        warn "Client service file not found — some values will be empty"
        return
    fi
    local exec_line wss_url host_port
    exec_line=$(grep "^ExecStart=" "$svc_file" | sed 's/^ExecStart=//')
    wss_url=$(echo "$exec_line" | grep -oE 'wss://[^[:space:]]+')
    # Extract host:port separately from path to avoid port regex matching path digits
    host_port=$(echo "$wss_url" | sed 's|wss://||' | cut -d'/' -f1)
    PARSED_DOMAIN=$(echo "$host_port" | cut -d':' -f1)
    PARSED_WSS_PORT=$(echo "$host_port" | cut -d':' -f2)
    [ -z "$PARSED_WSS_PORT" ] && PARSED_WSS_PORT="443"
    # Path comes from --http-upgrade-path-prefix flag (not the URL path)
    PARSED_UPGRADE_PATH=$(echo "$exec_line" | sed -n 's/.*--http-upgrade-path-prefix \([^ ]*\).*/\1/p')
    PARSED_FLAGS=()
    while IFS= read -r f; do
        [ -n "$f" ] && PARSED_FLAGS+=("$f")
    done < <(echo "$exec_line" | grep -oE 'tcp://[^[:space:]]+')
}

parse_server_service() {
    local svc_file="/etc/systemd/system/wstunnel-server.service"
    PARSED_BIND_IP="127.0.0.1" PARSED_BIND_PORT="2018" PARSED_UPGRADE_PATH=""
    if [ ! -f "$svc_file" ]; then
        warn "Server service file not found — using default values for diagnostics"
        return
    fi
    local exec_line ws_url
    exec_line=$(grep "^ExecStart=" "$svc_file" | sed 's/^ExecStart=//')
    ws_url=$(echo "$exec_line" | grep -oE 'ws://[^[:space:]]+')
    PARSED_BIND_IP=$(echo "$ws_url"   | sed 's|ws://||' | sed 's|:[0-9]*$||')
    PARSED_BIND_PORT=$(echo "$ws_url" | grep -oE '[0-9]+$')
    # Path restriction lives in Caddyfile (@wstunnel path matcher), not in wstunnel flags
    local _caddyfile="/etc/caddy/Caddyfile"
    PARSED_UPGRADE_PATH=""
    [ -f "$_caddyfile" ] && \
        PARSED_UPGRADE_PATH=$(sed -n 's/[[:space:]]*path \(\/[^* ]*\)\*.*/\1/p' "$_caddyfile" | head -1)
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
        block_text = '\n'.join(block)
        if re.search(r'(?:localhost|127\.0\.0\.1):' + re.escape(port) + r'(?:\s|{|}|$)', block_text):
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
    if [ -n "${PARSED_UPGRADE_PATH:-}" ]; then
        echo -e "  ${BOLD}Upgrade path    :${RESET}  ${GREEN}${PARSED_UPGRADE_PATH}${RESET}  ${CYAN}(obfuscation active)${RESET}"
    else
        echo -e "  ${BOLD}Upgrade path    :${RESET}  ${YELLOW}(none — obfuscation disabled)${RESET}"
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

show_server_state() {
    echo -e "  ${BOLD}wstunnel listens :${RESET}  ${YELLOW}ws://${PARSED_BIND_IP}:${PARSED_BIND_PORT}${RESET}"
    if [ -n "${PARSED_UPGRADE_PATH:-}" ]; then
        echo -e "  ${BOLD}Upgrade path     :${RESET}  ${GREEN}${PARSED_UPGRADE_PATH}${RESET}  ${CYAN}(obfuscation active)${RESET}"
    else
        echo -e "  ${BOLD}Upgrade path     :${RESET}  ${YELLOW}(none — obfuscation disabled)${RESET}"
    fi
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
    result+=" --websocket-ping-frequency-sec 30"
    result+=" --connection-min-idle 5"
    result+=" --dns-resolver dns://1.1.1.1"
    result+=" --http-headers \"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36\""
    result+=" --http-headers \"Origin: https://${PARSED_DOMAIN}\""
    for flag in "${PARSED_FLAGS[@]+"${PARSED_FLAGS[@]}"}"; do
        result+=" -R ${flag}"
    done
    # wstunnel v10 client ignores URL path — must use --http-upgrade-path-prefix flag
    [ -n "${PARSED_UPGRADE_PATH:-}" ] && result+=" --http-upgrade-path-prefix ${PARSED_UPGRADE_PATH}"
    local wss_url="wss://${PARSED_DOMAIN}:${PARSED_WSS_PORT}"
    result+=" ${wss_url}"
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
RestartSec=20
LimitNOFILE=65536
TasksMax=65536
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
    local exec_flags="--websocket-ping-frequency-sec 30"
    # Path restriction is handled by Caddy, not wstunnel — --restrict-http-upgrade-path-prefix
    # breaks ReverseTcp connections in wstunnel v10, so path routing lives in the Caddyfile.

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
RestartSec=5
LimitNOFILE=65536
TasksMax=65536
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
# Scheduled restart timer helpers
# ─────────────────────────────────────────────
get_restart_interval() {
    local type="$1"
    local tfile="/etc/systemd/system/wstunnel-${type}-restart.timer"
    if [ -f "$tfile" ]; then
        local h; h=$(grep "^OnUnitActiveSec=" "$tfile" 2>/dev/null | grep -oE '[0-9]+' | head -1)
        echo "${h:-0}"
    else
        echo "0"
    fi
}

ask_restart_interval() {
    local varname="$1" current="${2:-0}"
    echo ""
    echo -e "  ${BOLD}Scheduled auto-restart interval${RESET}  (current: ${YELLOW}${current}h${RESET}):"
    echo -e "    ${CYAN}0${RESET}   Disabled"
    echo -e "    ${CYAN}1${RESET}   Every  1 hour"
    echo -e "    ${CYAN}2${RESET}   Every  2 hours"
    echo -e "    ${CYAN}3${RESET}   Every  3 hours"
    echo -e "    ${CYAN}4${RESET}   Every  4 hours"
    echo -e "    ${CYAN}6${RESET}   Every  6 hours"
    echo -e "    ${CYAN}8${RESET}   Every  8 hours"
    echo -e "    ${CYAN}12${RESET}  Every 12 hours"
    echo ""
    local val
    while true; do
        read -rp "$(echo -e "  ${BOLD}Enter 0/1/2/3/4/6/8/12${RESET}: ")" val
        case "$val" in
            0|1|2|3|4|6|8|12) printf -v "$varname" '%s' "$val"; return ;;
            *) warn "Please enter one of: 0 1 2 3 4 6 8 12" ;;
        esac
    done
}

write_restart_timer() {
    local type="$1" hours="$2"
    local svc_name="wstunnel-${type}"
    local timer_name="wstunnel-${type}-restart"
    local label; [ "$type" = "server" ] && label="Server" || label="Client"

    info "Writing ${timer_name}.service ..."
    cat > "/etc/systemd/system/${timer_name}.service" <<EOF
[Unit]
Description=WStunnel ${label} Scheduled Restart
After=${svc_name}.service

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart ${svc_name}.service
EOF

    info "Writing ${timer_name}.timer (every ${hours}h) ..."
    cat > "/etc/systemd/system/${timer_name}.timer" <<EOF
[Unit]
Description=WStunnel ${label} Restart every ${hours}h

[Timer]
OnBootSec=${hours}h
OnUnitActiveSec=${hours}h
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable "${timer_name}.timer"
    systemctl start  "${timer_name}.timer"
    success "Restart timer enabled: every ${hours} hour(s)."
    echo -e "  ${YELLOW}Check: systemctl status ${timer_name}.timer${RESET}"
}

remove_restart_timer() {
    local type="$1"
    local timer_name="wstunnel-${type}-restart"
    if [ -f "/etc/systemd/system/${timer_name}.timer" ]; then
        systemctl stop    "${timer_name}.timer" 2>/dev/null || true
        systemctl disable "${timer_name}.timer" 2>/dev/null || true
        rm -f "/etc/systemd/system/${timer_name}.timer"
        rm -f "/etc/systemd/system/${timer_name}.service"
        systemctl daemon-reload
        success "Restart timer disabled and removed."
    else
        info "No restart timer configured."
    fi
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
            elif grep -qE "(localhost|127\.0\.0\.1):${PARSED_BIND_PORT}" "$caddyfile" 2>/dev/null; then
                check_ok "Caddyfile correctly proxies to :${PARSED_BIND_PORT}"
            else
                check_warn "Caddyfile may not proxy to :${PARSED_BIND_PORT}"
                echo -e "         ${YELLOW}→ cat /etc/caddy/Caddyfile${RESET}"
            fi
        fi
    else
        check_fail "Caddy is NOT installed"
        echo -e "         ${YELLOW}→ Run Install (option 1) to install Caddy automatically${RESET}"
    fi

    # 7. Multi-domain DNS check
    parse_server_domains
    echo ""
    echo -e "  ${BOLD}Configured Domains (${#PARSED_DOMAINS[@]}):${RESET}"
    if [ ${#PARSED_DOMAINS[@]} -eq 0 ]; then
        check_warn "No domains found in Caddyfile routing to localhost:${PARSED_BIND_PORT}"
        echo -e "         ${YELLOW}→ Run Install or Edit → Add domain to configure${RESET}"
    else
        for _dom in "${PARSED_DOMAINS[@]}"; do
            local _ip=""
            if _ip=$(getent hosts "$_dom" 2>/dev/null | awk '{print $1}' | head -1) && [ -n "$_ip" ]; then
                check_ok "DNS: ${_dom}  →  ${_ip}"
            else
                check_fail "DNS: ${_dom}  →  cannot resolve (A record missing or not propagated)"
                echo -e "         ${YELLOW}→ Point ${_dom} A record to this server's IP${RESET}"
            fi
        done
    fi

    # 8. Restart timer
    echo ""
    echo -e "  ${BOLD}Scheduled Restart Timer:${RESET}"
    local _srv_h; _srv_h=$(get_restart_interval "server")
    if [ "$_srv_h" != "0" ]; then
        if systemctl is-active "wstunnel-server-restart.timer" &>/dev/null; then
            local _next; _next=$(systemctl list-timers "wstunnel-server-restart.timer" --no-pager 2>/dev/null \
                | awk 'NR==2 {print $1, $2}' || echo "unknown")
            check_ok "Timer active — restarts every ${_srv_h}h  (next: ${_next})"
        else
            check_warn "Timer configured (${_srv_h}h) but NOT active"
            echo -e "         ${YELLOW}→ sudo systemctl start wstunnel-server-restart.timer${RESET}"
        fi
    else
        check_warn "No scheduled restart timer — consider enabling via Edit → option 4"
    fi

    # 9. ws shortcut
    echo ""
    echo -e "  ${BOLD}ws Command:${RESET}"
    if [ -f "$WS_BIN" ] && [ -x "$WS_BIN" ]; then
        check_ok "'ws' shortcut installed at ${WS_BIN}  (type 'ws' to relaunch)"
    else
        check_warn "'ws' shortcut not found — run Update (option 5) to install it"
    fi

    # 10. Firewall — check if common tools exist and show status
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

    # 11. بررسی مستقیم service file برای flags ناسازگار با ReverseTcp
    local svc_file="/etc/systemd/system/wstunnel-server.service"
    if [ -f "$svc_file" ] && grep -q -- '--restrict-to' "$svc_file"; then
        check_fail "--restrict-to found in service file — this BLOCKS all reverse tunnel (-R) connections"
        echo -e "         ${RED}wstunnel v10 --restrict-to blocks ALL ReverseTcp regardless of destination.${RESET}"
        echo -e "         ${YELLOW}→ Fix now:${RESET}"
        echo -e "         ${CYAN}   sed -i 's/ --restrict-to [^ ]*//g' ${svc_file}${RESET}"
        echo -e "         ${CYAN}   systemctl daemon-reload && systemctl restart wstunnel-server.service${RESET}"
    fi
    if [ -f "$svc_file" ] && grep -q -- '--restrict-http-upgrade-path-prefix' "$svc_file"; then
        check_fail "--restrict-http-upgrade-path-prefix in wstunnel service — also BLOCKS ReverseTcp in v10"
        echo -e "         ${RED}Path restriction must be done in Caddy, not wstunnel (wstunnel flag breaks -R).${RESET}"
        echo -e "         ${YELLOW}→ Fix now:${RESET}"
        echo -e "         ${CYAN}   sed -i 's/ --restrict-http-upgrade-path-prefix [^ ]*//g' ${svc_file}${RESET}"
        echo -e "         ${CYAN}   systemctl daemon-reload && systemctl restart wstunnel-server.service${RESET}"
    fi

    # 12. Multi-location: نمایش پورت‌های -R باز شده توسط کلاینت‌ها
    echo ""
    echo -e "  ${BOLD}Reverse Tunnel Ports (opened by Foreign VPS clients):${RESET}"
    local _wstunnel_pid
    _wstunnel_pid=$(systemctl show wstunnel-server.service --property=MainPID --value 2>/dev/null || echo "")
    # پورت‌هایی که wstunnel روشون listen می‌کنه (به جز پورت خودش)
    local _r_ports
    _r_ports=$(ss -tlnp 2>/dev/null \
        | grep "wstunnel\|pid=${_wstunnel_pid}," \
        | grep -v ":${PARSED_BIND_PORT} " \
        | awk '{print $4}' | sort -u)
    if [ -n "$_r_ports" ]; then
        while IFS= read -r _p; do
            [ -z "$_p" ] && continue
            echo -e "    ${GREEN}✓${RESET}  ${_p}  — client connected and port is open"
        done <<< "$_r_ports"
        local _conn_count
        _conn_count=$(ss -tnp 2>/dev/null \
            | grep "pid=${_wstunnel_pid}," 2>/dev/null \
            | grep -c "ESTAB" 2>/dev/null || echo "?")
        echo -e "    ${CYAN}Active WebSocket connections: ${_conn_count}${RESET}"
    else
        check_warn "No -R ports bound — no Foreign VPS client is currently connected"
        echo -e "         ${YELLOW}→ Check client service on each Foreign VPS:${RESET}"
        echo -e "         ${CYAN}   systemctl status wstunnel-client.service${RESET}"
    fi

    # 13. بررسی لاگ برای خطاهای رایج
    echo ""
    echo -e "  ${BOLD}Log analysis:${RESET}"
    local recent_logs
    recent_logs=$(journalctl -u wstunnel-server.service -n 50 --no-pager 2>/dev/null || true)

    if echo "$recent_logs" | grep -q "Rejecting connection with not allowed destination"; then
        check_fail "Logs: reverse tunnel connections are being REJECTED (--restrict-to)"
        echo -e "         ${YELLOW}→ Run the fix above (remove --restrict-to) and restart service${RESET}"
    fi

    if echo "$recent_logs" | grep -q "error.*bind\|address already in use\|EADDRINUSE"; then
        check_fail "Logs: port binding error — two clients trying to use the same -R port!"
        echo -e "         ${RED}Each Foreign VPS must use a unique Iran VPS port.${RESET}"
        echo -e "         ${YELLOW}→ Edit the conflicting client and change its Iran VPS port${RESET}"
    fi

    # کلاینت‌هایی که در لاگ‌ها connect/disconnect کردن
    local _client_ips
    _client_ips=$(echo "$recent_logs" \
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
        | grep -v "127\.0\.0\." \
        | sort -u | head -10)
    if [ -n "$_client_ips" ]; then
        echo -e "    ${CYAN}Seen client IPs in recent logs:${RESET}"
        echo "$_client_ips" | while IFS= read -r _ip; do
            echo -e "      ${CYAN}${_ip}${RESET}"
        done
    fi

    if echo "$recent_logs" | grep -q "Invalid protocol version"; then
        check_warn "Some non-WebSocket traffic detected (normal — browsers/scanners)"
    fi

    echo ""
    echo -e "  ${BOLD}Last 20 log lines:${RESET}"
    echo "$recent_logs" | tail -20 | sed 's/^/    /'

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

    # 2. Service running / restart loop detection
    if systemctl is-active wstunnel-client.service &>/dev/null; then
        # Check restart count — if high, the service is in a crash loop
        local _restart_count
        _restart_count=$(systemctl show wstunnel-client.service --property=NRestarts --value 2>/dev/null || echo "0")
        if [ "${_restart_count:-0}" -gt 5 ] 2>/dev/null; then
            check_warn "wstunnel-client.service is running BUT has restarted ${_restart_count} times"
            echo -e "         ${YELLOW}→ The service keeps reconnecting — likely port conflict on Iran VPS${RESET}"
            echo -e "         ${YELLOW}→ Check if another Foreign VPS uses the same Iran port${RESET}"
            echo -e "         ${CYAN}   journalctl -u wstunnel-client.service -n 30 --no-pager${RESET}"
        else
            check_ok "wstunnel-client.service is running  (restarts: ${_restart_count:-0})"
        fi
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
    # Note: curl writes "000" to stdout even on timeout/error AND exits nonzero.
    # Using || echo "000" would double it to "000000", so we suppress exit code via || true.
    local http_code caddy_broken=false wstunnel_rejecting=false
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        --max-time 6 \
        "https://${PARSED_DOMAIN}:${PARSED_WSS_PORT}" 2>/dev/null) || true
    http_code="${http_code:-000}"
    # wstunnel rejects plain HTTP with connection-close (no response body) → curl gives 000.
    # Treat this as "reachable but wstunnel-only" — not the same as truly unreachable.
    local https_reachable=false
    case "$http_code" in
        "000")
            # Distinguish timeout from connection-refused:
            # Try a fast TCP connect to see if the port is at least open.
            if timeout 4 bash -c "echo >/dev/tcp/${PARSED_DOMAIN}/${PARSED_WSS_PORT}" 2>/dev/null; then
                https_reachable=true
                check_ok "Iran VPS port ${PARSED_WSS_PORT} is open (wstunnel doesn't respond to plain HTTP — normal)"
            else
                check_fail "Cannot reach https://${PARSED_DOMAIN}:${PARSED_WSS_PORT} (port closed or timeout)"
                echo -e "         ${YELLOW}→ Is Caddy running on Iran VPS?${RESET}"
                echo -e "         ${YELLOW}→ Is port 443 open in Iran VPS firewall?${RESET}"
                echo -e "         ${YELLOW}→ Does DNS point to Iran VPS?${RESET}"
            fi
            ;;
        "400")
            https_reachable=true
            check_fail "Iran VPS returns 400 — wstunnel or Caddy is rejecting the connection"
            echo -e "         ${RED}Most likely causes:${RESET}"
            echo -e "         ${RED}  1. --restrict-to flag in wstunnel-server.service (blocks ReverseTcp)${RESET}"
            echo -e "         ${RED}  2. --restrict-http-upgrade-path-prefix in wstunnel-server.service (incompatible with -R)${RESET}"
            echo -e "         ${RED}  3. Caddy path matcher not matching client upgrade path${RESET}"
            echo -e "         ${YELLOW}→ On Iran VPS check/fix wstunnel service:${RESET}"
            echo -e "         ${CYAN}   grep ExecStart /etc/systemd/system/wstunnel-server.service${RESET}"
            echo -e "         ${CYAN}   sed -i 's/ --restrict-to [^ ]*//g; s/ --restrict-http-upgrade-path-prefix [^ ]*//g' /etc/systemd/system/wstunnel-server.service${RESET}"
            echo -e "         ${CYAN}   systemctl daemon-reload && systemctl restart wstunnel-server.service${RESET}"
            wstunnel_rejecting=true
            ;;
        "404")
            https_reachable=true
            check_fail "Iran VPS returns 404 — Caddyfile is misconfigured or has 'respond 404'"
            echo -e "         ${RED}Caddy is running but blocking WebSocket connections!${RESET}"
            echo -e "         ${YELLOW}→ On Iran VPS fix Caddyfile:${RESET}"
            echo -e "         ${CYAN}           reverse_proxy localhost:2018  (remove @ws and respond 404)${RESET}"
            echo -e "         ${YELLOW}→ Then: systemctl reload caddy${RESET}"
            caddy_broken=true
            ;;
        *)
            https_reachable=true
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
            echo -e "         ${YELLOW}→ Is this port already used by another Foreign VPS client?${RESET}"
            echo -e "         ${YELLOW}→ Check wstunnel-server logs on Iran VPS:${RESET}"
            echo -e "         ${CYAN}   journalctl -u wstunnel-server.service -n 50 --no-pager${RESET}"
        fi
    done

    # 7. Restart timer
    echo ""
    echo -e "  ${BOLD}Scheduled Restart Timer:${RESET}"
    local _cli_h; _cli_h=$(get_restart_interval "client")
    if [ "$_cli_h" != "0" ]; then
        if systemctl is-active "wstunnel-client-restart.timer" &>/dev/null; then
            local _cnext; _cnext=$(systemctl list-timers "wstunnel-client-restart.timer" --no-pager 2>/dev/null \
                | awk 'NR==2 {print $1, $2}' || echo "unknown")
            check_ok "Timer active — restarts every ${_cli_h}h  (next: ${_cnext})"
        else
            check_warn "Timer configured (${_cli_h}h) but NOT active"
            echo -e "         ${YELLOW}→ sudo systemctl start wstunnel-client-restart.timer${RESET}"
        fi
    else
        check_warn "No scheduled restart timer — consider enabling via Edit → option 5"
    fi

    # 8. ws shortcut
    echo ""
    echo -e "  ${BOLD}ws Command:${RESET}"
    if [ -f "$WS_BIN" ] && [ -x "$WS_BIN" ]; then
        check_ok "'ws' shortcut installed at ${WS_BIN}  (type 'ws' to relaunch)"
    else
        check_warn "'ws' shortcut not found — run Update (option 5) to install it"
    fi

    # 9. Caddy CA cert trust check
    echo ""
    echo -e "  ${BOLD}Caddy CA Certificate Trust:${RESET}"
    local _ca_file
    _ca_file=$(ls /usr/local/share/ca-certificates/caddy*.crt 2>/dev/null | head -1 || true)
    if [ -n "$_ca_file" ]; then
        check_ok "Caddy CA cert found: ${_ca_file}"
        if openssl verify -CAfile "$_ca_file" "$_ca_file" &>/dev/null 2>&1 \
            || openssl x509 -in "$_ca_file" -noout -subject &>/dev/null 2>&1; then
            check_ok "CA cert appears valid"
        else
            check_warn "CA cert may be malformed — try reinstalling from Iran VPS"
        fi
    else
        check_fail "Caddy CA cert NOT installed"
        echo -e "         ${RED}Iran VPS uses 'tls internal' — this VPS won't trust its cert!${RESET}"
        echo -e "         ${YELLOW}→ On Iran VPS run:${RESET}"
        echo -e "         ${CYAN}   cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt${RESET}"
        echo -e "         ${YELLOW}→ On this Foreign VPS paste that output into:${RESET}"
        echo -e "         ${CYAN}   cat > /usr/local/share/ca-certificates/caddy-iran-ca.crt${RESET}"
        echo -e "         ${CYAN}   update-ca-certificates${RESET}"
        echo -e "         ${CYAN}   systemctl restart wstunnel-client.service${RESET}"
    fi

    # 10. Log analysis
    echo ""
    echo -e "  ${BOLD}Log analysis:${RESET}"
    local _cli_logs
    _cli_logs=$(journalctl -u wstunnel-client.service -n 50 --no-pager 2>/dev/null || true)

    local tls_error=false
    if echo "$_cli_logs" | grep -qi "certificate.*unknown\|unknown.*authority\|tls.*handshake\|x509\|certificate.*verify"; then
        tls_error=true
        check_fail "Logs: TLS certificate trust error — Caddy CA cert not trusted!"
        echo -e "         ${RED}The Foreign VPS does not trust Iran VPS's self-signed TLS cert.${RESET}"
        echo -e "         ${YELLOW}→ Install Caddy CA cert (see step 9 above)${RESET}"
    fi

    if echo "$_cli_logs" | grep -qi "error.*bind\|address already in use\|EADDRINUSE\|already.*listen"; then
        check_fail "Logs: port binding error — another client is already using that Iran VPS port!"
        echo -e "         ${RED}Two Foreign VPS clients using the same Iran port.${RESET}"
        echo -e "         ${YELLOW}→ Edit → option 4 → change Iran VPS port to a unique value${RESET}"
    fi

    if echo "$_cli_logs" | grep -qi "refused\|timeout\|unreachable\|connection.*reset"; then
        check_warn "Logs: connection errors detected — Iran VPS may be unreachable or rejecting"
    fi

    if echo "$_cli_logs" | grep -qi "register.*reverse\|reverse.*register\|start.*listen"; then
        check_ok "Logs: reverse tunnel registration messages found (client connected)"
    fi

    echo ""
    echo -e "  ${BOLD}Last 30 log lines:${RESET}"
    echo "$_cli_logs" | tail -30 | sed 's/^/    /' \
        || echo -e "    ${YELLOW}(no logs available)${RESET}"

    # 11. Summary verdict
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━  Verdict  ━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    if $tls_error; then
        echo -e "  ${RED}Root cause: TLS certificate not trusted on this Foreign VPS.${RESET}"
        echo -e "  Iran VPS uses 'tls internal' but this VPS doesn't have the CA cert."
        echo ""
        echo -e "  ${YELLOW}Fix — on Iran VPS get the CA cert:${RESET}"
        echo -e "  ${CYAN}cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt${RESET}"
        echo -e "  ${YELLOW}Then on THIS Foreign VPS:${RESET}"
        echo -e "  ${CYAN}cat > /usr/local/share/ca-certificates/caddy-iran-ca.crt${RESET}  [paste + Ctrl+D]"
        echo -e "  ${CYAN}update-ca-certificates && systemctl restart wstunnel-client.service${RESET}"
    elif $caddy_broken; then
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
    echo ""
    echo -e "  ${BOLD}Multi-location tip:${RESET} To see ALL connected clients and their ports,"
    echo -e "  run Diagnose on the ${YELLOW}Iran VPS${RESET} — it shows every bound -R port and"
    echo -e "  active WebSocket connection from each Foreign VPS."
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
        echo -e "  ${CYAN}3${RESET}) Back to main menu"
        echo ""
        local ch
        while true; do
            read -rp "$(echo -e "  ${BOLD}Enter 1-3${RESET}: ")" ch
            case "$ch" in
                1) diagnose_server; return ;;
                2) diagnose_client; return ;;
                3) return ;;
                *) warn "Please enter 1, 2 or 3." ;;
            esac
        done
    fi

    $has_server && diagnose_server
    $has_client && diagnose_client
}

# ─────────────────────────────────────────────
# Kernel TCP tuning for high-connection server
# ─────────────────────────────────────────────
tune_kernel_for_server() {
    info "Applying kernel TCP tuning for high-connection workloads..."
    local sysctl_conf="/etc/sysctl.conf"
    local params=(
        "net.ipv4.tcp_max_syn_backlog=4096"
        "net.core.netdev_max_backlog=4096"
        "net.ipv4.tcp_syn_retries=3"
        "net.ipv4.tcp_fin_timeout=15"
        "net.ipv4.tcp_tw_reuse=1"
    )
    for param in "${params[@]}"; do
        local key="${param%%=*}"
        local val="${param##*=}"
        if grep -q "^${key}" "$sysctl_conf" 2>/dev/null; then
            sed -i "s|^${key}.*|${key} = ${val}|" "$sysctl_conf"
        else
            echo "${key} = ${val}" >> "$sysctl_conf"
        fi
    done
    sysctl -p &>/dev/null
    success "Kernel TCP tuning applied (tcp_max_syn_backlog=4096, tcp_tw_reuse=1)."
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
    echo -e "${BOLD}─── Anti-Detection / Obfuscation ──────────────────────${RESET}"
    echo -e "  ${YELLOW}A custom WebSocket upgrade path makes tunnel traffic look like a${RESET}"
    echo -e "  ${YELLOW}regular HTTPS API call — harder for DPI to detect and block.${RESET}"
    echo -e "  ${YELLOW}Each Foreign VPS client MUST use the EXACT SAME path.${RESET}"
    echo ""
    local _gen_path; _gen_path=$(gen_upgrade_path)
    echo -e "  ${CYAN}Auto-generated path example: ${_gen_path}${RESET}"
    echo ""
    ask PARSED_UPGRADE_PATH "WebSocket upgrade path (Enter to use generated, leave blank to disable)" "${_gen_path}"
    # Normalize: ensure leading slash or empty
    if [ -n "$PARSED_UPGRADE_PATH" ] && [[ "$PARSED_UPGRADE_PATH" != /* ]]; then
        PARSED_UPGRADE_PATH="/${PARSED_UPGRADE_PATH}"
    fi

    echo ""
    echo -e "${BOLD}─── Scheduled Auto-Restart ────────────────────────────${RESET}"
    echo -e "  ${YELLOW}Periodic restart keeps the tunnel fresh and clears stale connections.${RESET}"
    local SERVER_RESTART_HOURS
    ask_restart_interval SERVER_RESTART_HOURS "0"

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━  Summary  ━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Mode             :  ${GREEN}Iran VPS — Server${RESET}"
    echo -e "  wstunnel version :  ${YELLOW}${WSTUNNEL_VERSION}${RESET}"
    echo ""
    show_server_state
    if [ "$SERVER_RESTART_HOURS" != "0" ]; then
        echo -e "  ${BOLD}Auto-restart      :${RESET}  ${YELLOW}every ${SERVER_RESTART_HOURS}h${RESET}"
    else
        echo -e "  ${BOLD}Auto-restart      :${RESET}  ${YELLOW}disabled${RESET}"
    fi
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    confirm "Proceed with server installation?" || { info "Aborted."; return; }
    echo ""

    # ── ۱. نصب wstunnel ────────────────────────────────
    install_wstunnel_binary "$WSTUNNEL_VERSION"
    setup_user
    write_server_service
    tune_kernel_for_server

    # ── ۲. نصب و کانفیگ Caddy ──────────────────────────
    echo ""
    echo -e "${BOLD}─── Caddy ─────────────────────────────────────────────${RESET}"
    install_caddy
    for dom in "${PARSED_DOMAINS[@]+"${PARSED_DOMAINS[@]}"}"; do
        configure_caddyfile "$dom" "$PARSED_BIND_PORT" "${PARSED_UPGRADE_PATH:-}"
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

    # ── ۳. تایمر ری‌استارت ──────────────────────────────
    if [ "$SERVER_RESTART_HOURS" != "0" ]; then
        echo ""
        echo -e "${BOLD}─── Restart Timer ─────────────────────────────────────${RESET}"
        write_restart_timer "server" "$SERVER_RESTART_HOURS"
    fi

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  wstunnel logs:  ${CYAN}sudo journalctl -u wstunnel-server.service -f${RESET}"
    echo -e "  Caddy logs:     ${CYAN}sudo journalctl -u caddy -f${RESET}"
    echo -e "  Caddyfile:      ${CYAN}/etc/caddy/Caddyfile${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

    # ── CA cert — باید روی هر Foreign VPS نصب شود ──────────
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━  CA Certificate  ━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  ${YELLOW}Caddy uses 'tls internal' (self-signed CA).${RESET}"
    echo -e "  ${YELLOW}Each Foreign VPS MUST trust this CA for the tunnel to work.${RESET}"
    echo ""
    local _caddy_ca="/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt"
    # Caddy ممکنه چند ثانیه طول بکشه تا CA بسازه
    local _wait=0
    while [ ! -f "$_caddy_ca" ] && [ $_wait -lt 10 ]; do
        sleep 1; _wait=$((_wait + 1))
    done
    if [ -f "$_caddy_ca" ]; then
        echo -e "  ${BOLD}Run these commands on each Foreign VPS:${RESET}"
        echo ""
        echo -e "${CYAN}cat > /usr/local/share/ca-certificates/caddy-iran-ca.crt << 'CACEOF'${RESET}"
        cat "$_caddy_ca"
        echo -e "${CYAN}CACEOF${RESET}"
        echo -e "${CYAN}update-ca-certificates${RESET}"
        echo -e "${CYAN}systemctl restart wstunnel-client.service${RESET}"
    else
        echo -e "  ${YELLOW}CA cert not generated yet. Run after ~30s:${RESET}"
        echo -e "  ${CYAN}cat ${_caddy_ca}${RESET}"
        echo -e "  Copy output to Foreign VPS: /usr/local/share/ca-certificates/caddy-iran-ca.crt"
        echo -e "  Then run: update-ca-certificates"
    fi
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

    echo ""
    echo ""
    echo -e "${BOLD}─── ws command ────────────────────────────────────────${RESET}"
    install_ws_command
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
    echo -e "${BOLD}─── Anti-Detection / Obfuscation ──────────────────────${RESET}"
    echo -e "  ${YELLOW}Enter the WebSocket upgrade path configured on the Iran VPS server.${RESET}"
    echo -e "  ${YELLOW}Leave empty ONLY if the server was set up without a path.${RESET}"
    echo ""
    ask PARSED_UPGRADE_PATH "WebSocket upgrade path (copy from Iran VPS setup, or leave blank)" ""
    if [ -n "$PARSED_UPGRADE_PATH" ] && [[ "$PARSED_UPGRADE_PATH" != /* ]]; then
        PARSED_UPGRADE_PATH="/${PARSED_UPGRADE_PATH}"
    fi

    echo ""
    echo -e "${BOLD}─── Caddy CA Certificate (TLS Trust) ──────────────────${RESET}"
    echo -e "  ${YELLOW}Iran VPS uses 'tls internal'. This VPS must trust Caddy's CA cert.${RESET}"
    echo -e "  ${YELLOW}Get the cert from Iran VPS:${RESET}"
    echo -e "  ${CYAN}cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt${RESET}"
    echo ""
    local _ca_already=false
    if ls /usr/local/share/ca-certificates/ 2>/dev/null | grep -qi "caddy"; then
        _ca_already=true
        check_ok "A Caddy CA cert is already in /usr/local/share/ca-certificates/"
        confirm "  Reinstall / update it?" || _ca_already=true
    fi
    if ! $_ca_already; then
        echo -e "  ${BOLD}Paste the cert content below (from Iran VPS), then press Ctrl+D on a new line:${RESET}"
        local _ca_content _ca_tmp
        _ca_tmp=$(mktemp)
        _ca_content=$(cat 2>/dev/null || true)
        if echo "$_ca_content" | grep -q "BEGIN CERTIFICATE"; then
            echo "$_ca_content" > "$_ca_tmp"
            # Validate cert is parseable before touching system CA bundle
            if openssl x509 -in "$_ca_tmp" -noout 2>/dev/null; then
                cp "$_ca_tmp" /usr/local/share/ca-certificates/caddy-iran-ca.crt
                chmod 644 /usr/local/share/ca-certificates/caddy-iran-ca.crt
                if update-ca-certificates 2>/dev/null; then
                    success "Caddy CA cert installed — TLS trust configured."
                else
                    warn "update-ca-certificates failed — trying --fresh..."
                    update-ca-certificates --fresh 2>/dev/null || true
                fi
            else
                warn "Cert failed OpenSSL validation — NOT installed (system CA bundle unchanged)."
                echo -e "  ${YELLOW}Make sure you copied the full cert including BEGIN/END lines.${RESET}"
            fi
        else
            warn "No valid cert pasted — skipping. Install manually later:"
            echo -e "  ${CYAN}cat > /usr/local/share/ca-certificates/caddy-iran-ca.crt${RESET}"
            echo -e "  ${CYAN}update-ca-certificates${RESET}"
        fi
        rm -f "$_ca_tmp"
    fi

    echo ""
    echo -e "${BOLD}─── Port mappings ─────────────────────────────────────${RESET}"
    echo -e "  How ${BOLD}-R${RESET} works:"
    echo -e "    [User] → ${YELLOW}Iran VPS${RESET}:IRAN_PORT  →  WSS tunnel  →  ${GREEN}this VPS${RESET}:LOCAL_PORT"
    echo -e "  Ports open on Iran VPS. Your VPN service must run on LOCAL_PORT here."
    echo ""
    echo -e "  ${YELLOW}⚠  MULTI-LOCATION:${RESET} If you have more than one Foreign VPS connecting to"
    echo -e "  the same Iran VPS, ${BOLD}each Foreign VPS must use a different IRAN_PORT${RESET}."
    echo -e "  Example: VPS-1 → 8443 / VPS-2 → 9443 / VPS-3 → 7443"
    echo -e "  Two clients sharing the same Iran port = second client never connects."
    echo ""

    PARSED_FLAGS=()
    declare -a IRAN_PORTS=()
    local count=0

    while true; do
        count=$((count + 1))
        echo -e "  ${BOLD}── Mapping #${count} ──${RESET}"
        ask IRAN_BIND_IP "Bind IP on Iran VPS (0.0.0.0 = public)" "0.0.0.0"
        while true; do
            ask IRAN_PORT "Port to open on Iran VPS (users connect here)" "8443"
            local _dup_port=false
            for _existing_port in "${IRAN_PORTS[@]+"${IRAN_PORTS[@]}"}"; do
                [ "$_existing_port" = "$IRAN_PORT" ] && _dup_port=true && break
            done
            if $_dup_port; then
                warn "Port ${IRAN_PORT} is already used in a previous mapping. Choose a different port."
            else
                break
            fi
        done
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
    echo -e "${BOLD}─── Scheduled Auto-Restart ────────────────────────────${RESET}"
    echo -e "  ${YELLOW}Periodic restart reconnects the tunnel and clears stale WebSocket connections.${RESET}"
    local CLIENT_RESTART_HOURS
    ask_restart_interval CLIENT_RESTART_HOURS "0"

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━  Summary  ━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Mode             :  ${GREEN}Foreign VPS — Client${RESET}"
    echo -e "  wstunnel version :  ${YELLOW}${WSTUNNEL_VERSION}${RESET}"
    echo -e "  Connect to Iran  :  ${YELLOW}wss://${PARSED_DOMAIN}:${PARSED_WSS_PORT}${RESET}"
    echo ""
    show_client_state
    echo ""
    echo -e "  ExecStart:  ${CYAN}${exec_full}${RESET}"
    if [ "$CLIENT_RESTART_HOURS" != "0" ]; then
        echo -e "  ${BOLD}Auto-restart      :${RESET}  ${YELLOW}every ${CLIENT_RESTART_HOURS}h${RESET}"
    else
        echo -e "  ${BOLD}Auto-restart      :${RESET}  ${YELLOW}disabled${RESET}"
    fi
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    confirm "Proceed with client installation?" || { info "Aborted."; return; }
    echo ""

    install_wstunnel_binary "$WSTUNNEL_VERSION"
    setup_user
    write_client_service

    # ── تایمر ری‌استارت ──────────────────────────────
    if [ "$CLIENT_RESTART_HOURS" != "0" ]; then
        echo ""
        echo -e "${BOLD}─── Restart Timer ─────────────────────────────────────${RESET}"
        write_restart_timer "client" "$CLIENT_RESTART_HOURS"
    fi

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
    echo ""
    echo -e "  ${YELLOW}MULTI-LOCATION REMINDER:${RESET}"
    echo -e "  Each Foreign VPS must use a ${BOLD}unique${RESET} Iran VPS port."
    echo -e "  This machine uses: ${CYAN}$(IFS=,; echo "${IRAN_PORTS[*]}")${RESET}"
    echo -e "  Other Foreign VPS machines must use different port numbers."
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    echo ""
    echo -e "${BOLD}─── ws command ────────────────────────────────────────${RESET}"
    install_ws_command
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
    local -a ADDED_DOMAINS=()   # فقط دامنه‌هایی که این session اضافه شدن

    while true; do
        echo ""
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━  Edit Server  ━━━━━━━━━━━━━━━━━━━${RESET}"
        show_server_state
        echo ""
        local cur_restart; cur_restart=$(get_restart_interval "server")
        echo -e "  ${BOLD}Auto-restart      :${RESET}  $([ "$cur_restart" != "0" ] && echo "${GREEN}every ${cur_restart}h${RESET}" || echo "${YELLOW}disabled${RESET}")"
        echo ""
        echo -e "${BOLD}─── Options ───────────────────────────────────────────${RESET}"
        echo -e "  ${CYAN}1${RESET}) Add domain"
        echo -e "  ${CYAN}2${RESET}) Remove domain"
        echo -e "  ${CYAN}3${RESET}) Change bind IP / port"
        echo -e "  ${CYAN}4${RESET}) Change WebSocket upgrade path (obfuscation)"
        echo -e "  ${CYAN}5${RESET}) Configure scheduled restart"
        echo -e "  ${CYAN}6${RESET}) Apply changes"
        echo -e "  ${CYAN}7${RESET}) Back to main menu"
        echo ""

        local choice
        read -rp "$(echo -e "  ${BOLD}Enter 1-7${RESET}: ")" choice

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
                    ADDED_DOMAINS+=("${NEW_DOMAIN}")
                    changed=true
                    success "Domain ${NEW_DOMAIN} added (apply to save)."
                fi
                ;;
            2)
                [ ${#PARSED_DOMAINS[@]} -eq 0 ] && { warn "No domains configured."; continue; }
                echo ""
                echo -e "  ${BOLD}Which domain to remove?${RESET}"
                for i in "${!PARSED_DOMAINS[@]}"; do
                    echo -e "    ${CYAN}$((i+1))${RESET}  ${PARSED_DOMAINS[$i]}"
                done
                echo ""
                local r_idx
                read -rp "$(echo -e "  ${BOLD}Enter number${RESET}: ")" r_idx
                if [[ "$r_idx" =~ ^[0-9]+$ ]] && (( r_idx >= 1 && r_idx <= ${#PARSED_DOMAINS[@]} )); then
                    local rm_dom="${PARSED_DOMAINS[$((r_idx-1))]}"
                    echo ""
                    warn "Removing ${rm_dom} will disconnect any Foreign VPS clients tunneling through it."
                    confirm "  Confirm removal?" || continue
                    # اگه از همین session اضافه شده بود، از ADDED_DOMAINS هم حذف کن
                    local new_added=()
                    for a in "${ADDED_DOMAINS[@]+"${ADDED_DOMAINS[@]}"}"; do
                        [ "$a" != "$rm_dom" ] && new_added+=("$a")
                    done
                    ADDED_DOMAINS=()
                    for a in "${new_added[@]+"${new_added[@]}"}"; do ADDED_DOMAINS+=("$a"); done
                    # اگه از Caddyfile بود، در DOMAINS_TO_REMOVE بذار
                    local was_in_caddy=false
                    grep -qF "${rm_dom} {" "/etc/caddy/Caddyfile" 2>/dev/null && was_in_caddy=true
                    $was_in_caddy && DOMAINS_TO_REMOVE+=("$rm_dom")
                    # از PARSED_DOMAINS حذف کن
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
                echo ""
                echo -e "  ${YELLOW}Current path: ${PARSED_UPGRADE_PATH:-"(none)"}${RESET}"
                echo -e "  ${YELLOW}Leave blank to disable obfuscation. Must match all Foreign VPS clients.${RESET}"
                echo ""
                local _auto_path; _auto_path=$(gen_upgrade_path)
                echo -e "  ${CYAN}Auto-generated: ${_auto_path}${RESET}"
                local NEW_PATH
                ask NEW_PATH "New WebSocket upgrade path (or leave blank to disable)" "${PARSED_UPGRADE_PATH}"
                if [ -n "$NEW_PATH" ] && [[ "$NEW_PATH" != /* ]]; then
                    NEW_PATH="/${NEW_PATH}"
                fi
                if [ "$NEW_PATH" != "$PARSED_UPGRADE_PATH" ]; then
                    PARSED_UPGRADE_PATH="$NEW_PATH"
                    changed=true
                    if [ -n "$PARSED_UPGRADE_PATH" ]; then
                        success "Upgrade path set to: ${PARSED_UPGRADE_PATH}"
                        warn "Update all Foreign VPS clients to use this path!"
                    else
                        success "Upgrade path disabled."
                    fi
                else
                    info "No changes."
                fi
                ;;
            5)
                local cur_h; cur_h=$(get_restart_interval "server")
                ask_restart_interval NEW_RESTART_H "$cur_h"
                if [ "$NEW_RESTART_H" = "0" ]; then
                    remove_restart_timer "server"
                elif [ "$NEW_RESTART_H" != "$cur_h" ]; then
                    write_restart_timer "server" "$NEW_RESTART_H"
                else
                    info "No changes to restart timer."
                fi
                ;;
            6)
                ! $changed && { info "No changes to apply."; continue; }
                echo ""
                echo -e "${BOLD}─── Changes Summary ───────────────────────────────────${RESET}"
                if [ ${#DOMAINS_TO_REMOVE[@]} -gt 0 ]; then
                    echo -e "  ${RED}Remove:${RESET}"
                    for dom in "${DOMAINS_TO_REMOVE[@]}"; do
                        echo -e "    ${RED}✗${RESET}  ${dom}"
                    done
                fi
                if [ ${#ADDED_DOMAINS[@]} -gt 0 ]; then
                    echo -e "  ${GREEN}Add:${RESET}"
                    for dom in "${ADDED_DOMAINS[@]}"; do
                        echo -e "    ${GREEN}✓${RESET}  ${dom}"
                    done
                fi
                if [ "${PARSED_BIND_IP}" != "${old_ip}" ] || [ "${PARSED_BIND_PORT}" != "${old_port}" ]; then
                    echo -e "  ${CYAN}Bind:${RESET}  ${old_ip}:${old_port}  →  ${PARSED_BIND_IP}:${PARSED_BIND_PORT}"
                fi
                echo ""
                confirm "Apply changes?" || continue
                echo ""

                # 1. wstunnel service — اگه bind address یا upgrade path تغییر کرده
                local svc_changed=false
                if [ "${PARSED_BIND_IP}" != "${old_ip}" ] || [ "${PARSED_BIND_PORT}" != "${old_port}" ]; then
                    svc_changed=true
                fi
                # Path obfuscation is now in Caddyfile — check if it changed
                local _cur_caddy_path=""
                [ -f "/etc/caddy/Caddyfile" ] && \
                    _cur_caddy_path=$(sed -n 's/[[:space:]]*path \(\/[^* ]*\)\*.*/\1/p' /etc/caddy/Caddyfile | head -1)
                local caddy_path_changed=false
                [ "$_cur_caddy_path" != "${PARSED_UPGRADE_PATH:-}" ] && caddy_path_changed=true

                local port_changed=false
                if [ "${PARSED_BIND_IP}" != "${old_ip}" ] || [ "${PARSED_BIND_PORT}" != "${old_port}" ]; then
                    port_changed=true
                fi
                $svc_changed && write_server_service

                # 2. اول دامنه‌های حذفی رو از Caddyfile بردار (بدون دست زدن به بقیه)
                for dom in "${DOMAINS_TO_REMOVE[@]+"${DOMAINS_TO_REMOVE[@]}"}"; do
                    remove_caddyfile_domain "$dom"
                done

                # 3. بعد دامنه‌های جدید رو اضافه/آپدیت کن
                if $port_changed || $caddy_path_changed; then
                    for dom in "${PARSED_DOMAINS[@]+"${PARSED_DOMAINS[@]}"}"; do
                        configure_caddyfile "$dom" "${PARSED_BIND_PORT}" "${PARSED_UPGRADE_PATH:-}"
                    done
                else
                    for dom in "${ADDED_DOMAINS[@]+"${ADDED_DOMAINS[@]}"}"; do
                        configure_caddyfile "$dom" "${PARSED_BIND_PORT}" "${PARSED_UPGRADE_PATH:-}"
                    done
                fi

                # 4. Caddy reload
                if [ ${#PARSED_DOMAINS[@]} -eq 0 ]; then
                    warn "No domains remain — Caddy has nothing to proxy."
                    warn "Clients cannot connect until you add a domain (option 1)."
                fi
                local cbin; cbin=$(caddy_bin)
                if [ -n "$cbin" ]; then
                    if systemctl reload caddy 2>/dev/null; then
                        success "Caddy reloaded successfully."
                    else
                        warn "Caddy reload failed — check: systemctl status caddy"
                    fi
                else
                    warn "Caddy binary not found — reload manually: systemctl reload caddy"
                fi
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
        local cur_restart_c; cur_restart_c=$(get_restart_interval "client")
        echo -e "  ${BOLD}Auto-restart      :${RESET}  $([ "$cur_restart_c" != "0" ] && echo "${GREEN}every ${cur_restart_c}h${RESET}" || echo "${YELLOW}disabled${RESET}")"
        echo ""
        echo -e "${BOLD}─── Options ───────────────────────────────────────────${RESET}"
        echo -e "  ${CYAN}1${RESET}) Add new port mapping"
        echo -e "  ${CYAN}2${RESET}) Edit an existing port mapping"
        echo -e "  ${CYAN}3${RESET}) Remove a port mapping"
        echo -e "  ${CYAN}4${RESET}) Change Iran VPS domain / WSS port"
        echo -e "  ${CYAN}5${RESET}) Change WebSocket upgrade path (obfuscation)"
        echo -e "  ${CYAN}6${RESET}) Configure scheduled restart"
        echo -e "  ${CYAN}7${RESET}) Apply changes and restart service"
        echo -e "  ${CYAN}8${RESET}) Back to main menu (discard changes)"
        echo ""

        local choice
        read -rp "$(echo -e "  ${BOLD}Enter 1-8${RESET}: ")" choice

        case "$choice" in
            1)
                echo ""
                echo -e "  ${BOLD}── New Port Mapping ──${RESET}"
                ask IRAN_BIND_IP "Bind IP on Iran VPS" "0.0.0.0"
                while true; do
                    ask IRAN_PORT "Port to open on Iran VPS" "8443"
                    local _dup=false
                    for _f in "${PARSED_FLAGS[@]+"${PARSED_FLAGS[@]}"}"; do
                        local _ep; _ep=$(echo "${_f#tcp://}" | cut -d: -f2)
                        [ "$_ep" = "$IRAN_PORT" ] && _dup=true && break
                    done
                    if $_dup; then
                        warn "Port ${IRAN_PORT} already exists in another mapping. Choose a different port."
                    else
                        break
                    fi
                done
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
                    while true; do
                        ask IRAN_PORT "Port on Iran VPS"             "$(echo "$oa"|cut -d: -f2)"
                        local _dup=false
                        for _fi in "${!PARSED_FLAGS[@]}"; do
                            [ "$_fi" -eq "$idx" ] && continue
                            local _ep; _ep=$(echo "${PARSED_FLAGS[$_fi]#tcp://}" | cut -d: -f2)
                            [ "$_ep" = "$IRAN_PORT" ] && _dup=true && break
                        done
                        if $_dup; then
                            warn "Port ${IRAN_PORT} is used by another mapping. Choose a different port."
                        else
                            break
                        fi
                    done
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
                echo -e "  ${YELLOW}Current path: ${PARSED_UPGRADE_PATH:-"(none)"}${RESET}"
                echo -e "  ${YELLOW}Must match the upgrade path configured on the Iran VPS server.${RESET}"
                echo ""
                local NEW_CLIENT_PATH
                ask NEW_CLIENT_PATH "WebSocket upgrade path (or leave blank to disable)" "${PARSED_UPGRADE_PATH}"
                if [ -n "$NEW_CLIENT_PATH" ] && [[ "$NEW_CLIENT_PATH" != /* ]]; then
                    NEW_CLIENT_PATH="/${NEW_CLIENT_PATH}"
                fi
                if [ "$NEW_CLIENT_PATH" != "$PARSED_UPGRADE_PATH" ]; then
                    PARSED_UPGRADE_PATH="$NEW_CLIENT_PATH"
                    changed=true
                    [ -n "$PARSED_UPGRADE_PATH" ] && success "Upgrade path set to: ${PARSED_UPGRADE_PATH}" || success "Upgrade path disabled."
                else
                    info "No changes."
                fi
                ;;
            6)
                local cur_hc; cur_hc=$(get_restart_interval "client")
                ask_restart_interval NEW_RESTART_HC "$cur_hc"
                if [ "$NEW_RESTART_HC" = "0" ]; then
                    remove_restart_timer "client"
                elif [ "$NEW_RESTART_HC" != "$cur_hc" ]; then
                    write_restart_timer "client" "$NEW_RESTART_HC"
                else
                    info "No changes to restart timer."
                fi
                ;;
            7)
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
            8)
                info "No changes applied."; return ;;
            *)
                warn "Please enter a number between 1 and 8." ;;
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
        echo -e "  ${CYAN}3${RESET}) Back to main menu"
        echo ""
        local ch
        while true; do
            read -rp "$(echo -e "  ${BOLD}Enter 1-3${RESET}: ")" ch
            case "$ch" in
                1) edit_server; return ;;
                2) edit_client; return ;;
                3) return ;;
                *) warn "Please enter 1, 2 or 3." ;;
            esac
        done
    fi

    if $has_server && $has_client; then
        echo ""
        echo -e "${BOLD}Both services found. Which to edit?${RESET}"
        echo ""
        echo -e "  ${CYAN}1${RESET}) Iran VPS   — wstunnel-server (bind IP / port)"
        echo -e "  ${CYAN}2${RESET}) Foreign VPS — wstunnel-client (ports + domain)"
        echo -e "  ${CYAN}3${RESET}) Back to main menu"
        echo ""
        local sc
        while true; do
            read -rp "$(echo -e "  ${BOLD}Enter 1-3${RESET}: ")" sc
            case "$sc" in
                1) edit_server; return ;;
                2) edit_client; return ;;
                3) return ;;
                *) warn "Please enter 1, 2 or 3." ;;
            esac
        done
    elif $has_server; then edit_server
    else edit_client
    fi
}

# Install / refresh the `ws` shortcut in /usr/local/bin/ws
install_ws_command() {
    info "Installing 'ws' command shortcut..."
    cat > "$WS_BIN" <<'WSEOF'
#!/bin/bash
exec bash <(curl -fsSL "https://raw.githubusercontent.com/Samr002/black-box/main/setup.sh") "$@"
WSEOF
    chmod +x "$WS_BIN"
    success "Shortcut installed: type 'ws' from anywhere to launch this script."
}

# Update Caddy binary to the latest pinned version
update_caddy_binary() {
    local cbin; cbin=$(caddy_bin)
    if [ -z "$cbin" ]; then
        warn "Caddy not found — skipping Caddy update."
        return
    fi
    local cur_ver; cur_ver=$("$cbin" version 2>/dev/null | awk '{print $1}' | sed 's/^v//' || echo "unknown")
    info "Current Caddy version: ${cur_ver}  [${cbin}]"
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
        *)       warn "Unsupported arch for Caddy update: ${arch}"; return ;;
    esac
    local ver="2.9.1"
    local url="https://github.com/caddyserver/caddy/releases/download/v${ver}/caddy_${ver}_linux_${arch}.tar.gz"
    info "Downloading Caddy v${ver}..."
    curl -fsSL "$url" -o /tmp/caddy.tar.gz
    tar -xzf /tmp/caddy.tar.gz -C /tmp caddy
    mv /tmp/caddy "$cbin"
    chmod +x "$cbin"
    rm -f /tmp/caddy.tar.gz
    success "Caddy updated to v${ver}  [${cbin}]"
    systemctl reload caddy 2>/dev/null && info "Caddy reloaded." || true
}

# ─────────────────────────────────────────────
# Update
# ─────────────────────────────────────────────
flow_update() {
    echo ""

    # ── current state ────────────────────────────
    local wbin; wbin=$(wstunnel_bin)
    if [ -n "$wbin" ]; then
        info "wstunnel  : $("$wbin" --version 2>&1 | head -n1)  [${wbin}]"
    else
        warn "wstunnel binary not found — will install fresh."
    fi

    local cbin; cbin=$(caddy_bin)
    if [ -n "$cbin" ]; then
        info "Caddy     : $("$cbin" version 2>/dev/null | head -n1)  [${cbin}]"
    else
        info "Caddy     : not installed on this machine."
    fi

    local script_date=""
    if [ -f "$WS_BIN" ]; then
        script_date=$(date -r "$WS_BIN" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown")
        info "ws script : installed  (last updated ${script_date})  [${WS_BIN}]"
    else
        info "ws script : not installed yet."
    fi

    declare -a FOUND_SVCS=()
    detect_services FOUND_SVCS

    if [ ${#FOUND_SVCS[@]} -gt 0 ]; then
        echo ""
        echo -e "  Services:"
        for svc in "${FOUND_SVCS[@]}"; do
            local st; st=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
            echo -e "    ${CYAN}${svc}${RESET}  [${st}]"
        done
    fi

    # ── per-component selection ──────────────────
    echo ""
    echo -e "${BOLD}─── Select what to update ─────────────────────────────${RESET}"

    local do_wstunnel=false NEW_VERSION="10.5.5"
    echo ""
    echo -e "  ${BOLD}wstunnel${RESET}  (current: $([ -n "$wbin" ] && "$wbin" --version 2>&1 | head -n1 || echo 'not installed'))"
    if confirm "  Update wstunnel?"; then
        do_wstunnel=true
        ask NEW_VERSION "  Target version" "10.5.5"
    fi

    local do_caddy=false
    if [ -n "$cbin" ]; then
        echo ""
        echo -e "  ${BOLD}Caddy${RESET}     (current: $("$cbin" version 2>/dev/null | head -n1))"
        confirm "  Update Caddy?" && do_caddy=true
    fi

    local do_script=false
    echo ""
    if [ -f "$WS_BIN" ]; then
        local script_date; script_date=$(date -r "$WS_BIN" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown")
        echo -e "  ${BOLD}ws script${RESET} (last updated: ${script_date})"
    else
        echo -e "  ${BOLD}ws script${RESET} (not installed yet)"
    fi
    confirm "  Update ws script from GitHub?" && do_script=true

    if ! $do_wstunnel && ! $do_caddy && ! $do_script; then
        echo ""
        info "Nothing selected — no changes made."
        return
    fi

    # ── summary ──────────────────────────────────
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━  Will update  ━━━━━━━━━━━━━━━━━━${RESET}"
    $do_wstunnel && echo -e "  ${CYAN}wstunnel${RESET}   →  v${NEW_VERSION}"
    $do_caddy    && echo -e "  ${CYAN}Caddy${RESET}      →  v2.9.1 (latest pinned)"
    $do_script   && echo -e "  ${CYAN}ws script${RESET}  →  latest from GitHub"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    confirm "Proceed?" || { info "Aborted."; return; }
    echo ""

    # ── stop services if wstunnel is being updated ──
    if $do_wstunnel; then
        for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
            info "Stopping ${svc} ..."
            systemctl stop "$svc" || true
        done
    fi

    # ── 1. wstunnel ─────────────────────────────
    if $do_wstunnel; then
        echo ""
        echo -e "${BOLD}─── wstunnel ──────────────────────────────────────────${RESET}"
        install_wstunnel_binary "$NEW_VERSION"
    fi

    # ── 2. Caddy ────────────────────────────────
    if $do_caddy; then
        echo ""
        echo -e "${BOLD}─── Caddy ─────────────────────────────────────────────${RESET}"
        update_caddy_binary
    fi

    # ── 3. ws script ────────────────────────────
    if $do_script; then
        echo ""
        echo -e "${BOLD}─── Script (ws command) ───────────────────────────────${RESET}"
        install_ws_command
    fi

    # ── restart services if wstunnel was updated ──
    if $do_wstunnel; then
        echo ""
        for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
            info "Restarting ${svc} ..."
            systemctl start "$svc"
            systemctl status "$svc" --no-pager
            echo ""
        done
    fi

    echo ""
    success "Update complete."
    local wb; wb=$(wstunnel_bin)
    local cb; cb=$(caddy_bin)
    $do_wstunnel && [ -n "$wb" ] && info "  wstunnel : $("$wb" --version 2>&1 | head -n1)"
    $do_caddy    && [ -n "$cb" ] && info "  Caddy    : $("$cb" version 2>/dev/null | head -n1)"
    $do_script   && info "  ws       : ${WS_BIN}  (type 'ws' to relaunch)"
}

# ─────────────────────────────────────────────
# Manual Restart
# ─────────────────────────────────────────────
flow_restart() {
    echo ""
    declare -a FOUND_SVCS=()
    detect_services FOUND_SVCS

    if [ ${#FOUND_SVCS[@]} -eq 0 ]; then
        warn "No wstunnel services found on this machine."
        return
    fi

    local has_server=false
    for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
        [[ "$svc" == *server* ]] && has_server=true
    done
    local caddy_active=false
    $has_server && systemctl is-enabled caddy &>/dev/null 2>&1 && caddy_active=true

    echo -e "${BOLD}─── Services to restart ───────────────────────────────${RESET}"
    echo ""
    for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
        local st; st=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        echo -e "  ${CYAN}${svc}${RESET}  [${st}]"
    done
    $caddy_active && echo -e "  ${CYAN}caddy.service${RESET}  [$(systemctl is-active caddy 2>/dev/null || echo inactive)]"
    echo ""
    confirm "Restart all services listed above?" || { info "Aborted."; return; }
    echo ""

    for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
        info "Restarting ${svc} ..."
        if systemctl restart "$svc" 2>/dev/null; then
            success "${svc} restarted."
        else
            warn "Failed to restart ${svc} — check: journalctl -u ${svc} -n 20"
        fi
    done

    if $caddy_active; then
        echo ""
        info "Restarting Caddy..."
        if systemctl restart caddy 2>/dev/null; then
            success "Caddy restarted."
        else
            warn "Failed to restart Caddy — check: journalctl -u caddy -n 20"
        fi
    fi

    echo ""
    echo -e "${BOLD}─── Status ────────────────────────────────────────────${RESET}"
    echo ""
    for svc in "${FOUND_SVCS[@]+"${FOUND_SVCS[@]}"}"; do
        systemctl status "$svc" --no-pager -l 2>/dev/null | head -6
        echo ""
    done
    if $caddy_active; then
        systemctl status caddy --no-pager -l 2>/dev/null | head -6
        echo ""
    fi
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

    # ── restart timer detection ─────────────────
    local server_timer_exists=false client_timer_exists=false
    [ -f "/etc/systemd/system/wstunnel-server-restart.timer" ] && server_timer_exists=true
    [ -f "/etc/systemd/system/wstunnel-client-restart.timer" ] && client_timer_exists=true

    # ── ws shortcut detection ───────────────────
    local ws_shortcut_exists=false
    [ -f "$WS_BIN" ] && ws_shortcut_exists=true

    # ── CA cert detection (Foreign VPS) ─────────
    local ca_cert_exists=false
    ls /usr/local/share/ca-certificates/caddy*.crt &>/dev/null 2>&1 && ca_cert_exists=true

    # ── sysctl tuning detection (Iran VPS) ──────
    local sysctl_tuning_exists=false
    grep -q "^net.ipv4.tcp_max_syn_backlog" /etc/sysctl.conf 2>/dev/null && sysctl_tuning_exists=true

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
        && ! $caddy_ours_binary && ! $caddy_ours_apt \
        && ! $server_timer_exists && ! $client_timer_exists \
        && ! $ws_shortcut_exists; then
        info "Nothing to remove — wstunnel is not installed on this machine."; return
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
    $server_timer_exists  && echo -e "  ${CYAN}restart timer${RESET}     wstunnel-server-restart.{timer,service}"
    $client_timer_exists  && echo -e "  ${CYAN}restart timer${RESET}     wstunnel-client-restart.{timer,service}"
    $ws_shortcut_exists   && echo -e "  ${CYAN}ws shortcut${RESET}       ${WS_BIN}"
    $ca_cert_exists       && echo -e "  ${CYAN}Caddy CA cert${RESET}     /usr/local/share/ca-certificates/caddy*.crt  (+ update-ca-certificates)"
    $sysctl_tuning_exists && echo -e "  ${CYAN}sysctl tuning${RESET}     tcp_max_syn_backlog, netdev_max_backlog, tcp_tw_reuse, tcp_fin_timeout, tcp_syn_retries"

    if $caddy_ours_binary; then
        local cst; cst=$(systemctl is-active caddy 2>/dev/null || echo "inactive")
        echo -e "  ${CYAN}Caddy service${RESET}     /etc/systemd/system/caddy.service  [${cst}]"
        echo -e "  ${CYAN}Caddy binary${RESET}      /usr/local/bin/caddy"
        echo -e "  ${CYAN}Caddy user${RESET}        caddy  +  /var/lib/caddy/  /var/log/caddy/"
        echo -e "  ${CYAN}Caddy config${RESET}      /etc/caddy/"
    elif $caddy_ours_apt; then
        local cst; cst=$(systemctl is-active caddy 2>/dev/null || echo "inactive")
        echo -e "  ${CYAN}Caddy package${RESET}     caddy (apt remove --purge)  [${cst}]"
        echo -e "  ${CYAN}Caddy config${RESET}      /etc/caddy/  /var/lib/caddy/  /var/log/caddy/"
        echo -e "  ${CYAN}Caddy user${RESET}        caddy (user + group)"
        echo -e "  ${CYAN}Caddy apt repo${RESET}    /etc/apt/sources.list.d/caddy-stable.list"
        echo -e "  ${CYAN}              ${RESET}    /usr/share/keyrings/caddy-stable-archive-keyring.gpg"
    elif $caddy_preexisting; then
        echo -e "  ${YELLOW}Caddy pre-existed — only our reverse_proxy block will be removed from Caddyfile${RESET}"
    fi
    echo ""
    echo -e "  ${RED}All items above will be permanently removed.${RESET}"
    echo ""
    confirm "Are you sure?" || { info "Aborted."; return; }
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
        rm -rf /etc/caddy /var/lib/caddy /var/log/caddy
        if id caddy &>/dev/null; then
            userdel caddy 2>/dev/null || true
        fi
        if getent group caddy &>/dev/null; then
            groupdel caddy 2>/dev/null || true
        fi
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
        if any(('localhost:' + port) in ln or ('127.0.0.1:' + port) in ln for ln in block):
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

    # ── 3. restart timers ──────────────────────
    for _timer_type in server client; do
        local _tname="wstunnel-${_timer_type}-restart"
        if [ -f "/etc/systemd/system/${_tname}.timer" ]; then
            info "Removing restart timer: ${_tname} ..."
            systemctl stop    "${_tname}.timer"   2>/dev/null || true
            systemctl disable "${_tname}.timer"   2>/dev/null || true
            rm -f "/etc/systemd/system/${_tname}.timer"
            rm -f "/etc/systemd/system/${_tname}.service"
            success "Removed ${_tname} timer."
        fi
    done

    # ── 4. systemctl reload ─────────────────────
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    # ── 5. wstunnel binary ──────────────────────
    if $wstunnel_bin_exists; then
        rm -f "$wbin"
        success "Removed ${wbin}"
    fi

    # ── 6. wstunnel user ────────────────────────
    if $wstunnel_user_exists; then
        rm -rf /home/wstunnel
        userdel wstunnel 2>/dev/null || true
        success "Removed user 'wstunnel' and /home/wstunnel/"
    fi

    # ── 7. ws shortcut ──────────────────────────
    if $ws_shortcut_exists; then
        rm -f "$WS_BIN"
        success "Removed ${WS_BIN}"
    fi

    # ── 8. Caddy CA cert (Foreign VPS) ──────────
    if $ca_cert_exists; then
        info "Removing Caddy CA certificate from system trust store..."
        rm -f /usr/local/share/ca-certificates/caddy*.crt
        update-ca-certificates 2>/dev/null || true
        success "Caddy CA cert removed and system CA bundle updated."
    fi

    # ── 9. sysctl tuning (Iran VPS) ─────────────
    if $sysctl_tuning_exists; then
        info "Removing kernel TCP tuning from /etc/sysctl.conf..."
        local _sysctl_conf="/etc/sysctl.conf"
        for _key in net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog \
                    net.ipv4.tcp_syn_retries net.ipv4.tcp_fin_timeout net.ipv4.tcp_tw_reuse; do
            sed -i "/^${_key}/d" "$_sysctl_conf" 2>/dev/null || true
        done
        sysctl -p &>/dev/null || true
        success "Kernel TCP tuning parameters removed."
    fi

    echo ""
    success "wstunnel and all related components removed from this machine."
}

# ─────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────
main() {
    check_root
    _show_header

    while true; do
        echo -e "  Quick install:"
        echo -e "  ${CYAN}bash <(curl -fsSL https://raw.githubusercontent.com/Samr002/black-box/main/setup.sh)${RESET}"
        echo ""
        echo -e "${BOLD}What would you like to do?${RESET}"
        echo ""
        pick_action ACTION

        case "$ACTION" in
            server)    flow_server;    _press_enter ;;
            client)    flow_client;    _press_enter ;;
            diagnose)  flow_diagnose;  _press_enter ;;
            edit)      flow_edit ;;
            update)    flow_update;    _press_enter ;;
            restart)   flow_restart;   _press_enter ;;
            uninstall) flow_uninstall; exit 0 ;;
        esac

        _show_header
    done
}

main "$@"
