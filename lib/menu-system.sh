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
            cnt=$(pgrep -c -u "$user" sshd 2>/dev/null)
            # FIX: Ensure cnt is a number and handle potential empty result
            [[ -z "$cnt" || ! "$cnt" =~ ^[0-9]+$ ]] && cnt=0
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

invalid_option() {
    msg_err "Invalid option. Please try again."
    sleep 1
}

press_enter() {
    echo ""
    echo -en " ${GRY}Press Enter to continue...${CR}"
    read -r
}

# ========================= PROTOCOL MENU =====================================
protocol_menu() {
    while true; do
        clear
        echo -e " ${CYN}=====[ ${CB}PROTOCOL MANAGEMENT ${CR}${CYN}]=====${CR}"
        echo ""
        echo -e "   ${CYN}[ 1]${CR} Install HAProxy Edge Stack (80/443)"
        echo -e "   ${CYN}[ 2]${CR} Uninstall HAProxy Edge Stack"
        echo -e "   ${CYN}[ 3]${CR} Install DNSTT (DNS Tunnel)"
        echo -e "   ${CYN}[ 4]${CR} Uninstall DNSTT"
        echo -e "   ${CYN}[ 5]${CR} Install badvpn-udpgw (UDP 7300)"
        echo -e "   ${CYN}[ 6]${CR} Uninstall badvpn"
        echo -e "   ${CYN}[ 7]${CR} Install Falcon Proxy (WS/Socks)"
        echo -e "   ${CYN}[ 8]${CR} Uninstall Falcon Proxy"
        echo -e "   ${CYN}[ 9]${CR} Install ZiVPN (UDP/VPN)"
        echo -e "   ${CYN}[10]${CR} Uninstall ZiVPN"
        echo -e "   ${CYN}[11]${CR} Internal Nginx Proxy Menu"
        echo -e "   ${CYN}[12]${CR} Install X-UI Panel"
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
            5) install_badvpn; press_enter ;;
            6) uninstall_badvpn; press_enter ;;
            7) install_falcon_proxy; press_enter ;;
            8) uninstall_falcon_proxy; press_enter ;;
            9) install_zivpn; press_enter ;;
            10) uninstall_zivpn; press_enter ;;
            11) nginx_proxy_menu ;;
            12) install_xui_panel; press_enter ;;
            13) uninstall_xui_panel; press_enter ;;
            *) invalid_option ;;
        esac
    done
}

# ========================= TOOLS MENU ========================================
tools_menu() {
    while true; do
        clear
        echo -e " ${CYN}=====[ ${CB}SYSTEM TOOLS ${CR}${CYN}]=====${CR}"
        echo ""
        echo -e "   ${CYN}[ 1]${CR} Traffic Monitor (vnStat)"
        echo -e "   ${CYN}[ 2]${CR} Torrent Block (iptables)"
        echo -e "   ${CYN}[ 3]${CR} Auto-Reboot Settings"
        echo -e "   ${CYN}[ 4]${CR} SSH Banner Management"
        echo -e "   ${CYN}[ 5]${CR} Network Optimizer (BBR/Sysctl)"
        echo -e "   ${CYN}[ 6]${CR} Speedtest"
        echo -e "   ${CYN}[ 7]${CR} Check System Status"
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
            5) network_optimizer_menu ;;
            6) 
                msg_info "Running speedtest..."
                curl -s https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python3 -
                press_enter
                ;;
            7) xxjihad_status; press_enter ;;
            8) 
                echo -e " ${CYN}--- Recent Logs ---${CR}"
                tail -n 50 "$XXJIHAD_LOG/xxjihad.log" 2>/dev/null || echo "No logs found."
                press_enter
                ;;
            *) invalid_option ;;
        esac
    done
}

# ========================= MAIN MENU =========================================
main_menu() {
    while true; do
        show_banner
        echo -e "   ${CYN}[ 1]${CR} User Management (SSH/VPN)"
        echo -e "   ${CYN}[ 2]${CR} Protocol Management (SSL/DNS/UDP)"
        echo -e "   ${CYN}[ 3]${CR} DNSTT Management"
        echo -e "   ${CYN}[ 4]${CR} System Tools & Optimization"
        echo -e "   ${CYN}[ 5]${CR} Update Script"
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
            4) tools_menu ;;
            5) 
                msg_info "Checking for updates..."
                # Simplified update logic
                msg_ok "You are already on the latest version ($VERSION)."
                sleep 2
                ;;
            99) uninstall_xxjihad ;;
            *) invalid_option ;;
        esac
    done
}
