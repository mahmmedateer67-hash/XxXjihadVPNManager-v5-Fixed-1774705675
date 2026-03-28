#!/bin/bash
###############################################################################
#  XxXjihad :: MENU SYSTEM v5.0                                               #
#  Main menu, protocol menu, tools menu, banner, uninstall                    #
###############################################################################

CR=$'\033[0m'; CB=$'\033[1m'; CD=$'\033[2m'
RED=$'\033[38;5;196m'; GRN=$'\033[38;5;46m'; YLW=$'\033[38;5;226m'
BLU=$'\033[38;5;39m'; PRP=$'\033[38;5;135m'; CYN=$'\033[38;5;51m'
WHT=$'\033[38;5;255m'; GRY=$'\033[38;5;245m'; ORG=$'\033[38;5;208m'

msg_ok()   { echo -e " ${GRN}[OK]${CR} $*"; }
msg_err()  { echo -e " ${RED}[ERROR]${CR} $*"; }
msg_warn() { echo -e " ${YLW}[WARN]${CR} $*"; }
msg_info() { echo -e " ${BLU}[INFO]${CR} $*"; }

show_banner() {
    clear
    local ip4
    ip4=$(curl -s -4 --max-time 3 icanhazip.com 2>/dev/null || echo "N/A")
    local total_users=0 online_users=0
    [[ -f "/etc/xxjihad/db/users.db" ]] && total_users=$(grep -c . "/etc/xxjihad/db/users.db" 2>/dev/null)
    if [[ -f "/etc/xxjihad/db/users.db" ]]; then
        while IFS=: read -r user _rest; do
            [[ -z "$user" || "$user" == \#* ]] && continue
            local cnt
            cnt=$(pgrep -c -u "$user" sshd 2>/dev/null || echo 0)
            online_users=$((online_users + cnt))
        done < "/etc/xxjihad/db/users.db"
    fi
    local uptime_str
    uptime_str=$(uptime -p 2>/dev/null | sed 's/up //')
    local os_info
    os_info=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "Linux")

    echo ""
    echo -e " ${CYN}+============================================================+${CR}"
    echo -e " ${CYN}|${CR}                                                            ${CYN}|${CR}"
    echo -e " ${CYN}|${CR}    ${CB}${WHT}X${CYN}x${WHT}X${CYN}j${WHT}i${CYN}h${WHT}a${CYN}d${CR}  ${CB}${WHT}VPN Manager${CR}  ${GRY}v5.0${CR}                       ${CYN}|${CR}"
    echo -e " ${CYN}|${CR}                                                            ${CYN}|${CR}"
    echo -e " ${CYN}|${CR}    ${GRY}Server:${CR} ${WHT}${ip4}${CR}                                    ${CYN}|${CR}"
    echo -e " ${CYN}|${CR}    ${GRY}OS:${CR}     ${WHT}${os_info}${CR}                        ${CYN}|${CR}"
    echo -e " ${CYN}|${CR}    ${GRY}Uptime:${CR} ${WHT}${uptime_str}${CR}                            ${CYN}|${CR}"
    echo -e " ${CYN}|${CR}    ${GRY}Users:${CR}  ${WHT}${total_users}${CR} total | ${GRN}${online_users}${CR} online                    ${CYN}|${CR}"
    echo -e " ${CYN}|${CR}    ${GRY}TG:${CR}     ${WHT}https://t.me/XxXjihad${CR}                     ${CYN}|${CR}"
    echo -e " ${CYN}|${CR}                                                            ${CYN}|${CR}"
    echo -e " ${CYN}+============================================================+${CR}"
    echo ""
}

press_enter() {
    echo ""
    echo -e " ${GRY}Press Enter to continue...${CR}"
    read -r
}

invalid_option() {
    msg_err "Invalid option. Please try again."
    sleep 1
}

# ========================= SERVICE STATUS ====================================
xxjihad_status() {
    echo ""
    echo -e " ${CB}${CYN}--- Service Status Dashboard ---${CR}"
    echo ""

    local services=(
        "sshd:SSH Server"
        "haproxy:HAProxy Edge"
        "nginx:Nginx Proxy"
        "xxjihad-dnstt:DNSTT Tunnel"
        "falconproxy:Falcon Proxy"
        "zivpn:ZiVPN UDP"
        "badvpn:BadVPN UDPGW"
        "xxjihad-limiter:User Limiter"
        "x-ui:X-UI Panel"
    )

    printf " ${CB}${WHT}%-25s %-15s${CR}\n" "SERVICE" "STATUS"
    echo -e " ${CYN}$(printf '%.0s-' {1..42})${CR}"

    for entry in "${services[@]}"; do
        local svc_name="${entry%%:*}"
        local svc_label="${entry##*:}"
        local status="${RED}Inactive${CR}"
        if systemctl is-active --quiet "$svc_name" 2>/dev/null; then
            status="${GRN}Active${CR}"
        elif systemctl is-enabled --quiet "$svc_name" 2>/dev/null; then
            status="${YLW}Enabled (Stopped)${CR}"
        fi
        printf " %-25s %b\n" "$svc_label" "$status"
    done
    echo ""

    # Port summary
    echo -e " ${CB}${WHT}Active Listening Ports:${CR}"
    ss -tlnp 2>/dev/null | grep -E "LISTEN" | awk '{print $4}' | sort -t: -k2 -n | uniq | head -20 | while read -r addr; do
        echo -e "   ${GRY}*${CR} $addr"
    done
    echo ""
}

# ========================= PROTOCOL MANAGEMENT MENU ==========================
protocol_menu() {
    while true; do
        show_banner

        local badvpn_status="${GRY}(Inactive)${CR}"
        systemctl is-active --quiet badvpn 2>/dev/null && badvpn_status="${GRN}(Active)${CR}"

        local zivpn_status="${GRY}(Inactive)${CR}"
        systemctl is-active --quiet zivpn.service 2>/dev/null && zivpn_status="${GRN}(Active)${CR}"

        local ssl_tunnel_status="${GRY}(Inactive)${CR}"
        if systemctl is-active --quiet haproxy 2>/dev/null; then
            ssl_tunnel_status="${GRN}(Active)${CR}"
        fi

        local dnstt_status="${GRY}(Inactive)${CR}"
        systemctl is-active --quiet xxjihad-dnstt.service 2>/dev/null && dnstt_status="${GRN}(Active)${CR}"

        local falconproxy_status="${GRY}(Inactive)${CR}"
        local falconproxy_ports=""
        if systemctl is-active --quiet falconproxy 2>/dev/null; then
            [[ -f "$FALCONPROXY_CONFIG_FILE" ]] && source "$FALCONPROXY_CONFIG_FILE"
            falconproxy_ports=" ($PORTS)"
            falconproxy_status="${GRN}(Active - ${INSTALLED_VERSION:-latest})${CR}"
        fi

        local nginx_status="${GRY}(Inactive)${CR}"
        systemctl is-active --quiet nginx 2>/dev/null && nginx_status="${GRN}(Active)${CR}"

        local xui_status="${GRY}(Not Installed)${CR}"
        command -v x-ui &>/dev/null && {
            systemctl is-active --quiet x-ui 2>/dev/null && xui_status="${GRN}(Active)${CR}" || xui_status="${YLW}(Installed/Stopped)${CR}"
        }

        echo -e " ${CYN}=====[ ${CB}PROTOCOL & TUNNEL MANAGEMENT ${CR}${CYN}]=====${CR}"
        echo ""
        echo -e "   ${ORG}--- TUNNELLING PROTOCOLS ---${CR}"
        printf "   ${CYN}[ 1]${CR} %-45s %b\n" "HAProxy Edge Stack (80/443)" "$ssl_tunnel_status"
        printf "   ${CYN}[ 2]${CR} %-45s\n" "Uninstall HAProxy Edge Stack"
        printf "   ${CYN}[ 3]${CR} %-45s %b\n" "DNSTT Tunnel (Port 53)" "$dnstt_status"
        printf "   ${CYN}[ 4]${CR} %-45s\n" "Uninstall DNSTT"
        printf "   ${CYN}[ 5]${CR} %-45s %b\n" "Falcon Proxy${falconproxy_ports}" "$falconproxy_status"
        printf "   ${CYN}[ 6]${CR} %-45s\n" "Uninstall Falcon Proxy"
        printf "   ${CYN}[ 7]${CR} %-45s %b\n" "Nginx Proxy Management" "$nginx_status"
        printf "   ${CYN}[ 8]${CR} %-45s %b\n" "badvpn (UDP 7300)" "$badvpn_status"
        printf "   ${CYN}[ 9]${CR} %-45s\n" "Uninstall badvpn"
        printf "   ${CYN}[10]${CR} %-45s %b\n" "ZiVPN (UDP 5667)" "$zivpn_status"
        printf "   ${CYN}[11]${CR} %-45s\n" "Uninstall ZiVPN"
        echo ""
        echo -e "   ${ORG}--- V2RAY / XRAY ---${CR}"
        printf "   ${CYN}[12]${CR} %-45s %b\n" "X-UI Panel (V2Ray Management)" "$xui_status"
        printf "   ${CYN}[13]${CR} %-45s\n" "Uninstall X-UI Panel"
        echo ""
        echo -e "   ${GRY}[ 0]${CR} Return to Main Menu"
        echo ""
        read -rp " Select an option: " choice
        [[ -z "$choice" ]] && continue
        if [[ "$choice" == "0" ]]; then return; fi

        case "$choice" in
            1) install_ssl_tunnel; press_enter ;;
            2) uninstall_ssl_tunnel; press_enter ;;
            3) install_dnstt; press_enter ;;
            4) uninstall_dnstt; press_enter ;;
            5) install_falcon_proxy; press_enter ;;
            6) uninstall_falcon_proxy; press_enter ;;
            7) nginx_proxy_menu ;;
            8) install_badvpn; press_enter ;;
            9) uninstall_badvpn; press_enter ;;
            10) install_zivpn; press_enter ;;
            11) uninstall_zivpn; press_enter ;;
            12) install_xui_panel; press_enter ;;
            13) uninstall_xui_panel; press_enter ;;
            *) invalid_option ;;
        esac
    done
}

