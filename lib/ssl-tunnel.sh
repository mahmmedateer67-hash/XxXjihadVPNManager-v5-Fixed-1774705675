#!/bin/bash
###############################################################################
#  XxXjihad :: SSL TUNNEL / HAPROXY EDGE STACK v5.0                           #
#  HAProxy on 80/443 -> Internal Nginx on 8880/8443                           #
#  SSH detection, TLS termination, V2Ray/WS/gRPC/xHTTP routing               #
###############################################################################

# ========================= EDGE CERT MANAGEMENT ==============================
load_edge_cert_info() {
    EDGE_CERT_MODE=""
    EDGE_DOMAIN=""
    EDGE_EMAIL=""
    if [[ -f "$EDGE_CERT_INFO_FILE" ]]; then
        source "$EDGE_CERT_INFO_FILE"
    fi
}

save_edge_cert_info() {
    local mode="$1" domain="$2" email="$3"
    mkdir -p "$(dirname "$EDGE_CERT_INFO_FILE")"
    cat > "$EDGE_CERT_INFO_FILE" <<CERTEOF
EDGE_CERT_MODE="${mode}"
EDGE_DOMAIN="${domain}"
EDGE_EMAIL="${email}"
CERTEOF
}

# ========================= PACKAGE MANAGEMENT ================================
ensure_edge_stack_packages() {
    local pkgs_needed=()
    command -v haproxy &>/dev/null || pkgs_needed+=("haproxy")
    command -v nginx &>/dev/null || pkgs_needed+=("nginx")
    command -v openssl &>/dev/null || pkgs_needed+=("openssl")

    if [[ ${#pkgs_needed[@]} -gt 0 ]]; then
        msg_info "Installing required packages: ${pkgs_needed[*]}"
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "${pkgs_needed[@]}" >/dev/null 2>&1 || {
            msg_err "Failed to install packages"
            return 1
        }
    fi
    msg_ok "Edge stack packages ready"
}

# ========================= CERTIFICATE GENERATION ============================
generate_self_signed_edge_cert() {
    local host_ip=$(curl -s -4 icanhazip.com || echo "127.0.0.1")
    # FIX: Use nip.io for automatic domain resolution if only IP is provided
    local common_name="${1:-${host_ip}.nip.io}"
    
    msg_info "Generating self-signed certificate for: ${common_name}"
    mkdir -p "$SSL_CERT_DIR"

    openssl req -x509 -newkey rsa:2048 \
        -keyout "$SSL_CERT_KEY_FILE" \
        -out "$SSL_CERT_CHAIN_FILE" \
        -days 3650 -nodes \
        -subj "/CN=${common_name}" 2>/dev/null

    # Create combined PEM for HAProxy
    cat "$SSL_CERT_CHAIN_FILE" "$SSL_CERT_KEY_FILE" > "$SSL_CERT_FILE"
    chmod 600 "$SSL_CERT_KEY_FILE" "$SSL_CERT_FILE"

    save_edge_cert_info "self-signed" "$common_name" ""
    msg_ok "Self-signed certificate generated for ${common_name}"
}

obtain_certbot_edge_cert() {
    local domain="$1" email="$2"
    msg_info "Obtaining Let's Encrypt certificate for: ${domain}"

    if ! command -v certbot &>/dev/null; then
        msg_info "Installing certbot..."
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq certbot >/dev/null 2>&1 || {
            msg_err "Failed to install certbot"
            return 1
        }
    fi

    # Stop services that might use port 80
    systemctl stop haproxy >/dev/null 2>&1
    systemctl stop nginx >/dev/null 2>&1
    sleep 1

    certbot certonly --standalone --agree-tos --non-interactive \
        -d "$domain" --email "$email" \
        --preferred-challenges http 2>&1

    local certbot_live="/etc/letsencrypt/live/${domain}"
    if [[ ! -f "${certbot_live}/fullchain.pem" ]]; then
        msg_err "Certbot failed to obtain certificate"
        return 1
    fi

    mkdir -p "$SSL_CERT_DIR"
    cp "${certbot_live}/fullchain.pem" "$SSL_CERT_CHAIN_FILE"
    cp "${certbot_live}/privkey.pem" "$SSL_CERT_KEY_FILE"
    cat "$SSL_CERT_CHAIN_FILE" "$SSL_CERT_KEY_FILE" > "$SSL_CERT_FILE"
    chmod 600 "$SSL_CERT_KEY_FILE" "$SSL_CERT_FILE"

    save_edge_cert_info "certbot" "$domain" "$email"
    msg_ok "Let's Encrypt certificate obtained for ${domain}"
}

# ========================= CERTIFICATE SELECTION =============================
select_edge_certificate() {
    echo ""
    echo -e " ${BLU}SSL Certificate Configuration:${CR}"
    echo ""

    load_edge_cert_info
    if [[ -n "$EDGE_CERT_MODE" ]]; then
        echo -e " ${GRY}Current: ${EDGE_CERT_MODE} (${EDGE_DOMAIN:-unknown})${CR}"
    fi

    echo -e "   ${GRN}[1]${CR} Self-signed certificate ${GRY}(Quick, no domain needed)${CR}"
    echo -e "   ${GRN}[2]${CR} Let's Encrypt (Certbot) ${GRY}(Requires domain + port 80)${CR}"
    echo -e "   ${GRY}[0]${CR} Cancel"
    echo ""
    read -rp " Choice [1]: " cert_choice
    cert_choice=${cert_choice:-1}

    case "$cert_choice" in
        1)
            local host_ip=$(curl -s -4 icanhazip.com || echo "127.0.0.1")
            local common_name
            read -rp " Common Name [${host_ip}.nip.io]: " common_name
            common_name=${common_name:-${host_ip}.nip.io}
            generate_self_signed_edge_cert "$common_name"
            ;;
        2)
            local domain_name email
            read -rp " Domain name (e.g., vpn.example.com): " domain_name
            [[ -z "$domain_name" ]] && { msg_err "Domain required"; return 1; }
            is_valid_ip4 "$domain_name" && { msg_err "Certbot needs a domain, not IP"; return 1; }
            read -rp " Email for Let's Encrypt: " email
            [[ -z "$email" ]] && { msg_err "Email required"; return 1; }
            obtain_certbot_edge_cert "$domain_name" "$email"
            ;;
        0) return 1 ;;
        *) msg_err "Invalid option"; return 1 ;;
    esac
}

