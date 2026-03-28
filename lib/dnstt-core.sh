#!/bin/bash
###############################################################################
#  XxXjihad :: DNSTT CORE ENGINE v5.0                                         #
#  DNSTT install/manage/uninstall, watchdog, heartbeat, UDP-Custom, rate-limit#
#  DNS Smart System with deSEC.io API                                         #
###############################################################################

# ========================= PATHS & CONSTANTS ================================
XXJIHAD_DIR="/etc/xxjihad"
XXJIHAD_LOG="/var/log/xxjihad"
XXJIHAD_RUN="/var/run/xxjihad"
XXJIHAD_BIN="/usr/local/bin"

DNSTT_BIN="${XXJIHAD_BIN}/dnstt-server"
DNSTT_KEYS="${XXJIHAD_DIR}/dnstt/keys"
DNSTT_CONF="${XXJIHAD_DIR}/dnstt/dnstt.conf"
DNSTT_SERVICE="/etc/systemd/system/xxjihad-dnstt.service"
DNSTT_WATCHDOG_SERVICE="/etc/systemd/system/xxjihad-watchdog.service"
DNSTT_HEARTBEAT_SERVICE="/etc/systemd/system/xxjihad-heartbeat.service"

UDP_DIR="${XXJIHAD_DIR}/udp-custom"
UDP_BIN="${UDP_DIR}/udp-custom"
UDP_CONF="${UDP_DIR}/config.json"
UDP_SERVICE="/etc/systemd/system/xxjihad-udp-custom.service"

CLEANER_SERVICE="/etc/systemd/system/xxjihad-cleaner.service"
CLEANER_TIMER="/etc/systemd/system/xxjihad-cleaner.timer"

# SSL Tunnel / HAProxy - Edge Stack Architecture
HAPROXY_CONFIG="/etc/haproxy/haproxy.cfg"
SSL_CERT_DIR="${XXJIHAD_DIR}/ssl"
SSL_CERT_FILE="${SSL_CERT_DIR}/xxjihad.pem"
SSL_CERT_CHAIN_FILE="${SSL_CERT_DIR}/xxjihad.crt"
SSL_CERT_KEY_FILE="${SSL_CERT_DIR}/xxjihad.key"
EDGE_CERT_INFO_FILE="${XXJIHAD_DIR}/db/edge_cert.conf"
EDGE_PUBLIC_HTTP_PORT="80"
EDGE_PUBLIC_TLS_PORT="443"
NGINX_INTERNAL_HTTP_PORT="8880"
NGINX_INTERNAL_TLS_PORT="8443"
HAPROXY_INTERNAL_DECRYPT_PORT="10443"

# Falcon Proxy
FALCONPROXY_SERVICE_FILE="/etc/systemd/system/falconproxy.service"
FALCONPROXY_BINARY="${XXJIHAD_BIN}/falconproxy"
FALCONPROXY_CONFIG_FILE="${XXJIHAD_DIR}/db/falconproxy_config.conf"

# ZiVPN
ZIVPN_DIR="/etc/zivpn"
ZIVPN_BIN="${XXJIHAD_BIN}/zivpn"
ZIVPN_SERVICE_FILE="/etc/systemd/system/zivpn.service"
ZIVPN_CONFIG_FILE="${ZIVPN_DIR}/config.json"
ZIVPN_CERT_FILE="${ZIVPN_DIR}/zivpn.crt"
ZIVPN_KEY_FILE="${ZIVPN_DIR}/zivpn.key"

# Nginx
NGINX_CONFIG_FILE="/etc/nginx/sites-available/default"
NGINX_PORTS_FILE="${XXJIHAD_DIR}/db/nginx_ports.conf"

# DNS Smart System (deSEC.io)
_D_T_E="R2dhbmpjMnZVTW9HTkZ0eU5WVXFoYzhjUUphMg=="
DESEC_TOKEN=$(echo "$_D_T_E" | base64 -d)
DESEC_DOMAIN="02iuk.shop"
DNS_INFO_FILE="${XXJIHAD_DIR}/db/dns_info.conf"

# SSH Banner
SSH_BANNER_FILE="/etc/bannerssh"

# Bandwidth
BANDWIDTH_DIR="${XXJIHAD_DIR}/bandwidth"

# Binary download URLs (verified working 200 OK)
DNSTT_URL_AMD64="https://dnstt.network/dnstt-server-linux-amd64"
DNSTT_URL_ARM64="https://dnstt.network/dnstt-server-linux-arm64"

