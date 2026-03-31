#!/bin/bash
###############################################################################
#  Xxxjihad :: DNSTT & DNS SMART CORE ENGINE v7.0.0                           #
#  Specialized for DNSTT & SSH VPN with Intelligent DNS Records (deSEC.io)    #
#  Strictly using 'xxxjihad' naming and Automated DNS Cleanup                 #
###############################################################################

# ========================= PATHS & CONSTANTS ================================
XXXJIHAD_DIR="/etc/xxxjihad"
XXXJIHAD_LOG="/var/log/xxxjihad"
XXXJIHAD_BIN="/usr/local/bin"
XXXJIHAD_LIB="/usr/local/lib/xxxjihad"

DNSTT_BIN="${XXXJIHAD_BIN}/dnstt-server"
DNSTT_KEYS="${XXXJIHAD_DIR}/dnstt/keys"
DNSTT_SERVICE="/etc/systemd/system/xxxjihad-dnstt.service"
DNS_INFO_FILE="${XXXJIHAD_DIR}/db/dns_info.conf"

# deSEC.io API Configuration (Fixed Domain 02iuk.shop)
DESEC_TOKEN="Ggavnjc2vUMoGNFtyNVUqhc8cQJa2"
DESEC_DOMAIN="02iuk.shop"

# Verified 200 OK Binary URLs (Direct from TheFirewoods/Falcon Source)
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
# This system ensures 'xxxjihad' is in every record and cleans up old records
cleanup_existing_records_by_ip() {
    local ip=$(curl -s -4 icanhazip.com || echo "127.0.0.1")
    msg_info "Scanning for old records associated with IP ${ip}..."
    
    # Fetch all rrsets for the domain
    local rrsets=$(curl -s -X GET "https://desec.io/api/v1/domains/${DESEC_DOMAIN}/rrsets/" \
        -H "Authorization: Token ${DESEC_TOKEN}")
    
    # Filter and delete records that match this IP or are orphaned NS records
    echo "$rrsets" | jq -c '.[]' | while read -r row; do
        local subname=$(echo "$row" | jq -r '.subname')
        local type=$(echo "$row" | jq -r '.type')
        local records=$(echo "$row" | jq -r '.records[]')
        
        if [[ "$records" == "$ip" ]] || [[ "$records" == *"xxxjihad"* ]]; then
            msg_warn "Deleting stale record: ${subname}.${DESEC_DOMAIN} (${type})"
            curl -s -X DELETE "https://desec.io/api/v1/domains/${DESEC_DOMAIN}/rrsets/${subname}/${type}/" \
                -H "Authorization: Token ${DESEC_TOKEN}" >/dev/null
        fi
    done
}

create_dnstt_dns() {
    local ip=$(curl -s -4 icanhazip.com || echo "127.0.0.1")
    local rand_id=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 4)
    local ns_sub="xxxjihad-ns-${rand_id}"
    local tun_sub="xxxjihad-tun-${rand_id}"
    
    # Ensure domain is clean before adding new records
    cleanup_existing_records_by_ip
    
    msg_info "Registering New Smart DNS: ${tun_sub}.${DESEC_DOMAIN}"
    
    # 1. Create A Record (and AAAA if available)
    local api_data="[{\"subname\": \"${ns_sub}\", \"type\": \"A\", \"ttl\": 3600, \"records\": [\"${ip}\"]}"
    local ipv6=$(curl -s -6 icanhazip.com --max-time 5)
    if [[ -n "$ipv6" ]]; then
        api_data="${api_data}, {\"subname\": \"${ns_sub}\", \"type\": \"AAAA\", \"ttl\": 3600, \"records\": [\"${ipv6}\"]}"
    fi
    # 2. Create NS Record
    api_data="${api_data}, {\"subname\": \"${tun_sub}\", \"type\": \"NS\", \"ttl\": 3600, \"records\": [\"${ns_sub}.${DESEC_DOMAIN}.\"]}]"

    local res=$(curl -s -X POST "https://desec.io/api/v1/domains/${DESEC_DOMAIN}/rrsets/" \
        -H "Authorization: Token ${DESEC_TOKEN}" -H "Content-Type: application/json" \
        -d "$api_data")

    if echo "$res" | grep -q "subname"; then
        mkdir -p "$(dirname "$DNS_INFO_FILE")"
        cat > "$DNS_INFO_FILE" <<DNSCONF
