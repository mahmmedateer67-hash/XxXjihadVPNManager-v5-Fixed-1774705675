#!/bin/bash
###############################################################################
#  XxXjihad :: DNSTT & DNS SMART CORE ENGINE v5.1.0                           #
#  DNSTT, deSEC.io API Integration for SSL/VPN, UDP-Custom, Watchdog         #
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

UDP_DIR="${XXJIHAD_DIR}/udp-custom"
UDP_BIN="${UDP_DIR}/udp-custom"
UDP_SERVICE="/etc/systemd/system/xxjihad-udp-custom.service"

# DNS Smart System (deSEC.io) - Fixed Domain 02iuk.shop
_D_T_E="R2dhbmpjMnZVTW9HTkZ0eU5WVXFoYzhjUUphMg=="
DESEC_TOKEN=$(echo "$_D_T_E" | base64 -d)
DESEC_DOMAIN="02iuk.shop"
DNS_INFO_FILE="${XXJIHAD_DIR}/db/dns_info.conf"

# Verified Binary URLs (200 OK - No Login Required)
DNSTT_URL_AMD64="https://github.com/jamal7720077-debug/XxXjihadVPNManager/raw/main/bin/dnstt-server-linux-amd64"
DNSTT_URL_ARM64="https://github.com/jamal7720077-debug/XxXjihadVPNManager/raw/main/bin/dnstt-server-linux-arm64"
UDP_URL_AMD64="https://github.com/jamal7720077-debug/XxXjihadVPNManager/raw/main/bin/udp-custom-linux-amd64"
UDP_URL_ARM64="https://github.com/jamal7720077-debug/XxXjihadVPNManager/raw/main/bin/udp-custom-linux-arm"

# ========================= COLORS ===========================================
CR=$'\033[0m'; CB=$'\033[1m'; RED=$'\033[38;5;196m'; GRN=$'\033[38;5;46m'
YLW=$'\033[38;5;226m'; BLU=$'\033[38;5;39m'; CYN=$'\033[38;5;51m'; WHT=$'\033[38;5;255m'

msg_ok()   { echo -e " ${GRN}[OK]${CR} $*"; }
msg_err()  { echo -e " ${RED}[ERROR]${CR} $*"; }
msg_warn() { echo -e " ${YLW}[WARN]${CR} $*"; }
msg_info() { echo -e " ${BLU}[INFO]${CR} $*"; }

# ========================= DNS SMART API (deSEC.io) =========================
# This function creates a dynamic subdomain for any service (SSL, SSH, DNSTT)
# Prefix will always be 'xxjihad-' followed by a random string.
create_smart_dns() {
    local type="${1:-vpn}" # vpn, ssl, dnstt
    local ip=$(curl -s -4 icanhazip.com || echo "127.0.0.1")
    local rand_id=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 6)
    local subname="xxjihad-${type}-${rand_id}"
    local full_domain="${subname}.${DESEC_DOMAIN}"

    msg_info "Creating Smart DNS for ${type}: ${full_domain}..."

    # Create A Record
    local res
    res=$(curl -s -X POST "https://desec.io/api/v1/domains/${DESEC_DOMAIN}/rrsets/" \
        -H "Authorization: Token ${DESEC_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"subname\":\"${subname}\",\"type\":\"A\",\"ttl\":3600,\"records\":[\"${ip}\"]}")

    if echo "$res" | grep -q "subname"; then
        msg_ok "Smart DNS created: ${full_domain}"
        
        # If it's for DNSTT, we also need an NS record pointing to this A record
        if [[ "$type" == "dnstt" ]]; then
            local tun_sub="tun-${rand_id}"
            local tun_domain="${tun_sub}.${DESEC_DOMAIN}"
            msg_info "Creating NS record for DNSTT: ${tun_domain} -> ${full_domain}"
            curl -s -X POST "https://desec.io/api/v1/domains/${DESEC_DOMAIN}/rrsets/" \
                -H "Authorization: Token ${DESEC_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"subname\":\"${tun_sub}\",\"type\":\"NS\",\"ttl\":3600,\"records\":[\"${full_domain}.\"]}" >/dev/null
            
            echo "DNSTT_TUNNEL_DOMAIN=\"${tun_domain}\"" >> "$DNS_INFO_FILE"
            echo "DNSTT_NS_DOMAIN=\"${full_domain}\"" >> "$DNS_INFO_FILE"
        fi

        echo "${type^^}_DOMAIN=\"${full_domain}\"" >> "$DNS_INFO_FILE"
        return 0
    else
        msg_err "Failed to create DNS record. API might be busy."
        return 1
    fi
}

get_smart_domain() {
    local type="${1:-VPN}"
    [[ -f "$DNS_INFO_FILE" ]] && grep "${type^^}_DOMAIN" "$DNS_INFO_FILE" | cut -d'"' -f2
}

# ========================= DOWNLOAD HELPERS =================================
download_binary() {
    local url="$1" dest="$2" name="$3"
    msg_info "Downloading ${name} (Direct 200 OK)..."
    wget -q --show-progress --timeout=20 -O "$dest" "$url"
    if [[ -s "$dest" ]]; then
        chmod +x "$dest"
        msg_ok "${name} installed successfully."
        return 0
    else
        msg_err "Failed to download ${name}. URL: ${url}"
        return 1
    fi
}

# ========================= DNSTT LOGIC ======================================
install_dnstt() {
    msg_info "Installing DNSTT with Smart DNS..."
    init_dirs
    
    # 1. Free Port 53
    if ! port_free 53; then
        systemctl stop systemd-resolved 2>/dev/null
        systemctl disable systemd-resolved 2>/dev/null
    fi
    
    # 2. Download
    local arch=$(uname -m)
    local url=$DNSTT_URL_AMD64
    [[ "$arch" == "aarch64" ]] && url=$DNSTT_URL_ARM64
    download_binary "$url" "$DNSTT_BIN" "dnstt-server" || return 1
    
    # 3. DNS Records
    create_smart_dns "dnstt" || return 1
    local tun_domain=$(get_smart_domain "DNSTT_TUNNEL")
    
    # 4. Keys
    mkdir -p "$DNSTT_KEYS"
    "$DNSTT_BIN" -gen-key -privkey-file "${DNSTT_KEYS}/server.key" -pubkey-file "${DNSTT_KEYS}/server.pub" >/dev/null
    local pubkey=$(cat "${DNSTT_KEYS}/server.pub")
    
    # 5. Service
    cat > "$DNSTT_SERVICE" <<EOF
[Unit]
Description=XxXjihad DNSTT Server
After=network.target

[Service]
ExecStart=$DNSTT_BIN -udp :53 -privkey-file ${DNSTT_KEYS}/server.key -mtu 500 $tun_domain 127.0.0.1:22
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xxjihad-dnstt --now
    msg_ok "DNSTT active on ${tun_domain}"
}

# Rest of helper functions...
init_dirs() {
    mkdir -p "$XXJIHAD_DIR"/{db,dns,ssl,dnstt/keys} "$XXJIHAD_LOG" 2>/dev/null
}

port_free() { ! ss -lntu | grep -q ":${1}\b"; }
