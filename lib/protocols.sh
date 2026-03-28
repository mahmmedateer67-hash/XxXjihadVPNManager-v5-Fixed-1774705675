#!/bin/bash
###############################################################################
#  XxXjihad :: PROTOCOLS ENGINE v5.0                                          #
#  badvpn, Falcon Proxy, ZiVPN, X-UI, Torrent Block, Traffic Monitor,        #
#  Auto-Reboot, SSH Banner, CloudFlare DNS                                    #
###############################################################################

# ========================= BADVPN ============================================
install_badvpn() {
    echo ""
    echo -e " ${CB}${CYN}--- Install badvpn-udpgw (UDP Port 7300) ---${CR}"
    echo ""

    if systemctl is-active --quiet badvpn 2>/dev/null; then
        msg_warn "badvpn is already running on port 7300"
        return 0
    fi

    local badvpn_bin="/usr/local/bin/badvpn-udpgw"
    if [[ ! -f "$badvpn_bin" ]]; then
        msg_info "Installing badvpn-udpgw..."
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq cmake make g++ git 2>/dev/null

        local tmp_dir="/tmp/badvpn-build-$$"
        mkdir -p "$tmp_dir"
        cd "$tmp_dir" || return 1

        if ! git clone --depth 1 https://github.com/nickolaev/badvpn.git 2>/dev/null; then
            msg_err "Failed to clone badvpn repository"
            cd /
            rm -rf "$tmp_dir"
            return 1
        fi

        cd badvpn || return 1
        mkdir build && cd build || return 1
        cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null 2>&1
        make -j"$(nproc)" >/dev/null 2>&1

        if [[ -f "udpgw/badvpn-udpgw" ]]; then
            cp "udpgw/badvpn-udpgw" "$badvpn_bin"
            chmod +x "$badvpn_bin"
        else
            msg_err "Build failed"
            cd /
            rm -rf "$tmp_dir"
            return 1
        fi
        cd /
        rm -rf "$tmp_dir"
    fi

    cat > /etc/systemd/system/badvpn.service <<'BVPNSVC'
[Unit]
Description=BadVPN UDP Gateway
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500 --max-connections-for-client 10
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
BVPNSVC

    systemctl daemon-reload
    systemctl enable badvpn >/dev/null 2>&1
    systemctl start badvpn
    sleep 1

    if systemctl is-active --quiet badvpn; then
        msg_ok "badvpn running on port 7300"
    else
        msg_err "badvpn failed to start"
        return 1
    fi
}

uninstall_badvpn() {
    echo ""
    echo -e " ${CB}${RED}--- Uninstall badvpn ---${CR}"
    if [[ ! -f /etc/systemd/system/badvpn.service ]]; then
        msg_warn "badvpn is not installed."
        return 0
    fi
    if [[ "$UNINSTALL_MODE" != "silent" ]]; then
        read -rp " Are you sure? (y/n): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && { msg_warn "Cancelled"; return 0; }
    fi
    systemctl stop badvpn 2>/dev/null
    systemctl disable badvpn 2>/dev/null
    rm -f /etc/systemd/system/badvpn.service
    rm -f /usr/local/bin/badvpn-udpgw
    systemctl daemon-reload
    msg_ok "badvpn uninstalled"
}