UDP_URL_AMD64="https://github.com/firewallfalcons/FirewallFalcon-Manager/raw/main/udp/udp-custom-linux-amd64"
UDP_URL_ARM64="https://github.com/firewallfalcons/FirewallFalcon-Manager/raw/main/udp/udp-custom-linux-arm"

# Smart defaults
SMART_MTU="500"
SMART_FWD_PORT="22"
SMART_UDP_PORT="36712"

# Uninstall mode
UNINSTALL_MODE="${UNINSTALL_MODE:-interactive}"

# ========================= COLORS (Cyan/White Theme) =========================
CR=$'\033[0m'; CB=$'\033[1m'; CD=$'\033[2m'
RED=$'\033[38;5;196m'; GRN=$'\033[38;5;46m'; YLW=$'\033[38;5;226m'
BLU=$'\033[38;5;39m'; PRP=$'\033[38;5;135m'; CYN=$'\033[38;5;51m'
WHT=$'\033[38;5;255m'; GRY=$'\033[38;5;245m'; ORG=$'\033[38;5;208m'

# ========================= LOGGING ==========================================
_log() { mkdir -p "$XXJIHAD_LOG" 2>/dev/null; echo "[$(date '+%F %T')] [$1] $2" >> "$XXJIHAD_LOG/xxjihad.log"; }
log_i() { _log "INFO" "$*"; }
log_w() { _log "WARN" "$*"; }
log_e() { _log "ERROR" "$*"; }

msg_ok()   { echo -e " ${GRN}[OK]${CR} $*"; }
msg_err()  { echo -e " ${RED}[ERROR]${CR} $*"; }
msg_warn() { echo -e " ${YLW}[WARN]${CR} $*"; }
msg_info() { echo -e " ${BLU}[INFO]${CR} $*"; }

die() { msg_err "$1"; log_e "$1"; exit "${2:-1}"; }

# ========================= HELPERS ==========================================
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) die "Unsupported architecture: $(uname -m)" ;;
    esac
}

