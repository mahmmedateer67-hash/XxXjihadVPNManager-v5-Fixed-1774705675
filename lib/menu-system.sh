#!/bin/bash
###############################################################################
#  Xxxjihad :: DNSTT & SSH VPN MENU v7.0.0                                    #
#  Simplified Management Interface - TheFirewoods Inspired                     #
###############################################################################

CR=$'\033[0m'; CB=$'\033[1m'; RED=$'\033[38;5;196m'; GRN=$'\033[38;5;46m'
YLW=$'\033[38;5;226m'; BLU=$'\033[38;5;39m'; CYN=$'\033[38;5;51m'; WHT=$'\033[38;5;255m'

msg_ok()   { echo -e " ${GRN}[OK]${CR} $*"; }
msg_err()  { echo -e " ${RED}[ERROR]${CR} $*"; }
msg_warn() { echo -e " ${YLW}[WARN]${CR} $*"; }
msg_info() { echo -e " ${BLU}[INFO]${CR} $*"; }

show_banner() {
    clear
    local ip4=$(curl -s -4 --max-time 3 icanhazip.com 2>/dev/null || echo "N/A")
    local total_users=0 online_users=0
    [[ -f "/etc/xxxjihad/db/users.db" ]] && total_users=$(grep -c . "/etc/xxxjihad/db/users.db" 2>/dev/null)
    if [[ -f "/etc/xxxjihad/db/users.db" ]]; then
        while IFS=: read -r user _rest; do
            [[ -z "$user" || "$user" == \#* ]] && continue
            local cnt=$(pgrep -c -u "$user" sshd 2>/dev/null)
            [[ -z "$cnt" || ! "$cnt" =~ ^[0-9]+$ ]] && cnt=0
            online_users=$((online_users + cnt))
        done < "/etc/xxxjihad/db/users.db"
    fi
    local uptime_str=$(uptime -p 2>/dev/null | sed 's/up //')

    echo ""
    echo -e " ${CYN}+============================================================+${CR}"
    echo -e " ${CYN}|${CR}    ${CB}${WHT}X${CYN}x${WHT}X${CYN}j${WHT}i${CYN}h${WHT}a${CYN}d${CR}  ${CB}${WHT}DNSTT & SSH VPN Manager${CR}  ${GRY}v7.0.0${CR}              ${CYN}|${CR}"
    echo -e " ${CYN}|${CR}                                                            ${CYN}|${CR}"
    echo -e " ${CYN}|${CR}    ${GRY}Server:${CR} ${WHT}${ip4}${CR}                                    ${CYN}|${CR}"
    echo -e " ${CYN}|${CR}    ${GRY}Uptime:${CR} ${WHT}${uptime_str}${CR}                            ${CYN}|${CR}"
    echo -e " ${CYN}|${CR}    ${GRY}Users:${CR}  ${WHT}${total_users}${CR} total | ${GRN}${online_users}${CR} online                    ${CYN}|${CR}"
    echo -e " ${CYN}|${CR}    ${GRY}TG:${CR}     ${WHT}https://t.me/Xxxjihad${CR}                     ${CYN}|${CR}"
    echo -e " ${CYN}+============================================================+${CR}"
    echo ""
}

main_menu() {
    while true; do
        show_banner
        echo -e "   ${CYN}[ 1]${CR} User Management (SSH VPN)"
        echo -e "   ${CYN}[ 2]${CR} Install DNSTT (Smart DNS)"
        echo -e "   ${CYN}[ 3]${CR} Uninstall DNSTT"
        echo -e "   ${CYN}[ 4]${CR} System Tools & Optimization"
        echo ""
        echo -e "   ${RED}[99]${CR} Uninstall Xxxjihad (Complete Cleanup)"
        echo -e "   ${GRY}[ 0]${CR} Exit"
        echo ""
        read -rp " Select an option: " choice
        [[ -z "$choice" ]] && continue
        if [[ "$choice" == "0" ]]; then echo -e "\n ${GRN}Goodbye!${CR}\n"; exit 0; fi

        case "$choice" in
            1) user_menu ;;
            2) install_dnstt; echo -en "\nPress Enter to continue..."; read -r ;;
            3) uninstall_dnstt; echo -en "\nPress Enter to continue..."; read -r ;;
            4) tools_menu ;;
            99) uninstall_xxxjihad ;;
            *) msg_err "Invalid option"; sleep 1 ;;
        esac
    done
}

tools_menu() {
    while true; do
        clear
        echo -e " ${CYN}=====[ ${CB}SYSTEM TOOLS ${CR}${CYN}]=====${CR}"
        echo ""
        echo -e "   ${CYN}[ 1]${CR} Network Optimizer (BBR)"
        echo -e "   ${CYN}[ 2]${CR} Speedtest"
        echo -e "   ${CYN}[ 3]${CR} View Logs"
        echo ""
        echo -e "   ${GRY}[ 0]${CR} Return to Main Menu"
        echo ""
        read -rp " Select an option: " choice
        [[ -z "$choice" ]] && continue
        if [[ "$choice" == "0" ]]; then return; fi

        case "$choice" in
            1) setup_bbr; apply_sysctl_optimizations; echo -en "\nPress Enter..."; read -r ;;
            2) msg_info "Running speedtest..."; curl -s https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python3 -; echo -en "\nPress Enter..."; read -r ;;
            3) tail -n 50 "$XXXJIHAD_LOG/xxxjihad.log" 2>/dev/null || echo "No logs found."; echo -en "\nPress Enter..."; read -r ;;
            *) msg_err "Invalid option"; sleep 1 ;;
        esac
    done
}

uninstall_xxxjihad() {
    echo ""
    read -rp " Are you sure you want to uninstall EVERYTHING? (y/n): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    
    msg_info "Starting intelligent cleanup..."
    
    # 1. Stop and remove DNSTT (this also deletes DNS records via API)
    uninstall_dnstt
    
    # 2. Remove all VPN users
    if [[ -f "/etc/xxxjihad/db/users.db" ]]; then
        while IFS=: read -r user _rest; do
            [[ -z "$user" ]] && continue
            killall -u "$user" -9 2>/dev/null
            userdel -r "$user" 2>/dev/null
        done < "/etc/xxxjihad/db/users.db"
    fi
    
    # 3. Remove files and commands
    rm -rf "/etc/xxxjihad" "/usr/local/lib/xxxjihad" "/var/log/xxxjihad"
    rm -f "/usr/local/bin/xxxjihad" "/etc/profile.d/xxxjihad-banner.sh"
    
    msg_ok "Xxxjihad uninstalled. System and Domain are clean."
    exit 0
}