# ========================= FALCON PROXY ======================================
install_falcon_proxy() {
    echo ""
    echo -e " ${CB}${CYN}--- Installing Falcon Proxy (Websockets/Socks) ---${CR}"
    echo ""

    if [[ -f "$FALCONPROXY_SERVICE_FILE" ]]; then
        msg_warn "Falcon Proxy is already installed."
        if [[ -f "$FALCONPROXY_CONFIG_FILE" ]]; then
            source "$FALCONPROXY_CONFIG_FILE"
            echo -e "   Configured on port(s): ${YLW}$PORTS${CR}"
            echo -e "   Version: ${YLW}${INSTALLED_VERSION:-Unknown}${CR}"
        fi
        read -rp " Reinstall/update? (y/n) [n]: " confirm_reinstall
        [[ ! "$confirm_reinstall" =~ ^[Yy]$ ]] && return 0
    fi

    echo -e " ${BLU}Fetching available versions from GitHub...${CR}"
    local releases_json
    releases_json=$(curl -s "https://api.github.com/repos/firewallfalcons/FirewallFalcon-Manager/releases")
    if [[ -z "$releases_json" || "$releases_json" == "[]" ]]; then
        msg_err "Could not fetch releases. Check internet or API limits."
        return 1
    fi

    mapfile -t versions < <(echo "$releases_json" | jq -r '.[].tag_name' 2>/dev/null | head -10)

    if [[ ${#versions[@]} -eq 0 ]]; then
        msg_err "No releases found in the repository."
        return 1
    fi

    echo ""
    echo -e " ${CYN}Select a version to install:${CR}"
    for i in "${!versions[@]}"; do
        printf "   ${GRN}[%2d]${CR} %s\n" "$((i+1))" "${versions[$i]}"
    done
    echo -e "   ${RED}[ 0]${CR} Cancel"
    echo ""

    local choice
    while true; do
        read -rp " Enter version number [1]: " choice
        choice=${choice:-1}
        [[ "$choice" == "0" ]] && return 0
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -le "${#versions[@]}" ]]; then
            SELECTED_VERSION="${versions[$((choice-1))]}"
            break
        else
            msg_err "Invalid selection."
        fi
    done

    local ports
    read -rp " Enter port(s) for Falcon Proxy (e.g., 8080 or 8080 8888) [8080]: " ports
    ports=${ports:-8080}

    local port_array=($ports)
    for port in "${port_array[@]}"; do
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
            msg_err "Invalid port number: $port. Aborting."
            return 1
        fi
        check_and_open_firewall_port "$port" tcp
    done

    echo ""
    echo -e " ${GRN}Detecting system architecture...${CR}"
    local arch=$(uname -m)
    local binary_name=""
    if [[ "$arch" == "x86_64" ]]; then
        binary_name="falconproxy"
        echo -e " ${BLU}Detected x86_64 (amd64) architecture.${CR}"
    elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        binary_name="falconproxyarm"
        echo -e " ${BLU}Detected ARM64 architecture.${CR}"
    else
        msg_err "Unsupported architecture: $arch"
        return 1
    fi

    local download_url="https://github.com/firewallfalcons/FirewallFalcon-Manager/releases/download/$SELECTED_VERSION/$binary_name"

    echo ""
    echo -e " ${GRN}Downloading Falcon Proxy $SELECTED_VERSION ($binary_name)...${CR}"
    download_binary "$download_url" "$FALCONPROXY_BINARY" "falconproxy" 50000 || return 1

    echo ""
    echo -e " ${GRN}Creating systemd service file...${CR}"
    cat > "$FALCONPROXY_SERVICE_FILE" <<EOF
[Unit]
Description=Falcon Proxy ($SELECTED_VERSION) - XxXjihad
After=network.target

[Service]
User=root
Type=simple
ExecStart=$FALCONPROXY_BINARY -p $ports
Restart=always
RestartSec=2s

[Install]
WantedBy=default.target
EOF

    echo -e " ${GRN}Saving configuration...${CR}"
    mkdir -p "$(dirname "$FALCONPROXY_CONFIG_FILE")"
    cat > "$FALCONPROXY_CONFIG_FILE" <<EOF
PORTS="$ports"
INSTALLED_VERSION="$SELECTED_VERSION"
EOF

    echo -e " ${GRN}Enabling and starting Falcon Proxy service...${CR}"
    systemctl daemon-reload
    systemctl enable falconproxy.service >/dev/null 2>&1
    systemctl restart falconproxy.service
    sleep 2

    if systemctl is-active --quiet falconproxy; then
        echo ""
        msg_ok "SUCCESS: Falcon Proxy $SELECTED_VERSION is installed and active."
        echo -e "   Listening on port(s): ${YLW}$ports${CR}"
        log_i "Falcon Proxy $SELECTED_VERSION installed on port(s) $ports"
    else
        msg_err "Falcon Proxy service failed to start."
        journalctl -u falconproxy.service -n 15 --no-pager
        return 1
    fi
}

uninstall_falcon_proxy() {
    echo ""
    echo -e " ${CB}${RED}--- Uninstalling Falcon Proxy ---${CR}"

    if [[ ! -f "$FALCONPROXY_SERVICE_FILE" ]]; then
        msg_warn "Falcon Proxy is not installed, skipping."
        return 0
    fi

    if [[ "$UNINSTALL_MODE" != "silent" ]]; then
        read -rp " Are you sure? (y/n): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && { msg_warn "Cancelled"; return 0; }
    fi

    echo -e " ${GRN}Stopping and disabling Falcon Proxy service...${CR}"
    systemctl stop falconproxy.service >/dev/null 2>&1
    systemctl disable falconproxy.service >/dev/null 2>&1
    echo -e " ${GRN}Removing service file...${CR}"
    rm -f "$FALCONPROXY_SERVICE_FILE"
    systemctl daemon-reload
    echo -e " ${GRN}Removing binary and config files...${CR}"
    rm -f "$FALCONPROXY_BINARY"
    rm -f "$FALCONPROXY_CONFIG_FILE"
    msg_ok "Falcon Proxy has been uninstalled successfully."
    log_i "Falcon Proxy uninstalled"
}

# ========================= ZIVPN =============================================
install_zivpn() {
    echo ""
    echo -e " ${CB}${CYN}--- Installing ZiVPN (UDP/VPN) ---${CR}"
    echo ""

    if [[ -f "$ZIVPN_SERVICE_FILE" ]]; then
        msg_warn "ZiVPN is already installed."
        return 0
    fi

    echo -e " ${GRN}Checking system architecture...${CR}"
    local arch=$(uname -m)
    local zivpn_url=""

    if [[ "$arch" == "x86_64" ]]; then
        zivpn_url="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64"
        echo -e " ${BLU}Detected AMD64/x86_64 architecture.${CR}"
    elif [[ "$arch" == "aarch64" ]]; then
        zivpn_url="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-arm64"
        echo -e " ${BLU}Detected ARM64 architecture.${CR}"
    elif [[ "$arch" == "armv7l" || "$arch" == "arm" ]]; then
        zivpn_url="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-arm"
        echo -e " ${BLU}Detected ARM architecture.${CR}"
    else
        msg_err "Unsupported architecture: $arch"
        return 1
    fi

    echo ""
    echo -e " ${GRN}Downloading ZiVPN binary...${CR}"
    download_binary "$zivpn_url" "$ZIVPN_BIN" "zivpn" 50000 || return 1

    echo ""
    echo -e " ${GRN}Configuring ZiVPN...${CR}"
    mkdir -p "$ZIVPN_DIR"

    echo -e " ${BLU}Generating self-signed certificates...${CR}"
    command -v openssl &>/dev/null || apt-get install -y openssl 2>&1

    openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
        -subj "/C=US/ST=California/L=Los Angeles/O=XxXjihad/OU=VPN/CN=zivpn" \
        -keyout "$ZIVPN_KEY_FILE" -out "$ZIVPN_CERT_FILE" 2>/dev/null

    cat > "$ZIVPN_CONFIG_FILE" <<EOF
{
  "listen_addr": ":5667",
  "cert_file": "$ZIVPN_CERT_FILE",
  "key_file": "$ZIVPN_KEY_FILE",
  "auth": {
    "mode": "passwords",
    "config": []
  }
}
EOF

    echo ""
    echo -e " ${GRN}Starting ZiVPN Service...${CR}"
    systemctl daemon-reload
    systemctl enable zivpn.service >/dev/null 2>&1
    systemctl start zivpn.service

    echo -e " ${BLU}Configuring Firewall Rules (Redirecting 6000-19999 -> 5667)...${CR}"
    local iface=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    if [[ -n "$iface" ]]; then
        iptables -t nat -A PREROUTING -i "$iface" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null
    fi
    fw_allow 5667 udp
    fw_allow 6000:19999 udp 2>/dev/null
    if command -v ufw &>/dev/null; then
        ufw allow 6000:19999/udp >/dev/null 2>&1
    fi

    if systemctl is-active --quiet zivpn.service; then
        echo ""
        msg_ok "ZiVPN Installed Successfully!"
        echo -e "   - UDP Port: 5667 (Direct)"
        echo -e "   - UDP Ports: 6000-19999 (Redirected to 5667)"
        log_i "ZiVPN installed on port 5667"
    else
        msg_err "ZiVPN service failed to start."
        journalctl -u zivpn.service -n 15 --no-pager
        return 1
    fi
}

uninstall_zivpn() {
    echo ""
    echo -e " ${CB}${RED}--- Uninstalling ZiVPN ---${CR}"

    if [[ ! -f "$ZIVPN_SERVICE_FILE" ]]; then
        msg_warn "ZiVPN is not installed."
        return 0
    fi

    if [[ "$UNINSTALL_MODE" != "silent" ]]; then
        read -rp " Are you sure? (y/n): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && { msg_warn "Cancelled"; return 0; }
    fi

    echo -e " ${GRN}Stopping and disabling ZiVPN service...${CR}"
    systemctl stop zivpn.service >/dev/null 2>&1
    systemctl disable zivpn.service >/dev/null 2>&1
    rm -f "$ZIVPN_SERVICE_FILE"
    rm -f "$ZIVPN_BIN"
    rm -rf "$ZIVPN_DIR"

    local iface=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    if [[ -n "$iface" ]]; then
        iptables -t nat -D PREROUTING -i "$iface" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null
    fi

    systemctl daemon-reload
    msg_ok "ZiVPN has been uninstalled."
    log_i "ZiVPN uninstalled"
}

# ========================= NGINX PROXY =======================================
install_nginx_proxy() {
    echo ""
    echo -e " ${CB}${CYN}--- Reconfiguring Internal Nginx Proxy (${NGINX_INTERNAL_HTTP_PORT}/${NGINX_INTERNAL_TLS_PORT}) ---${CR}"
    echo ""

    if [[ ! -s "$SSL_CERT_FILE" ]] || [[ ! -s "$SSL_CERT_CHAIN_FILE" ]] || [[ ! -s "$SSL_CERT_KEY_FILE" ]]; then
        msg_warn "No shared certificate found. Running full HAProxy edge installer..."
        install_ssl_tunnel
        return
    fi

    mkdir -p "$XXJIHAD_DIR"/{db,ssl}
    ensure_edge_stack_packages || return

    # FIX: Stop and clean any conflicting Nginx default config
    systemctl stop nginx >/dev/null 2>&1
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    sleep 1

    check_and_free_ports "$EDGE_PUBLIC_HTTP_PORT" "$EDGE_PUBLIC_TLS_PORT" \
        "$NGINX_INTERNAL_HTTP_PORT" "$NGINX_INTERNAL_TLS_PORT" "$HAPROXY_INTERNAL_DECRYPT_PORT" || return

    check_and_open_firewall_port "$EDGE_PUBLIC_HTTP_PORT" tcp
    check_and_open_firewall_port "$EDGE_PUBLIC_TLS_PORT" tcp

    load_edge_cert_info
    local server_name="${EDGE_DOMAIN:-$(detect_preferred_host)}"
    [[ -z "$server_name" ]] && server_name="_"

    configure_edge_stack "$server_name" || return

    msg_ok "Internal Nginx proxy reconfigured successfully."
    echo -e "   Public HAProxy edge: ${YLW}${EDGE_PUBLIC_HTTP_PORT}/${EDGE_PUBLIC_TLS_PORT}${CR}"
    echo -e "   Internal Nginx: ${YLW}${NGINX_INTERNAL_HTTP_PORT}/${NGINX_INTERNAL_TLS_PORT}${CR}"
}

purge_nginx() {
    local mode="${1:-interactive}"
    if [[ "$mode" != "silent" ]]; then
        echo ""
        echo -e " ${CB}${RED}--- Purge Internal Nginx ---${CR}"
        read -rp " This will completely remove Nginx. Continue? (y/n): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && { msg_warn "Cancelled"; return 0; }
    fi

    systemctl stop nginx >/dev/null 2>&1
    systemctl disable nginx >/dev/null 2>&1
    apt-get purge -y nginx nginx-common nginx-full >/dev/null 2>&1
    rm -rf /etc/nginx
    rm -f "${NGINX_CONFIG_FILE}.bak"* "$NGINX_PORTS_FILE"

    if [[ "$mode" != "silent" ]]; then
        msg_ok "Internal Nginx proxy purged."
    fi
}

request_certbot_ssl() {
    echo ""
    echo -e " ${CB}${CYN}--- Shared Certbot Certificate (HAProxy + Nginx) ---${CR}"
    echo ""

    mkdir -p "$XXJIHAD_DIR"/{db,ssl}
    ensure_edge_stack_packages || return
    load_edge_cert_info

    local preferred_host default_domain="" domain_name email
    preferred_host=$(detect_preferred_host)

    if [[ -n "$EDGE_DOMAIN" ]] && ! is_valid_ip4 "$EDGE_DOMAIN"; then
        default_domain="$EDGE_DOMAIN"
    elif [[ -n "$preferred_host" ]] && ! is_valid_ip4 "$preferred_host"; then
        default_domain="$preferred_host"
    fi

    if [[ -n "$default_domain" ]]; then
        read -rp " Enter domain name [$default_domain]: " domain_name
        domain_name=${domain_name:-$default_domain}
    else
        read -rp " Enter domain name (e.g., vpn.example.com): " domain_name
    fi
    [[ -z "$domain_name" ]] && { msg_err "Domain name required"; return 1; }
    is_valid_ip4 "$domain_name" && { msg_err "Certbot requires a domain, not an IP"; return 1; }

    read -rp " Enter email for Let's Encrypt [${EDGE_EMAIL:-}]: " email
    email=${email:-$EDGE_EMAIL}
    [[ -z "$email" ]] && { msg_err "Email required"; return 1; }

    check_and_open_firewall_port "$EDGE_PUBLIC_HTTP_PORT" tcp
    check_and_open_firewall_port "$EDGE_PUBLIC_TLS_PORT" tcp

    obtain_certbot_edge_cert "$domain_name" "$email" || return
    configure_edge_stack "$domain_name" || return

    msg_ok "Shared Certbot certificate applied successfully."
    echo -e "   Domain: ${YLW}${domain_name}${CR}"
    echo -e "   Public edge: ${YLW}${EDGE_PUBLIC_HTTP_PORT}/${EDGE_PUBLIC_TLS_PORT}${CR}"
}

nginx_proxy_menu() {
    while true; do
        echo ""
        echo -e " ${CB}${CYN}--- Internal Nginx Proxy Management ---${CR}"
        echo ""

        local nginx_status="${RED}Inactive${CR}"
        local haproxy_status="${RED}Inactive${CR}"
        systemctl is-active --quiet nginx 2>/dev/null && nginx_status="${GRN}Active${CR}"
        systemctl is-active --quiet haproxy 2>/dev/null && haproxy_status="${GRN}Active${CR}"

        load_edge_cert_info 2>/dev/null
        local cert_info="${EDGE_CERT_MODE:-Not configured}"
        [[ -n "$EDGE_DOMAIN" ]] && cert_info="${cert_info} - ${EDGE_DOMAIN}"

        echo -e " Nginx: $nginx_status | HAProxy: $haproxy_status"
        echo -e " ${GRY}Public: ${EDGE_PUBLIC_HTTP_PORT}/${EDGE_PUBLIC_TLS_PORT} | Internal: ${NGINX_INTERNAL_HTTP_PORT}/${NGINX_INTERNAL_TLS_PORT}${CR}"
        echo -e " ${GRY}Certificate: ${cert_info}${CR}"
        echo ""

        if systemctl is-active --quiet nginx 2>/dev/null; then
            echo -e "   ${GRN}[1]${CR} Stop Nginx Service"
            echo -e "   ${GRN}[2]${CR} Restart HAProxy + Nginx Stack"
        else
            echo -e "   ${GRN}[1]${CR} Start Nginx Service"
            echo -e "   ${GRN}[2]${CR} Restart HAProxy + Nginx Stack"
        fi
        echo -e "   ${GRN}[3]${CR} Re-install/Re-configure Edge Stack"
        echo -e "   ${GRN}[4]${CR} Switch/Renew Shared SSL (Certbot)"
        echo -e "   ${RED}[5]${CR} Uninstall/Purge Nginx"
        echo -e "   ${GRY}[0]${CR} Back"
        echo ""
        read -rp " Choice: " ch
        # FIX: Ensure 0 exits the menu correctly
        if [[ "$ch" == "0" ]]; then return; fi
        
        case "$ch" in
            1)
                if systemctl is-active --quiet nginx 2>/dev/null; then
                    msg_info "Stopping Nginx..."
                    systemctl stop nginx
                    msg_ok "Nginx stopped"
                else
                    msg_info "Starting Nginx..."
                    systemctl start nginx
                    if systemctl is-active --quiet nginx; then
                        msg_ok "Nginx started"
                    else
                        msg_err "Failed to start Nginx"
                    fi
                fi
                ;;
            2)
                msg_info "Restarting Nginx and HAProxy..."
                local restart_ok=true
                systemctl restart nginx 2>/dev/null || restart_ok=false
                command -v haproxy &>/dev/null && systemctl restart haproxy 2>/dev/null || restart_ok=false
                if $restart_ok && systemctl is-active --quiet nginx && systemctl is-active --quiet haproxy; then
                    msg_ok "HAProxy + Nginx stack restarted"
                else
                    msg_err "One or more services failed to restart"
                fi
                ;;
            3) install_nginx_proxy ;;
            4) request_certbot_ssl ;;
            5) purge_nginx ;;
            *) msg_err "Invalid option" ;;
        esac
        echo ""
        echo -e " ${GRY}Press Enter to continue...${CR}"
        read -r
    done
}