# ========================= BACKUP CONFIGS ====================================
backup_edge_configs() {
    [[ -f "$HAPROXY_CONFIG" ]] && cp "$HAPROXY_CONFIG" "${HAPROXY_CONFIG}.bak.$(date +%s)" 2>/dev/null
    [[ -f "$NGINX_CONFIG_FILE" ]] && cp "$NGINX_CONFIG_FILE" "${NGINX_CONFIG_FILE}.bak.$(date +%s)" 2>/dev/null
}

# ========================= HAPROXY EDGE CONFIG ===============================
write_haproxy_edge_config() {
    mkdir -p /etc/haproxy
    # FIX: Ensure HAProxy can run without errors and ports are available
    cat > "$HAPROXY_CONFIG" <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 4096

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5s
    timeout client  24h
    timeout server  24h

# ====================================================================
# TIER 1: PORT ${EDGE_PUBLIC_HTTP_PORT} (Cleartext Payloads & Raw SSH)
# ====================================================================
frontend port_80_edge
    bind *:${EDGE_PUBLIC_HTTP_PORT}
    mode tcp
    tcp-request inspect-delay 2s

    acl is_ssh payload(0,7) -m bin 5353482d322e30

    tcp-request content accept if is_ssh
    tcp-request content accept if HTTP

    use_backend direct_ssh if is_ssh
    default_backend nginx_cleartext

# ====================================================================
# TIER 1: PORT ${EDGE_PUBLIC_TLS_PORT} (TLS V2Ray, SSL Payloads, Raw SSH)
# ====================================================================
frontend port_443_edge
    bind *:${EDGE_PUBLIC_TLS_PORT}
    mode tcp
    tcp-request inspect-delay 2s

    acl is_ssh payload(0,7) -m bin 5353482d322e30
    acl is_tls req.ssl_hello_type 1
    acl has_web_alpn req.ssl_alpn -m sub h2 http/1.1

    tcp-request content accept if is_ssh
    tcp-request content accept if HTTP
    tcp-request content accept if is_tls

    use_backend direct_ssh if is_ssh
    use_backend nginx_cleartext if HTTP
    use_backend nginx_tls if is_tls has_web_alpn
    default_backend loopback_ssl_terminator

# ====================================================================
# TIER 2: INTERNAL DECRYPTOR (Only for Any-SNI SSH-TLS)
# ====================================================================
frontend internal_decryptor
    bind 127.0.0.1:${HAPROXY_INTERNAL_DECRYPT_PORT} ssl crt ${SSL_CERT_FILE}
    mode tcp
    tcp-request inspect-delay 2s

    acl is_ssh payload(0,7) -m bin 5353482d322e30
    tcp-request content accept if is_ssh
    tcp-request content accept if HTTP

    use_backend direct_ssh if is_ssh
    default_backend nginx_cleartext

# ====================================================================
# DESTINATION BACKENDS (Clean handoffs)
# ====================================================================
backend direct_ssh
    mode tcp
    server ssh_server 127.0.0.1:22

backend nginx_cleartext
    mode tcp
    server nginx_8880 127.0.0.1:${NGINX_INTERNAL_HTTP_PORT}

backend nginx_tls
    mode tcp
    server nginx_8443 127.0.0.1:${NGINX_INTERNAL_TLS_PORT}

backend loopback_ssl_terminator
    mode tcp
    server haproxy_ssl 127.0.0.1:${HAPROXY_INTERNAL_DECRYPT_PORT}
EOF
}

