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
    local common_name="${1:-$(detect_preferred_host)}"
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
    msg_ok "Self-signed certificate generated"
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
            local common_name
            read -rp " Common Name [$(detect_preferred_host)]: " common_name
            common_name=${common_name:-$(detect_preferred_host)}
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
    cat > "$HAPROXY_CONFIG" <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

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
# XxXjihad Internal Nginx Proxy (Edge Stack)
# Handles HTTP on ${NGINX_INTERNAL_HTTP_PORT} and HTTPS on ${NGINX_INTERNAL_TLS_PORT}

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
    systemctl restart haproxy
    systemctl restart nginx
    sleep 2

    local ok=true
    if ! systemctl is-active --quiet haproxy; then
        msg_err "HAProxy failed to start"
        journalctl -u haproxy -n 10 --no-pager 2>/dev/null
        ok=false
    fi
    if ! systemctl is-active --quiet nginx; then
        msg_err "Nginx failed to start"
        journalctl -u nginx -n 10 --no-pager 2>/dev/null
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
    echo -e " This will configure:"
    echo -e "   HAProxy on ${WHT}${EDGE_PUBLIC_HTTP_PORT}/${EDGE_PUBLIC_TLS_PORT}${CR}"
    echo -e "   Internal Nginx on ${WHT}${NGINX_INTERNAL_HTTP_PORT}/${NGINX_INTERNAL_TLS_PORT}${CR}"
    echo -e "   Loopback SSL decryptor on ${WHT}${HAPROXY_INTERNAL_DECRYPT_PORT}${CR}"
    echo ""

    if [[ -f "$HAPROXY_CONFIG" ]] || [[ -f "$NGINX_CONFIG_FILE" ]]; then
        msg_warn "Existing HAProxy/Nginx configs will be replaced."
        read -rp " Continue? (y/n): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && { msg_warn "Cancelled"; return 0; }
    fi

    mkdir -p "$XXJIHAD_DIR"/{db,ssl}

    ensure_edge_stack_packages || return

    systemctl stop haproxy >/dev/null 2>&1
    systemctl stop nginx >/dev/null 2>&1
    sleep 1

    check_and_free_ports "$EDGE_PUBLIC_HTTP_PORT" "$EDGE_PUBLIC_TLS_PORT" \
        "$NGINX_INTERNAL_HTTP_PORT" "$NGINX_INTERNAL_TLS_PORT" "$HAPROXY_INTERNAL_DECRYPT_PORT" || return

    check_and_open_firewall_port "$EDGE_PUBLIC_HTTP_PORT" tcp
    check_and_open_firewall_port "$EDGE_PUBLIC_TLS_PORT" tcp

    select_edge_certificate || return

    load_edge_cert_info
    local server_name="${EDGE_DOMAIN:-$(detect_preferred_host)}"
    [[ -z "$server_name" ]] && server_name="_"

    configure_edge_stack "$server_name" || return

    echo ""
    msg_ok "HAProxy edge stack is active!"
    echo -e "   Public edge ports: ${YLW}${EDGE_PUBLIC_HTTP_PORT}/${EDGE_PUBLIC_TLS_PORT}${CR}"
    echo -e "   Internal Nginx ports: ${YLW}${NGINX_INTERNAL_HTTP_PORT}/${NGINX_INTERNAL_TLS_PORT}${CR}"
    echo -e "   Certificate: ${YLW}${EDGE_CERT_MODE:-unknown}${CR}"
    echo ""
    echo -e " ${CYN}Supported Connections:${CR}"
    echo -e "   ${GRN}*${CR} Direct SSH on ports: 22, 80, 443"
    echo -e "   ${GRN}*${CR} SSH + Payload (no SSL) on ports: 80, 443"
    echo -e "   ${GRN}*${CR} SSH + Payload + WebSocket + SSL on port: 443"
    echo -e "   ${GRN}*${CR} V2Ray WS/gRPC/xHTTP on ports: 443, 80"
    echo -e "   ${GRN}*${CR} V2Ray + Payload on port 8080 (via Falcon Proxy)"
    echo ""
    log_i "HAProxy Edge Stack installed"
}

# ========================= UNINSTALL SSL TUNNEL ==============================
uninstall_ssl_tunnel() {
    echo ""
    echo -e " ${CB}${RED}--- Uninstalling HAProxy Edge Stack ---${CR}"

    if ! command -v haproxy &>/dev/null; then
        msg_warn "HAProxy is not installed, skipping."
    else
        msg_info "Stopping and disabling HAProxy..."
        systemctl stop haproxy >/dev/null 2>&1
        systemctl disable haproxy >/dev/null 2>&1
    fi

    if [[ -f "$HAPROXY_CONFIG" ]]; then
        cat > "$HAPROXY_CONFIG" <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice

defaults
    log     global
EOF
    fi

    local delete_cert="n"
    if [[ "$UNINSTALL_MODE" == "silent" ]]; then
        delete_cert="y"
    elif [[ -f "$SSL_CERT_FILE" ]] || [[ -f "$SSL_CERT_CHAIN_FILE" ]] || [[ -f "$SSL_CERT_KEY_FILE" ]]; then
        if systemctl is-active --quiet nginx 2>/dev/null; then
            msg_warn "The shared certificate is also used by internal Nginx."
        fi
        read -rp " Delete the shared TLS certificate too? (y/n): " delete_cert
    fi

    if [[ "$delete_cert" =~ ^[Yy]$ ]]; then
        if systemctl is-active --quiet nginx 2>/dev/null; then
            msg_info "Stopping Nginx (shared certificate being removed)..."
            systemctl stop nginx >/dev/null 2>&1
        fi
        rm -f "$SSL_CERT_FILE" "$SSL_CERT_CHAIN_FILE" "$SSL_CERT_KEY_FILE" "$EDGE_CERT_INFO_FILE"
        rm -f "$NGINX_PORTS_FILE"
        msg_ok "Shared certificate files removed"
    fi

    msg_ok "HAProxy edge stack removed"
    if systemctl is-active --quiet nginx 2>/dev/null; then
        echo -e " ${GRY}Internal Nginx is still running on ${NGINX_INTERNAL_HTTP_PORT}/${NGINX_INTERNAL_TLS_PORT}.${CR}"
    fi
    log_i "HAProxy Edge Stack uninstalled"
}