is_valid_ip4() { [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; }

get_public_ip4() {
    local ip
    for svc in "https://icanhazip.com" "https://api.ipify.org" "https://ifconfig.me/ip"; do
        ip=$(curl -s -4 --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        is_valid_ip4 "$ip" && { echo "$ip"; return 0; }
    done
    return 1
}

port_free() {
    ! ss -lntu 2>/dev/null | grep -qE ":${1}\b"
}

is_dnstt_installed() {
    [[ -f "$DNSTT_SERVICE" && -f "$DNSTT_BIN" && -f "$DNSTT_CONF" ]]
}

is_udp_installed() {
    [[ -f "$UDP_SERVICE" ]]
}

init_dirs() {
    mkdir -p "$XXJIHAD_DIR"/{dnstt/keys,dns,udp-custom,network,ssl,db,backups,rate_limit,bandwidth,banners} \
             "$XXJIHAD_LOG" "$XXJIHAD_RUN" 2>/dev/null
    [[ -f "$XXJIHAD_DIR/db/users.db" ]] || touch "$XXJIHAD_DIR/db/users.db"
    chmod 600 "$XXJIHAD_DIR/db/users.db" 2>/dev/null
}

install_deps() {
    local missing=()
    for cmd in curl wget jq bc openssl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    command -v dig &>/dev/null || missing+=("dnsutils")
    if [[ ${#missing[@]} -gt 0 ]]; then
        msg_info "Installing dependencies: ${missing[*]}"
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 || {
            msg_err "Failed to install some dependencies"; return 1
        }
    fi
    msg_ok "All dependencies ready"
}

check_and_open_firewall_port() {
    local port="$1" protocol="${2:-tcp}"
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$port/$protocol" >/dev/null 2>&1
    fi
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --add-port="$port/$protocol" --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
    iptables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null
}

check_and_free_ports() {
    local port
    for port in "$@"; do
        if ! port_free "$port"; then
            msg_warn "Port $port is in use."
            local pids
            pids=$(ss -lntp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | sort -u)
            for pid in $pids; do
                local proc_name
                proc_name=$(ps -p "$pid" -o comm= 2>/dev/null)
                if [[ "$proc_name" != "sshd" && "$proc_name" != "systemd" && "$proc_name" != "bash" ]]; then
                    kill -9 "$pid" 2>/dev/null
                fi
            done
            sleep 1
            if ! port_free "$port"; then
                msg_err "Could not free port $port"
                return 1
            fi
            msg_ok "Port $port freed"
        fi
    done
    return 0
}

detect_preferred_host() {
    local ip4
    ip4=$(get_public_ip4 2>/dev/null)
    if [[ -f "$DNS_INFO_FILE" ]]; then
        local managed_domain
        managed_domain=$(grep 'FULL_DOMAIN' "$DNS_INFO_FILE" | cut -d'"' -f2)
        [[ -n "$managed_domain" ]] && { echo "$managed_domain"; return; }
    fi
    if [[ -f "$NGINX_CONFIG_FILE" ]]; then
        local nginx_domain
        nginx_domain=$(grep -oP 'server_name \K[^\s;]+' "$NGINX_CONFIG_FILE" | head -n 1)
        [[ "$nginx_domain" != "_" && -n "$nginx_domain" ]] && { echo "$nginx_domain"; return; }
    fi
    echo "${ip4:-localhost}"
}

# ========================= PORT 53 MANAGEMENT ================================
free_port_53() {
    if port_free 53; then
        msg_ok "Port 53 is available"
        return 0
    fi
    msg_info "Freeing port 53..."

    # 1. Ensure SSH port is allowed before any changes
    fw_allow 22 tcp

    # 2. Stop and disable systemd-resolved completely (like reference project)
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        msg_info "Stopping and disabling systemd-resolved to free port 53..."
        systemctl stop systemd-resolved >/dev/null 2>&1
        systemctl disable systemd-resolved >/dev/null 2>&1
    fi

    # 3. Safe resolv.conf update
    chattr -i /etc/resolv.conf 2>/dev/null
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<'RESOLV'
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLV
    chattr +i /etc/resolv.conf 2>/dev/null

    # 4. Check if port 53 is now free
    sleep 1
    if port_free 53; then
        msg_ok "Port 53 freed successfully"
        return 0
    fi

    # 5. Force kill only non-critical processes on port 53
    local pids
    pids=$(ss -lunp 2>/dev/null | grep ':53 ' | grep -oP 'pid=\K[0-9]+' | sort -u)
    for pid in $pids; do
        local proc_name
        proc_name=$(ps -p "$pid" -o comm= 2>/dev/null)
        if [[ "$proc_name" != "sshd" && "$proc_name" != "systemd" && "$proc_name" != "bash" ]]; then
            kill -9 "$pid" 2>/dev/null
        fi
    done

    sleep 1
    if port_free 53; then
        msg_ok "Port 53 freed (force)"
        return 0
    fi

    msg_err "Port 53 is still occupied. Please check manually with 'ss -lunp | grep :53'"
    return 1
}

fw_allow() {
    local port="$1" proto="${2:-udp}"
    check_and_open_firewall_port "$port" "$proto"
}

# ========================= DNSTT BINARY MANAGEMENT ===========================
download_binary() {
    local url="$1" dest="$2" name="$3" min_size="${4:-100000}"
    local tmp="/tmp/${name}.download.$$"
    for attempt in 1 2 3; do
        msg_info "Downloading $name (attempt $attempt/3)..."
        if curl -sL --max-time 120 --retry 2 -o "$tmp" "$url" 2>/dev/null; then
            local sz
            sz=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
            if [[ $sz -gt $min_size ]]; then
                mv "$tmp" "$dest"
                chmod +x "$dest"
                msg_ok "$name downloaded ($sz bytes)"
                return 0
            fi
            msg_warn "Download too small ($sz bytes), retrying..."
        else
            msg_warn "Download failed, retrying..."
        fi
        sleep 2
    done
    rm -f "$tmp"
    return 1
}

download_dnstt() {
    local arch
    arch=$(detect_arch)
    local url=""
    [[ "$arch" == "amd64" ]] && url="$DNSTT_URL_AMD64" || url="$DNSTT_URL_ARM64"
    download_binary "$url" "$DNSTT_BIN" "dnstt-server" 2000000
}

generate_keys() {
    mkdir -p "$DNSTT_KEYS"
    "$DNSTT_BIN" -gen-key -privkey-file "${DNSTT_KEYS}/server.key" -pubkey-file "${DNSTT_KEYS}/server.pub" >/dev/null 2>&1
    if [[ -f "${DNSTT_KEYS}/server.pub" ]]; then
        cat "${DNSTT_KEYS}/server.pub"
    fi
}

# ========================= DNS SMART SYSTEM (deSEC.io) =======================
create_dns_records_auto() {
    local ip="$1"
    local rand_id
    rand_id=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 12)
    local ns_sub="ns-${rand_id}"
    local tun_sub="tun-${rand_id}"

    msg_info "Configuring DNS records via deSEC.io API..."

    # 1. Create NS Record (A)
    local res1
    res1=$(curl -s -X POST "https://desec.io/api/v1/domains/${DESEC_DOMAIN}/rrsets/" \
        -H "Authorization: Token ${DESEC_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"subname\":\"${ns_sub}\",\"type\":\"A\",\"ttl\":3600,\"records\":[\"${ip}\"]}")

    # 2. Create Tunnel Record (NS)
    local res2
    res2=$(curl -s -X POST "https://desec.io/api/v1/domains/${DESEC_DOMAIN}/rrsets/" \
        -H "Authorization: Token ${DESEC_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"subname\":\"${tun_sub}\",\"type\":\"NS\",\"ttl\":3600,\"records\":[\"${ns_sub}.${DESEC_DOMAIN}.\"]}")

    if echo "$res1" | grep -q "subname" && echo "$res2" | grep -q "subname"; then
        msg_ok "DNS records created successfully!"
        echo -e "   NS Domain:     ${YLW}${ns_sub}.${DESEC_DOMAIN}${CR}"
        echo -e "   Tunnel Domain: ${YLW}${tun_sub}.${DESEC_DOMAIN}${CR}"
        _DNS_NS_DOMAIN="${ns_sub}.${DESEC_DOMAIN}"
        _DNS_TUNNEL_DOMAIN="${tun_sub}.${DESEC_DOMAIN}"
        _DNS_NS_SUBDOMAIN="${ns_sub}"
        _DNS_TUNNEL_SUBDOMAIN="${tun_sub}"
        _DNS_MANAGED="true"
        _DNS_HAS_IPV6="false"

        mkdir -p "$(dirname "$DNS_INFO_FILE")"
        cat > "$DNS_INFO_FILE" <<DNSCONF
FULL_DOMAIN="${_DNS_TUNNEL_DOMAIN}"
NS_DOMAIN="${_DNS_NS_DOMAIN}"
NS_SUB="${ns_sub}"
TUNNEL_SUB="${tun_sub}"
VPS_IP="${ip}"
DNSCONF
        return 0
    else
        msg_err "Failed to create DNS records. API Response: $res1 $res2"
        return 1
    fi
}

delete_dns_records() {
    [[ ! -f "$DNS_INFO_FILE" ]] && return
    source "$DNS_INFO_FILE"
    msg_info "Deleting DNS records from deSEC.io..."
    curl -s -X DELETE "https://desec.io/api/v1/domains/${DESEC_DOMAIN}/rrsets/${NS_SUB}/A/" -H "Authorization: Token ${DESEC_TOKEN}" >/dev/null
    curl -s -X DELETE "https://desec.io/api/v1/domains/${DESEC_DOMAIN}/rrsets/${TUNNEL_SUB}/NS/" -H "Authorization: Token ${DESEC_TOKEN}" >/dev/null
    rm -f "$DNS_INFO_FILE"
}

# ========================= DNSTT INSTALLATION ================================
install_dnstt() {
    echo ""
    echo -e " ${CB}${CYN}============================================${CR}"
    echo -e " ${CB}${CYN}      DNSTT (DNS Tunnel) Installation       ${CR}"
    echo -e " ${CB}${CYN}============================================${CR}"
    echo ""

    if is_dnstt_installed; then
        msg_warn "DNSTT is already installed and configured."
        show_dnstt_info
        echo ""
        read -rp " Reinstall? (y/n) [n]: " confirm_re
        [[ ! "$confirm_re" =~ ^[Yy]$ ]] && return 0
        msg_info "Stopping existing DNSTT for reinstall..."
        systemctl stop xxjihad-dnstt 2>/dev/null
    fi

    # Step 1: Dependencies
    msg_info "Step 1/7: Checking dependencies..."
    install_deps || return 1

    # Step 2: Port 53
    msg_info "Step 2/7: Preparing port 53..."
    free_port_53 || return 1
    fw_allow 53 udp
    fw_allow 53 tcp

    # Step 3: Forward target
    echo ""
    echo -e " ${BLU}Where should DNSTT forward traffic?${CR}"
    echo -e "   ${GRN}[1]${CR} SSH (port 22)         ${GRY}<-- Smart Default${CR}"
    echo -e "   ${GRN}[2]${CR} V2Ray backend (port 8787)"
    echo -e "   ${GRN}[3]${CR} Custom port"
    echo ""
    read -rp " Choice [Enter=1]: " fwd_choice
    fwd_choice=${fwd_choice:-1}

    local fwd_port="22" fwd_desc="SSH (22)"
    case $fwd_choice in
        1) fwd_port="22"; fwd_desc="SSH (22)" ;;
        2) fwd_port="8787"; fwd_desc="V2Ray (8787)" ;;
        3) read -rp " Enter custom port: " fwd_port; fwd_desc="Custom ($fwd_port)" ;;
    esac
    msg_ok "Forward target: $fwd_desc"

    # Step 4: DNS Configuration
    echo ""
    echo -e " ${BLU}DNS Configuration:${CR}"
    echo -e "   ${GRN}[1]${CR} Auto-generate DNS records (deSEC.io)  ${GRY}<-- Recommended${CR}"
    echo -e "   ${GRN}[2]${CR} Use custom DNS records"
    echo ""
    read -rp " Choice [Enter=1]: " dns_choice
    dns_choice=${dns_choice:-1}

    local ns_domain="" tunnel_domain=""
    local DNSTT_RECORDS_MANAGED="false"
    local NS_SUBDOMAIN="" TUNNEL_SUBDOMAIN="" HAS_IPV6="false"

    if [[ "$dns_choice" == "1" ]]; then
        local server_ipv4
        server_ipv4=$(get_public_ip4)
        if [[ -z "$server_ipv4" ]]; then
            msg_err "Could not detect public IPv4. Cannot auto-configure DNS."
            return 1
        fi

        create_dns_records_auto "$server_ipv4" || return 1

        ns_domain="$_DNS_NS_DOMAIN"
        tunnel_domain="$_DNS_TUNNEL_DOMAIN"
        NS_SUBDOMAIN="$_DNS_NS_SUBDOMAIN"
        TUNNEL_SUBDOMAIN="$_DNS_TUNNEL_SUBDOMAIN"
        DNSTT_RECORDS_MANAGED="$_DNS_MANAGED"
        HAS_IPV6="$_DNS_HAS_IPV6"
    else
        echo ""
        echo -e " ${GRY}You need 2 DNS records configured BEFORE this step:${CR}"
        echo -e "   ${YLW}A Record${CR}:  ns.yourdomain.com  ->  Your VPS IP"
        echo -e "   ${YLW}NS Record${CR}: tun.yourdomain.com ->  ns.yourdomain.com"
        echo ""
        read -rp " Enter NS domain (e.g., ns1.example.com): " ns_domain
        [[ -z "$ns_domain" ]] && { msg_err "NS domain is required."; return 1; }
        read -rp " Enter Tunnel domain (e.g., tun.example.com): " tunnel_domain
        [[ -z "$tunnel_domain" ]] && { msg_err "Tunnel domain is required."; return 1; }
    fi

    msg_ok "NS: $ns_domain | Tunnel: $tunnel_domain"

    # Step 5: MTU
    echo ""
    read -rp " MTU value [Enter=${SMART_MTU} Smart Default]: " mtu_val
    mtu_val=${mtu_val:-$SMART_MTU}
    if [[ ! "$mtu_val" =~ ^[0-9]+$ ]]; then
        msg_warn "Invalid MTU, using default: $SMART_MTU"
        mtu_val="$SMART_MTU"
    fi
    msg_ok "MTU: $mtu_val"

    # Step 5b: Padding (Anti-DPI) - Ask BEFORE creating service
    read -rp " Enable DNSTT Padding for Anti-DPI? (y/n) [n]: " enable_padding
    local padding_flag=""
    if [[ "$enable_padding" =~ ^[Yy]$ ]]; then
        padding_flag="-padding 128"
        msg_ok "Padding enabled (128 bytes)"
    fi

    # Step 6: Download binary
    msg_info "Step 3/7: Downloading DNSTT binary..."
    if [[ -f "$DNSTT_BIN" && -x "$DNSTT_BIN" ]]; then
        msg_ok "DNSTT binary already exists, skipping download"
    else
        download_dnstt || return 1
    fi

    if ! "$DNSTT_BIN" -help 2>&1 | grep -qi "usage\|dnstt\|gen-key"; then
        msg_err "DNSTT binary is corrupted or incompatible"
        rm -f "$DNSTT_BIN"
        return 1
    fi
    msg_ok "DNSTT binary verified"

    # Step 7: Generate keys
    msg_info "Step 4/7: Generating cryptographic keys..."
    local pub_key
    pub_key=$(generate_keys 2>/dev/null | tail -1)
    if [[ -z "$pub_key" || ! -f "$DNSTT_KEYS/server.key" ]]; then
        msg_err "Key generation failed"
        return 1
    fi
    msg_ok "Keys generated"

    # Create systemd service (padding_flag is now defined)
    # FIX: Corrected command order to ensure -udp :53 is followed by mandatory arguments
    msg_info "Step 5/7: Creating systemd service..."
    cat > "$DNSTT_SERVICE" <<SVCEOF
[Unit]
Description=XxXjihad DNSTT Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
    ExecStart=${DNSTT_BIN} -udp :53 -privkey-file ${DNSTT_KEYS}/server.key -mtu ${mtu_val} ${padding_flag} ${tunnel_domain} 127.0.0.1:${fwd_port}
Restart=always
RestartSec=3
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

    # Step 6: Save config
    msg_info "Step 6/7: Saving configuration..."

    mkdir -p "$(dirname "$DNSTT_CONF")"
    cat > "$DNSTT_CONF" <<CONFEOF
NS_SUBDOMAIN="${NS_SUBDOMAIN}"
TUNNEL_SUBDOMAIN="${TUNNEL_SUBDOMAIN}"
NS_DOMAIN="${ns_domain}"
TUNNEL_DOMAIN="${tunnel_domain}"
PUBLIC_KEY="${pub_key}"
FORWARD_PORT="${fwd_port}"
FORWARD_DESC="${fwd_desc}"
MTU_VALUE="${mtu_val}"
DNSTT_RECORDS_MANAGED="${DNSTT_RECORDS_MANAGED}"
HAS_IPV6="${HAS_IPV6}"
DNSTT_PADDING="${padding_flag}"
INSTALL_DATE="$(date '+%F %T')"
CONFEOF

    # Step 7: Start service
    msg_info "Step 7/7: Starting DNSTT service..."
    systemctl daemon-reload
    systemctl enable xxjihad-dnstt.service >/dev/null 2>&1
    systemctl start xxjihad-dnstt.service
    sleep 3

    if systemctl is-active --quiet xxjihad-dnstt.service; then
        msg_ok "DNSTT is running!"
        echo ""
        show_dnstt_info
        echo ""
        install_watchdog
        install_heartbeat
        apply_rate_limiting
        echo ""
        msg_ok "Installation complete! All services are active."
    else
        msg_err "DNSTT failed to start. Diagnostics:"
        echo ""
        journalctl -u xxjihad-dnstt.service -n 15 --no-pager 2>/dev/null
        return 1
    fi
}

# ========================= DNSTT INFO DISPLAY ================================
show_dnstt_info() {
    if [[ ! -f "$DNSTT_CONF" ]]; then
        msg_warn "DNSTT is not installed. No configuration found."
        return 1
    fi

    local _ns _tun _key _fport _fdesc _mtu _date
    _ns=$(grep '^NS_DOMAIN=' "$DNSTT_CONF" 2>/dev/null | cut -d'"' -f2)
    _tun=$(grep '^TUNNEL_DOMAIN=' "$DNSTT_CONF" 2>/dev/null | cut -d'"' -f2)
    _key=$(grep '^PUBLIC_KEY=' "$DNSTT_CONF" 2>/dev/null | cut -d'"' -f2)
    _fport=$(grep '^FORWARD_PORT=' "$DNSTT_CONF" 2>/dev/null | cut -d'"' -f2)
    _fdesc=$(grep '^FORWARD_DESC=' "$DNSTT_CONF" 2>/dev/null | cut -d'"' -f2)
    _mtu=$(grep '^MTU_VALUE=' "$DNSTT_CONF" 2>/dev/null | cut -d'"' -f2)
    _date=$(grep '^INSTALL_DATE=' "$DNSTT_CONF" 2>/dev/null | cut -d'"' -f2)

    local status_text="${RED}STOPPED${CR}"
    local status_icon="${RED}X${CR}"
    if systemctl is-active --quiet xxjihad-dnstt.service 2>/dev/null; then
        status_text="${GRN}RUNNING${CR}"
        status_icon="${GRN}*${CR}"
    fi

    local ip4
    ip4=$(get_public_ip4 2>/dev/null || echo "N/A")

    echo -e " ${CYN}+====================================================+${CR}"
    echo -e " ${CYN}|         DNSTT Connection Information                |${CR}"
    echo -e " ${CYN}+====================================================+${CR}"
    echo -e " ${CYN}|${CR} Status:       [$status_icon] $status_text"
    echo -e " ${CYN}|${CR} Server IP:    ${YLW}${ip4}${CR}"
    echo -e " ${CYN}|${CR} NS Domain:    ${YLW}${_ns}${CR}"
    echo -e " ${CYN}|${CR} Tunnel:       ${YLW}${_tun}${CR}"
    echo -e " ${CYN}|${CR} Public Key:   ${YLW}${_key}${CR}"
    echo -e " ${CYN}|${CR} Forward To:   ${WHT}127.0.0.1:${_fport} (${_fdesc})${CR}"
    echo -e " ${CYN}|${CR} MTU:          ${WHT}${_mtu}${CR}"
    echo -e " ${CYN}|${CR} Installed:    ${GRY}${_date}${CR}"
    echo -e " ${CYN}+====================================================+${CR}"

    if [[ "$_fdesc" == *"V2Ray"* ]]; then
        echo -e " ${CYN}|${CR} ${YLW}Note: Ensure V2Ray service listens on port ${_fport} (no TLS)${CR}"
    fi
}

# ========================= DNSTT UNINSTALL ===================================
uninstall_dnstt() {
    echo ""
    echo -e " ${CB}${RED}--- Uninstall DNSTT ---${CR}"

    if ! is_dnstt_installed && [[ ! -f "$DNSTT_SERVICE" ]]; then
        msg_warn "DNSTT is not installed. Nothing to uninstall."
        return 0
    fi

    if [[ "$UNINSTALL_MODE" != "silent" ]]; then
        echo -e " ${YLW}This will remove DNSTT, Watchdog, and Heartbeat services.${CR}"
        read -rp " Are you sure? (y/n): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && { msg_warn "Cancelled"; return 0; }
    fi

    delete_dns_records

    msg_info "Stopping services..."
    for svc in xxjihad-dnstt xxjihad-watchdog xxjihad-heartbeat; do
        systemctl stop "${svc}.service" 2>/dev/null
        systemctl disable "${svc}.service" 2>/dev/null
    done

    msg_info "Removing files..."
    rm -f "$DNSTT_SERVICE" "$DNSTT_WATCHDOG_SERVICE" "$DNSTT_HEARTBEAT_SERVICE"
    rm -f "$DNSTT_BIN"
    rm -f "${XXJIHAD_BIN}/xxjihad-watchdog" "${XXJIHAD_BIN}/xxjihad-heartbeat"
    rm -rf "$DNSTT_KEYS"
    rm -f "$DNSTT_CONF"
    systemctl daemon-reload

    remove_rate_limiting 2>/dev/null
    chattr -i /etc/resolv.conf 2>/dev/null

    msg_ok "DNSTT completely uninstalled"
    log_i "DNSTT uninstalled by user"
}

# ========================= WATCHDOG (Auto-Healing) ===========================
install_watchdog() {
    msg_info "Installing Advanced Watchdog (Port Response & Auto-Healing)..."

    cat > "${XXJIHAD_BIN}/xxjihad-watchdog" <<'WDEOF'
#!/bin/bash
LOG="/var/log/xxjihad/watchdog.log"
MAX_RESTARTS=10
restart_count=0
cooldown_until=0
mkdir -p "$(dirname "$LOG")"
log_wd() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

clear_cache() {
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
}

check_port_response() {
    local port=$1 proto=$2
    if [[ "$proto" == "udp" ]]; then
        nc -z -u -w 2 127.0.0.1 "$port" >/dev/null 2>&1
        return $?
    else
        nc -z -w 2 127.0.0.1 "$port" >/dev/null 2>&1
        return $?
    fi
}

while true; do
    now=$(date +%s)
    if [[ $restart_count -ge $MAX_RESTARTS && $now -lt $cooldown_until ]]; then
        sleep 5; continue
    fi
    [[ $now -ge $cooldown_until ]] && restart_count=0

    # 1. Check DNSTT (Port 53 UDP)
    if [[ -f /etc/systemd/system/xxjihad-dnstt.service ]]; then
        is_active=$(systemctl is-active --quiet xxjihad-dnstt.service; echo $?)
        port_ok=$(check_port_response 53 "udp"; echo $?)

        if [[ $is_active -ne 0 || $port_ok -ne 0 ]]; then
            restart_count=$((restart_count + 1))
            log_wd "DNSTT issue detected (Active: $is_active, Port 53: $port_ok)! Restarting..."
            systemctl restart xxjihad-dnstt.service 2>/dev/null
            clear_cache
            sleep 2
        fi
    fi

    # 2. Check HAProxy
    if systemctl is-enabled --quiet haproxy 2>/dev/null; then
        if ! systemctl is-active --quiet haproxy; then
            log_wd "HAProxy is down! Restarting..."
            systemctl restart haproxy 2>/dev/null
        fi
    fi

    # 3. Check Nginx
    if systemctl is-enabled --quiet nginx 2>/dev/null; then
        if ! systemctl is-active --quiet nginx; then
            log_wd "Nginx is down! Restarting..."
            systemctl restart nginx 2>/dev/null
        fi
    fi

    if [[ $restart_count -ge $MAX_RESTARTS ]]; then
        log_wd "Max restarts reached. Entering cooldown for 5 minutes."
        cooldown_until=$((now + 300))
    fi
    sleep 30
done
WDEOF
    chmod +x "${XXJIHAD_BIN}/xxjihad-watchdog"

    cat > "$DNSTT_WATCHDOG_SERVICE" <<EOF
[Unit]
Description=XxXjihad Watchdog Service
After=network.target

[Service]
Type=simple
ExecStart=${XXJIHAD_BIN}/xxjihad-watchdog
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xxjihad-watchdog.service >/dev/null 2>&1
    systemctl restart xxjihad-watchdog.service
    msg_ok "Watchdog active"
}

# ========================= HEARTBEAT (Persistence) ===========================
install_heartbeat() {
    msg_info "Installing Heartbeat service..."
    cat > "${XXJIHAD_BIN}/xxjihad-heartbeat" <<'HBEOF'
#!/bin/bash
while true; do
    # Ensure port 53 isn't reclaimed by systemd-resolved
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl stop systemd-resolved >/dev/null 2>&1
        systemctl disable systemd-resolved >/dev/null 2>&1
    fi
    # Refresh firewall rules just in case
    iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null
    sleep 300
done
HBEOF
    chmod +x "${XXJIHAD_BIN}/xxjihad-heartbeat"

    cat > "$DNSTT_HEARTBEAT_SERVICE" <<EOF
[Unit]
Description=XxXjihad Heartbeat Service
After=network.target

[Service]
Type=simple
ExecStart=${XXJIHAD_BIN}/xxjihad-heartbeat
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xxjihad-heartbeat.service >/dev/null 2>&1
    systemctl restart xxjihad-heartbeat.service
    msg_ok "Heartbeat active"
}

# ========================= RATE LIMITING (Anti-Abuse) ========================
apply_rate_limiting() {
    msg_info "Applying DNSTT rate limiting (Anti-Abuse)..."
    iptables -A INPUT -p udp --dport 53 -m hashlimit --hashlimit-name dnstt-limit \
        --hashlimit-mode srcip --hashlimit-upto 100/sec --hashlimit-burst 200 -j ACCEPT 2>/dev/null
    iptables -A INPUT -p udp --dport 53 -j DROP 2>/dev/null
    msg_ok "Rate limiting applied"
}

remove_rate_limiting() {
    iptables -D INPUT -p udp --dport 53 -m hashlimit --hashlimit-name dnstt-limit \
        --hashlimit-mode srcip --hashlimit-upto 100/sec --hashlimit-burst 200 -j ACCEPT 2>/dev/null
    iptables -D INPUT -p udp --dport 53 -j DROP 2>/dev/null
}

# ========================= DNSTT MENU ========================================
dnstt_menu() {
    while true; do
        clear
        echo -e " ${CYN}=====[ ${CB}DNSTT MANAGEMENT ${CR}${CYN}]=====${CR}"
        echo ""
        if is_dnstt_installed; then
            show_dnstt_info
        else
            msg_warn "DNSTT is not installed."
        fi
        echo ""
        echo -e "   ${CYN}[ 1]${CR} Install DNSTT"
        echo -e "   ${CYN}[ 2]${CR} Show Connection Info"
        echo -e "   ${CYN}[ 3]${CR} Restart DNSTT"
        echo -e "   ${CYN}[ 4]${CR} View Logs"
        echo -e "   ${CYN}[ 5]${CR} Rotate Keys"
        echo -e "   ${RED}[ 6]${CR} Uninstall DNSTT"
        echo ""
        echo -e "   ${GRY}[ 0]${CR} Return to Main Menu"
        echo ""
        read -rp " Select an option: " choice
        case $choice in
            1) install_dnstt; echo -e "\nPress Enter to continue..."; read -r ;;
            2) show_dnstt_info; echo -e "\nPress Enter to continue..."; read -r ;;
            3)
                msg_info "Restarting DNSTT..."
                systemctl restart xxjihad-dnstt.service
                msg_ok "DNSTT restarted"
                sleep 2
                ;;
            4)
                echo -e " ${CYN}--- DNSTT Logs ---${CR}"
                journalctl -u xxjihad-dnstt.service -n 50 --no-pager
                echo -e "\nPress Enter to continue..."; read -r
                ;;
            5)
                msg_info "Rotating keys..."
                generate_keys >/dev/null
                local new_pub
                new_pub=$(cat "${DNSTT_KEYS}/server.pub" 2>/dev/null)
                sed -i "s/^PUBLIC_KEY=.*/PUBLIC_KEY=\"$new_pub\"/" "$DNSTT_CONF"
                systemctl restart xxjihad-dnstt.service
                msg_ok "Keys rotated and service restarted"
                sleep 2
                ;;
            6) uninstall_dnstt; echo -e "\nPress Enter to continue..."; read -r ;;
            0) return ;;
            *) invalid_option ;;
        esac
    done
}