# ========================= NGINX INTERNAL CONFIG =============================
write_nginx_internal_config() {
    local server_name="${1:-_}"
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    cat > "$NGINX_CONFIG_FILE" <<EOF
server {
    listen ${NGINX_INTERNAL_HTTP_PORT};
    server_tokens off;
    server_name ${server_name};

    resolver 1.1.1.1 8.8.8.8 ipv6=off valid=300s;

    location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)$ {
        client_max_body_size 0;
        client_body_timeout 1d;
        grpc_read_timeout 1d;
        grpc_socket_keepalive on;
        proxy_read_timeout 1d;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        if (\$content_type ~* "GRPC") { grpc_pass grpc://127.0.0.1:\$fwdport\$is_args\$args; break; }
        proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
        break;
    }

    location / {
        proxy_read_timeout 3600s;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_http_version 1.1;
        proxy_socket_keepalive on;
        tcp_nodelay on;
        tcp_nopush off;
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}

server {
    listen ${NGINX_INTERNAL_TLS_PORT} ssl;
    server_tokens off;
    server_name ${server_name};

    ssl_certificate ${SSL_CERT_CHAIN_FILE};
    ssl_certificate_key ${SSL_CERT_KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    resolver 1.1.1.1 8.8.8.8 ipv6=off valid=300s;

    location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)$ {
        client_max_body_size 0;
        client_body_timeout 1d;
        grpc_read_timeout 1d;
        grpc_socket_keepalive on;
        proxy_read_timeout 1d;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        if (\$content_type ~* "GRPC") { grpc_pass grpc://127.0.0.1:\$fwdport\$is_args\$args; break; }
        proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
        break;
    }

    location / {
        proxy_read_timeout 3600s;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_http_version 1.1;
        proxy_socket_keepalive on;
        tcp_nodelay on;
        tcp_nopush off;
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
    ln -sf "$NGINX_CONFIG_FILE" /etc/nginx/sites-enabled/default
}

# ========================= SAVE EDGE PORTS INFO ==============================
save_edge_ports_info() {
    cat > "$NGINX_PORTS_FILE" <<EOF
EDGE_HTTP_PORT="${EDGE_PUBLIC_HTTP_PORT}"
EDGE_TLS_PORT="${EDGE_PUBLIC_TLS_PORT}"
HTTP_PORTS="${NGINX_INTERNAL_HTTP_PORT}"
TLS_PORTS="${NGINX_INTERNAL_TLS_PORT}"
EOF
}

# ========================= CONFIGURE EDGE STACK ==============================
configure_edge_stack() {
    local server_name="${1:-_}"

    msg_info "Writing HAProxy edge configuration..."
    backup_edge_configs
    write_haproxy_edge_config

    msg_info "Writing Nginx internal proxy configuration..."
    write_nginx_internal_config "$server_name"

    msg_info "Starting edge stack services..."
    mkdir -p /run/haproxy
    systemctl daemon-reload
    systemctl enable haproxy >/dev/null 2>&1
    systemctl enable nginx >/dev/null 2>&1
    
    # Restart with delay and check
    systemctl restart nginx
    sleep 1
    systemctl restart haproxy
    sleep 2

    local ok=true
    if ! systemctl is-active --quiet haproxy; then
        msg_err "HAProxy failed to start. Checking logs..."
        journalctl -u haproxy -n 20 --no-pager
        ok=false
    fi
    if ! systemctl is-active --quiet nginx; then
        msg_err "Nginx failed to start. Checking logs..."
        journalctl -u nginx -n 20 --no-pager
        ok=false
    fi

    save_edge_ports_info
    $ok && msg_ok "Edge stack configured and running"
    return 0
}

# ========================= INSTALL SSL TUNNEL ================================
install_ssl_tunnel() {
    echo ""
    echo -e " ${CB}${CYN}============================================${CR}"
    echo -e " ${CB}${CYN}  HAProxy Edge Stack (80/443 -> 8880/8443)  ${CR}"
    echo -e " ${CB}${CYN}============================================${CR}"
    echo ""
    
    ensure_edge_stack_packages || return

    systemctl stop haproxy >/dev/null 2>&1
    systemctl stop nginx >/dev/null 2>&1
    sleep 1

    select_edge_certificate || return

    load_edge_cert_info
    local server_name="${EDGE_DOMAIN:-_}"
    configure_edge_stack "$server_name" || return

    msg_ok "HAProxy edge stack is active!"
}

uninstall_ssl_tunnel() {
    msg_info "Stopping and disabling HAProxy/Nginx..."
    systemctl stop haproxy nginx >/dev/null 2>&1
    systemctl disable haproxy nginx >/dev/null 2>&1
    msg_ok "HAProxy edge stack removed"
}
