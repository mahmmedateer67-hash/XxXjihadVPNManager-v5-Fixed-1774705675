#!/bin/bash
###############################################################################
#  XxXjihad :: DNSTT & DNS SMART CORE ENGINE v6.0.0                           #
#  Specialized for DNSTT & SSH VPN with Intelligent DNS Records (deSEC.io)    #
#  Inspired by TheFirewoods Manager - Verified 200 OK Links                   #
###############################################################################

# ========================= PATHS & CONSTANTS ================================
XXJIHAD_DIR="/etc/xxjihad"
XXJIHAD_LOG="/var/log/xxjihad"
XXJIHAD_BIN="/usr/local/bin"
XXJIHAD_LIB="/usr/local/lib/xxjihad"

DNSTT_BIN="${XXJIHAD_BIN}/dnstt-server"
DNSTT_KEYS="${XXJIHAD_DIR}/dnstt/keys"
DNSTT_SERVICE="/etc/systemd/system/xxjihad-dnstt.service"
DNS_INFO_FILE="${XXJIHAD_DIR}/db/dns_info.conf"

# deSEC.io API Configuration (Fixed Domain 02iuk.shop)
DESEC_TOKEN="Ggavnjc2vUMoGNFtyNVUqhc8cQJa2"
DESEC_DOMAIN="02iuk.shop"

# Verified 200 OK Binary URLs (No GitHub Login Required)
DNSTT_URL_AMD64="https://github.com/firewallfalcons/FirewallFalcon-Manager/raw/main/bin/dnstt-server-linux-amd64"
DNSTT_URL_ARM64="https://github.com/firewallfalcons/FirewallFalcon-Manager/raw/main/bin/dnstt-server-linux-arm64"

# ========================= COLORS ===========================================
CR=$'\033[0m'; CB=$'\033[1m'; RED=$'\033[38;5;196m'; GRN=$'\033[38;5;46m'
YLW=$'\033[38;5;226m'; BLU=$'\033[38;5;39m'; CYN=$'\033[38;5;51m'; WHT=$'\033[38;5;255m'

msg_ok()   { echo -e " ${GRN}[OK]${CR} $*"; }
msg_err()  { echo -e " ${RED}[ERROR]${CR} $*"; }
msg_warn() { echo -e " ${YLW}[WARN]${CR} $*"; }
msg_info() { echo -e " ${BLU}[INFO]${CR} $*"; }

# ========================= INTELLIGENT DNS SYSTEM ===========================
# Create records on install, delete records on uninstall
create_dnstt_dns() {
    local ip=$(curl -s -4 icanhazip.com || echo "127.0.0.1")
    local rand_id=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 8)
    local ns_sub="ns-${rand_id}"
    local tun_sub="tun-${rand_id}"
    
    msg_info "Registering Smart DNS records on ${DESEC_DOMAIN}..."
    
    # 1. Create A Record for NS
    local res1=$(curl -s -X POST "https://desec.io/api/v1/domains/${DESEC_DOMAIN}/rrsets/" \
        -H "Authorization: Token ${DESEC_TOKEN}" -H "Content-Type: application/json" \
        -d "{\"subname\":\"${ns_sub}\",\"type\":\"A\",\"ttl\":3600,\"records\":[\"${ip}\"]}")
    
    # 2. Create NS Record for Tunnel
    local res2=$(curl -s -X POST "https://desec.io/api/v1/domains/${DESEC_DOMAIN}/rrsets/" \
        -H "Authorization: Token ${DESEC_TOKEN}" -H "Content-Type: application/json" \
        -d "{\"subname\":\"${tun_sub}\",\"type\":\"NS\",\"ttl\":3600,\"records\":[\"${ns_sub}.${DESEC_DOMAIN}.\"]}")

    if echo "$res1" | grep -q "subname" && echo "$res2" | grep -q "subname"; then
        mkdir -p "$(dirname "$DNS_INFO_FILE")"
        cat > "$DNS_INFO_FILE" <<DNSCONF