NS_SUB="${ns_sub}"
TUN_SUB="${tun_sub}"
TUN_DOMAIN="${tun_sub}.${DESEC_DOMAIN}"
NS_DOMAIN="${ns_sub}.${DESEC_DOMAIN}"
VPS_IP="${ip}"
HAS_IPV6="$([[ -n "$ipv6" ]] && echo "true" || echo "false")"
DNSCONF
        msg_ok "Smart DNS Registered: ${tun_sub}.${DESEC_DOMAIN}"
        return 0
    else
        msg_err "Failed to register DNS. Response: $res"
        return 1
    fi
}

delete_dnstt_dns() {
    if [[ -f "$DNS_INFO_FILE" ]]; then
        source "$DNS_INFO_FILE"
        msg_info "Cleaning up current DNS records..."
        curl -s -X DELETE "https://desec.io/api/v1/domains/${DESEC_DOMAIN}/rrsets/${NS_SUB}/A/" -H "Authorization: Token ${DESEC_TOKEN}" >/dev/null
        curl -s -X DELETE "https://desec.io/api/v1/domains/${DESEC_DOMAIN}/rrsets/${TUN_SUB}/NS/" -H "Authorization: Token ${DESEC_TOKEN}" >/dev/null
        [[ "$HAS_IPV6" == "true" ]] && curl -s -X DELETE "https://desec.io/api/v1/domains/${DESEC_DOMAIN}/rrsets/${NS_SUB}/AAAA/" -H "Authorization: Token ${DESEC_TOKEN}" >/dev/null
        rm -f "$DNS_INFO_FILE"
    fi
    # Also run general cleanup to be 100% sure
    cleanup_existing_records_by_ip
    msg_ok "Domain ${DESEC_DOMAIN} is now clean."
}

# ========================= DNSTT CORE LOGIC =================================
install_dnstt() {
    echo -e "\n${CB}${CYN}--- 📡 DNSTT Smart Setup (xxxjihad Edition) ---${CR}"
    
    # 1. Port 53 Release (TheFirewoods Style)
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
    rm -f /etc/resolv.conf
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    
    # 2. Binary Management
    local arch=$(uname -m)
    local url=$DNSTT_URL_AMD64
    [[ "$arch" == "aarch64" ]] && url=$DNSTT_URL_ARM64
    wget -q -O "$DNSTT_BIN" "$url" && chmod +x "$DNSTT_BIN"
    
    # 3. DNS & Keys
    create_dnstt_dns || return 1
    source "$DNS_INFO_FILE"
    mkdir -p "$DNSTT_KEYS"
    "$DNSTT_BIN" -gen-key -privkey-file "${DNSTT_KEYS}/server.key" -pubkey-file "${DNSTT_KEYS}/server.pub" >/dev/null
    local pubkey=$(cat "${DNSTT_KEYS}/server.pub")
    
    # 4. Service
    cat > "$DNSTT_SERVICE" <<EOF
[Unit]
Description=Xxxjihad DNSTT Server
After=network.target

[Service]
ExecStart=$DNSTT_BIN -udp :53 -privkey-file ${DNSTT_KEYS}/server.key -mtu 512 $TUN_DOMAIN 127.0.0.1:22
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xxxjihad-dnstt --now
    
    msg_ok "DNSTT is ACTIVE on ${TUN_DOMAIN}"
}

uninstall_dnstt() {
    systemctl stop xxxjihad-dnstt 2>/dev/null
    systemctl disable xxxjihad-dnstt 2>/dev/null
    rm -f "$DNSTT_SERVICE" "$DNSTT_BIN"
    delete_dnstt_dns
}