# ========================= TOOLS MENU ========================================
tools_menu() {
    while true; do
        show_banner
        echo -e " ${CYN}=====[ ${CB}TOOLS & UTILITIES ${CR}${CYN}]=====${CR}"
        echo ""
        echo -e "   ${CYN}[ 1]${CR} Traffic Monitor"
        echo -e "   ${CYN}[ 2]${CR} Torrent Blocking (Anti-P2P)"
        echo -e "   ${CYN}[ 3]${CR} Auto-Reboot Management"
        echo -e "   ${CYN}[ 4]${CR} SSH Banner Management"
        echo -e "   ${CYN}[ 5]${CR} CloudFlare Free Domain (DNS)"
        echo -e "   ${CYN}[ 6]${CR} Certbot SSL Certificate"
        echo -e "   ${CYN}[ 7]${CR} Service Status Dashboard"
        echo -e "   ${CYN}[ 8]${CR} View Logs"
        echo ""
        echo -e "   ${GRY}[ 0]${CR} Return to Main Menu"
        echo ""
        read -rp " Select an option: " choice
        [[ -z "$choice" ]] && continue
        if [[ "$choice" == "0" ]]; then return; fi

        case "$choice" in
            1) traffic_monitor_menu; press_enter ;;
            2) torrent_block_menu; press_enter ;;
            3) auto_reboot_menu; press_enter ;;
            4) ssh_banner_menu ;;
            5) dns_menu; press_enter ;;
            6) request_certbot_ssl; press_enter ;;
            7) xxjihad_status; press_enter ;;
            8)
                echo ""
                echo -e " ${CYN}--- Recent Logs ---${CR}"
                tail -50 /var/log/xxjihad/xxjihad.log 2>/dev/null || msg_warn "No logs found."
                press_enter
                ;;
            *) invalid_option ;;
        esac
    done
}