NS_SUB="${ns_sub}"
TUN_SUB="${tun_sub}"
TUN_DOMAIN="${tun_sub}.${DESEC_DOMAIN}"
NS_DOMAIN="${ns_sub}.${DESEC_DOMAIN}"
VPS_IP="${ip}"
DNSCONF
        msg_ok "Smart DNS ready: ${tun_sub}.${DESEC_DOMAIN}"
        return 0
    else
        msg_err "Failed to register DNS. API might be limited."
        return 1
    fi
}

delete_dnstt_dns() {
    [[ ! -f "$DNS_INFO_FILE" ]] && return
    source "$DNS_INFO_FILE"
    msg_info "Cleaning up DNS records from ${DESEC_DOMAIN}..."
    curl -s -X DELETE "https://desec.io/api/v1/domains/${DESEC_DOMAIN}/rrsets/${NS_SUB}/A/" -H "Authorization: Token ${DESEC_TOKEN}" >/dev/null
    curl -s -X DELETE "https://desec.io/api/v1/domains/${DESEC_DOMAIN}/rrsets/${TUN_SUB}/NS/" -H "Authorization: Token ${DESEC_TOKEN}" >/dev/null
    rm -f "$DNS_INFO_FILE"
    msg_ok "DNS records removed. Domain is clean."
}

# ========================= DNSTT CORE LOGIC =================================
install_dnstt() {
    echo ""
    echo -e " ${CB}${CYN}--- DNSTT Smart Installation ---${CR}"
    
    # 1. Port 53 Check (Same as TheFirewoods)
    if ! ss -lntu | grep -q ":53\b"; then
        msg_ok "Port 53 is free"
    else
        msg_info "Freeing port 53 (disabling systemd-resolved)..."
        systemctl stop systemd-resolved 2>/dev/null
        systemctl disable systemd-resolved 2>/dev/null
        rm -f /etc/resolv.conf
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 1.1.1.1" > /etc/resolv.conf
    fi
    
    # 2. Download Binary (200 OK)
    local arch=$(uname -m)
    local url=$DNSTT_URL_AMD64
    [[ "$arch" == "aarch64" ]] && url=$DNSTT_URL_ARM64
    msg_info "Downloading DNSTT Server binary..."
    wget -q -O "$DNSTT_BIN" "$url" && chmod +x "$DNSTT_BIN"
    
    # 3. DNS Smart Setup
    create_dnstt_dns || return 1
    source "$DNS_INFO_FILE"
    
    # 4. Key Generation
    mkdir -p "$DNSTT_KEYS"
    "$DNSTT_BIN" -gen-key -privkey-file "${DNSTT_KEYS}/server.key" -pubkey-file "${DNSTT_KEYS}/server.pub" >/dev/null
    local pubkey=$(cat "${DNSTT_KEYS}/server.pub")
    
    # 5. Service Creation
    cat > "$DNSTT_SERVICE" <<EOF
[Unit]
Description=XxXjihad DNSTT Server
After=network.target

[Service]
ExecStart=$DNSTT_BIN -udp :53 -privkey-file ${DNSTT_KEYS}/server.key -mtu 500 $TUN_DOMAIN 127.0.0.1:22
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xxjihad-dnstt --now
    
    msg_ok "DNSTT is ACTIVE!"
    echo -e " ${CYN}+----------------------------------------+${CR}"
    echo -e " ${CYN}|${CR}  Domain:  ${YLW}$TUN_DOMAIN${CR}"
    echo -e " ${CYN}|${CR}  PubKey:  ${YLW}$pubkey${CR}"
    echo -e " ${CYN}+----------------------------------------+${CR}"
}

uninstall_dnstt() {
    msg_info "Removing DNSTT service..."
    systemctl stop xxjihad-dnstt 2>/dev/null
    systemctl disable xxjihad-dnstt 2>/dev/null
    rm -f "$DNSTT_SERVICE" "$DNSTT_BIN"
    delete_dnstt_dns
    msg_ok "DNSTT uninstalled."
}