# ========================= X-UI PANEL ========================================
install_xui_panel() {
    echo ""
    echo -e " ${CB}${CYN}--- Install X-UI Panel (V2Ray Management) ---${CR}"
    echo ""
    echo -e "   ${GRN}[1]${CR} Install latest version"
    echo -e "   ${GRN}[2]${CR} Install specific version"
    echo -e "   ${RED}[0]${CR} Cancel"
    echo ""
    read -rp " Choice: " xui_choice
    case "$xui_choice" in
        1)
            msg_info "Installing latest X-UI..."
            bash <(curl -Ls https://raw.githubusercontent.com/alireza0/x-ui/master/install.sh)
            ;;
        2)
            read -rp " Enter version (e.g., 1.8.0): " version
            [[ -z "$version" ]] && { msg_err "Version required"; return 1; }
            msg_info "Installing X-UI v${version}..."
            VERSION=$version bash <(curl -Ls "https://raw.githubusercontent.com/alireza0/x-ui/${version}/install.sh") "$version"
            ;;
        0) return 0 ;;
        *) msg_err "Invalid option" ;;
    esac
}

uninstall_xui_panel() {
    echo ""
    echo -e " ${CB}${RED}--- Uninstall X-UI Panel ---${CR}"
    if ! command -v x-ui &>/dev/null; then
        msg_warn "X-UI is not installed."
        return 0
    fi
    if [[ "$UNINSTALL_MODE" != "silent" ]]; then
        read -rp " Are you sure? (y/n): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && { msg_warn "Cancelled"; return 0; }
    fi
    msg_info "Running X-UI uninstaller..."
    x-ui uninstall >/dev/null 2>&1
    msg_info "Performing full cleanup..."
    systemctl stop x-ui 2>/dev/null
    systemctl disable x-ui 2>/dev/null
    rm -f /etc/systemd/system/x-ui.service
    rm -f /usr/local/bin/x-ui
    rm -rf /usr/local/x-ui/ /etc/x-ui/
    systemctl daemon-reload
    msg_ok "X-UI completely uninstalled"
}