# ========================= UNINSTALL SCRIPT ==================================
uninstall_script() {
    show_banner
    echo -e " ${RED}=====================================================${CR}"
    echo -e " ${RED}       DANGER: UNINSTALL SCRIPT & ALL DATA           ${CR}"
    echo -e " ${RED}=====================================================${CR}"
    echo -e " ${YLW}This will PERMANENTLY remove XxXjihad and all its components:${CR}"
    echo -e "  - The main command (xxjihad)"
    echo -e "  - All configuration and user data (/etc/xxjihad)"
    echo -e "  - All installed services (DNSTT, badvpn, SSL Tunnel, Nginx, FalconProxy, ZiVPN, X-UI)"
    echo ""
    echo -e " ${RED}This action is irreversible.${CR}"
    echo ""
    read -rp " Type 'yes' to confirm: " confirm
    [[ "$confirm" != "yes" ]] && { msg_ok "Uninstallation cancelled."; return; }

    export UNINSTALL_MODE="silent"
    echo ""
    msg_info "Starting uninstallation..."

    # Stop and remove limiter
    systemctl stop xxjihad-limiter &>/dev/null
    systemctl disable xxjihad-limiter &>/dev/null
    rm -f "$LIMITER_SERVICE" "$LIMITER_SCRIPT"

    # Remove SSH banner
    rm -f "$LOGIN_INFO_SCRIPT" "$SSHD_XX_CONFIG"
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null

    chattr -i /etc/resolv.conf &>/dev/null

    # Remove auto-reboot cron
    (crontab -l 2>/dev/null | grep -v "systemctl reboot") | crontab - 2>/dev/null

    # Remove torrent rules
    _flush_torrent_rules 2>/dev/null

    # Uninstall all services
    uninstall_dnstt 2>/dev/null
    uninstall_badvpn 2>/dev/null
    uninstall_ssl_tunnel 2>/dev/null
    uninstall_falcon_proxy 2>/dev/null
    uninstall_zivpn 2>/dev/null
    uninstall_xui_panel 2>/dev/null
    purge_nginx "silent" 2>/dev/null
    delete_dns_records 2>/dev/null

    systemctl daemon-reload

    # Remove files
    rm -rf /etc/xxjihad
    rm -rf /var/log/xxjihad
    rm -rf /var/run/xxjihad
    rm -f /usr/local/bin/xxjihad
    rm -f /usr/local/bin/xxjihad-watchdog
    rm -f /usr/local/bin/xxjihad-heartbeat
    rm -f /usr/local/bin/xxjihad-limiter
    rm -f /usr/local/bin/xxjihad-trial-cleanup

    echo ""
    echo -e " ${GRN}=====================================================${CR}"
    echo -e " ${GRN}      XxXjihad has been successfully uninstalled.     ${CR}"
    echo -e " ${GRN}=====================================================${CR}"
    echo -e " All associated files and services have been removed."
    echo -e " The 'xxjihad' command will no longer work."
    exit 0
}

