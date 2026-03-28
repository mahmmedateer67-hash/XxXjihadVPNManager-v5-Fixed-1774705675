#!/bin/bash
###############################################################################
#  XxXjihad :: SSL TUNNEL / HAPROXY EDGE STACK v5.1.0 (Smart DNS)             #
#  Automatic Domain Generation for SSL via deSEC.io API                       #
###############################################################################

# ========================= PATHS & CONSTANTS ================================
XXJIHAD_DIR="/etc/xxjihad"
SSL_CERT_DIR="${XXJIHAD_DIR}/ssl"
SSL_CERT_FILE="${SSL_CERT_DIR}/xxjihad.pem"
SSL_CERT_CHAIN_FILE="${SSL_CERT_DIR}/xxjihad.crt"
SSL_CERT_KEY_FILE="${SSL_CERT_DIR}/xxjihad.key"
EDGE_CERT_INFO_FILE="${XXJIHAD_DIR}/db/edge_cert.conf"
HAPROXY_CONFIG="/etc/haproxy/haproxy.cfg"

# ========================= COLORS ===========================================
CR=$'\033[0m'; CB=$'\033[1m'; RED=$'\033[38;5;196m'; GRN=$'\033[38;5;46m'
YLW=$'\033[38;5;226m'; BLU=$'\033[38;5;39m'; CYN=$'\033[38;5;51m'; WHT=$'\033[38;5;255m'

msg_ok()   { echo -e " ${GRN}[OK]${CR} $*"; }
msg_err()  { echo -e " ${RED}[ERROR]${CR} $*"; }
msg_warn() { echo -e " ${YLW}[WARN]${CR} $*"; }
msg_info() { echo -e " ${BLU}[INFO]${CR} $*"; }

# ========================= SMART SSL LOGIC ==================================
# Automatically generate a domain for SSL if none is provided
install_ssl_tunnel() {
    echo ""
    echo -e " ${CB}${CYN}============================================${CR}"
    echo -e " ${CB}${CYN}   HAProxy Edge Stack (SSL Smart DNS)       ${CR}"
    echo -e " ${CB}${CYN}============================================${CR}"
    echo ""

    # 1. Dependencies
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq haproxy nginx openssl >/dev/null 2>&1
    
    # 2. Smart DNS Generation
    source "/usr/local/lib/xxjihad/dnstt-core.sh"
    create_smart_dns "ssl" || return 1
    local ssl_domain=$(get_smart_domain "ssl")
    
    # 3. Generate Certificate
    msg_info "Generating certificate for: ${ssl_domain}"
    mkdir -p "$SSL_CERT_DIR"
    openssl req -x509 -newkey rsa:2048 -keyout "$SSL_CERT_KEY_FILE" -out "$SSL_CERT_CHAIN_FILE" \
        -days 3650 -nodes -subj "/CN=${ssl_domain}" 2>/dev/null
    cat "$SSL_CERT_CHAIN_FILE" "$SSL_CERT_KEY_FILE" > "$SSL_CERT_FILE"
    chmod 600 "$SSL_CERT_KEY_FILE" "$SSL_CERT_FILE"

    # 4. HAProxy Config
    cat > "$HAPROXY_CONFIG" <<EOF
global
    log /dev/log local0
    user haproxy
    group haproxy
    daemon
    maxconn 4096

defaults
    log     global
    mode    tcp
    timeout connect 5s
    timeout client  24h
    timeout server  24h

frontend port_80
    bind *:80
    default_backend nginx_http

frontend port_443
    bind *:443
    mode tcp
    tcp-request inspect-delay 2s
    acl is_tls req.ssl_hello_type 1
    use_backend ssl_terminator if is_tls
    default_backend ssh_direct

backend ssl_terminator
    mode tcp
    server loopback 127.0.0.1:10443

backend ssh_direct
    mode tcp
    server ssh_server 127.0.0.1:22

backend nginx_http
    mode tcp
    server nginx_8880 127.0.0.1:8880

frontend internal_ssl
    bind 127.0.0.1:10443 ssl crt $SSL_CERT_FILE
    mode tcp
    default_backend ssh_direct
EOF

    # 5. Restart Services
    systemctl restart haproxy nginx
    msg_ok "SSL Tunnel active on ${ssl_domain}"
    msg_ok "Ports: 80 (HTTP), 443 (SSL/SSH)"
}

uninstall_ssl_tunnel() {
    systemctl stop haproxy nginx 2>/dev/null
    systemctl disable haproxy nginx 2>/dev/null
    msg_ok "SSL Tunnel removed."
}