# ========================= MAIN MENU =========================================
main_menu() {
    while true; do
        show_banner

        # Quick status line
        local dnstt_st="${GRY}OFF${CR}" ssl_st="${GRY}OFF${CR}" nginx_st="${GRY}OFF${CR}" falcon_st="${GRY}OFF${CR}"
        systemctl is-active --quiet xxjihad-dnstt.service 2>/dev/null && dnstt_st="${GRN}ON${CR}"
        systemctl is-active --quiet haproxy 2>/dev/null && ssl_st="${GRN}ON${CR}"
        systemctl is-active --quiet nginx 2>/dev/null && nginx_st="${GRN}ON${CR}"
        systemctl is-active --quiet falconproxy 2>/dev/null && falcon_st="${GRN}ON${CR}"

        echo -e " ${GRY}Services: DNSTT[$dnstt_st${GRY}] Edge[$ssl_st${GRY}] Nginx[$nginx_st${GRY}] Falcon[$falcon_st${GRY}]${CR}"
        echo ""
        echo -e " ${CYN}=====[ ${CB}MAIN MENU ${CR}${CYN}]=====${CR}"
        echo ""
        echo -e "   ${CYN}[ 1]${CR} User Management"
        echo -e "   ${CYN}[ 2]${CR} Protocol & Tunnel Management"
        echo -e "   ${CYN}[ 3]${CR} DNSTT Management"
        echo -e "   ${CYN}[ 4]${CR} Network Optimization"
        echo -e "   ${CYN}[ 5]${CR} Tools & Utilities"
        echo ""
        echo -e "   ${RED}[99]${CR} Uninstall XxXjihad"
        echo -e "   ${GRY}[ 0]${CR} Exit"
        echo ""
        read -rp " Select an option: " choice
        [[ -z "$choice" ]] && continue
        if [[ "$choice" == "0" ]]; then echo -e "\n ${GRN}Goodbye!${CR}\n"; exit 0; fi

        case "$choice" in
            1) user_menu ;;
            2) protocol_menu ;;
            3) dnstt_menu ;;
            4) network_menu ;;
            5) tools_menu ;;
            99) uninstall_script ;;
            *) invalid_option ;;
        esac
    done
}
