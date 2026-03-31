#!/bin/bash
###############################################################################
#  XxXjihad :: SSH VPN USER MANAGER v6.0.0                                    #
#  Specialized for SSH VPN Accounts only - TheFirewoods Inspired              #
###############################################################################

DB_DIR="/etc/xxjihad/db"
DB_FILE="$DB_DIR/users.db"
BANNER_DIR="/etc/xxjihad/banners"
LOGIN_INFO_SCRIPT="/etc/xxjihad/banners/login_info.sh"

CR=$'\033[0m'; CB=$'\033[1m'; RED=$'\033[38;5;196m'; GRN=$'\033[38;5;46m'
YLW=$'\033[38;5;226m'; BLU=$'\033[38;5;39m'; CYN=$'\033[38;5;51m'; WHT=$'\033[38;5;255m'

msg_ok()   { echo -e " ${GRN}[OK]${CR} $*"; }
msg_err()  { echo -e " ${RED}[ERROR]${CR} $*"; }
msg_warn() { echo -e " ${YLW}[WARN]${CR} $*"; }
msg_info() { echo -e " ${BLU}[INFO]${CR} $*"; }

init_user_db() {
    mkdir -p "$DB_DIR" "$BANNER_DIR"
    [[ -f "$DB_FILE" ]] || touch "$DB_FILE"
    chmod 600 "$DB_FILE"
    groupadd xxjusers 2>/dev/null
}

create_user() {
    echo ""
    echo -e " ${CB}${CYN}--- Create New SSH VPN User ---${CR}"
    echo ""
    read -rp " Username: " username
    [[ -z "$username" ]] && { msg_err "Username cannot be empty."; return; }
    if id "$username" &>/dev/null || grep -q "^${username}:" "$DB_FILE"; then
        msg_err "User '$username' already exists."; return
    fi
    local default_pass=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 8)
    read -rp " Password [$default_pass]: " password
    password=${password:-$default_pass}
    read -rp " Duration (days) [30]: " days
    days=${days:-30}
    [[ ! "$days" =~ ^[0-9]+$ ]] && { msg_err "Invalid number."; return; }
    local expire_date=$(date -d "+${days} days" +%Y-%m-%d)
    
    # Create SSH VPN user (no shell access, only tunneling)
    useradd -m -s /usr/sbin/nologin "$username" 2>/dev/null
    usermod -aG xxjusers "$username" 2>/dev/null
    echo "$username:$password" | chpasswd
    chage -E "$expire_date" "$username"
    echo "$username:$password:$expire_date" >> "$DB_FILE"
    
    msg_ok "SSH VPN user created successfully!"
    echo -e " ${CYN}+====================================+${CR}"
    echo -e " ${CYN}|${CR}  Username:     ${YLW}$username${CR}"
    echo -e " ${CYN}|${CR}  Password:     ${YLW}$password${CR}"
    echo -e " ${CYN}|${CR}  Expires:      ${YLW}$expire_date${CR}"
    echo -e " ${CYN}+====================================+${CR}"
    update_ssh_banners_config
}

delete_user() {
    echo ""
    echo -e " ${CB}${RED}--- Delete SSH VPN User ---${CR}"
    echo ""
    _select_user_interface "Select user to delete"
    local u=$SELECTED_USER
    [[ "$u" == "NO_USERS" || -z "$u" ]] && return
    read -rp " Delete user '$u'? (y/n): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { msg_warn "Cancelled"; return; }
    killall -u "$u" -9 2>/dev/null
    userdel -r "$u" 2>/dev/null
    sed -i "/^${u}:/d" "$DB_FILE"
    msg_ok "User '$u' deleted."
    update_ssh_banners_config
}

list_users() {
    echo ""
    echo -e " ${CB}${CYN}--- SSH VPN User List ---${CR}"
    echo ""
    if [[ ! -s "$DB_FILE" ]]; then
        msg_warn "No users found."; return
    fi
    printf " ${CB}${WHT}%-18s %-15s %-12s %-8s %-8s${CR}\n" "USERNAME" "PASSWORD" "EXPIRES" "ONLINE" "STATUS"
    echo -e " ${CYN}$(printf '%.0s-' {1..70})${CR}"
    while IFS=: read -r user pass expiry _extra; do
        [[ -z "$user" || "$user" == \#* ]] && continue
        local online=$(pgrep -c -u "$user" sshd 2>/dev/null || echo 0)
        local status_color="$WHT" status_text="Active"
        if passwd -S "$user" 2>/dev/null | grep -q " L "; then
            status_color="$RED"; status_text="Locked"
        fi
        if [[ "$expiry" != "Never" && -n "$expiry" ]]; then
            local exp_ts=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
            local now_ts=$(date +%s)
            if [[ $exp_ts -lt $now_ts && $exp_ts -ne 0 ]]; then
                status_color="$RED"; status_text="Expired"
            fi
        fi
        printf " ${status_color}%-18s %-15s %-12s %-8s %-8s${CR}\n" "$user" "$pass" "$expiry" "$online" "$status_text"
    done < "$DB_FILE"
    echo ""
}

update_ssh_banners_config() {
    mkdir -p "$(dirname "$LOGIN_INFO_SCRIPT")"
    cat > "$LOGIN_INFO_SCRIPT" << 'BANEOF'
#!/bin/bash
user=$(whoami)
[[ "$user" == "root" ]] && exit 0
echo -e "\033[1;36m+====================================================+"
echo -e "\033[1;36m|          \033[1;37mXxXjihad\033[0m\033[1;36m SSH VPN Manager v6.0.0       |"
echo -e "\033[1;36m+====================================================+"
echo -e "\033[1;36m| \033[1;37mWelcome, \033[1;33m$user\033[0m\033[1;36m!                                     |"
echo -e "\033[1;36m| \033[1;37mYour account is active for tunneling.              |"
echo -e "\033[1;36m+====================================================+\033[0m"
BANEOF
    chmod +x "$LOGIN_INFO_SCRIPT"
    rm -f /etc/ssh/sshd_config.d/xxjihad-banner.conf
    cat > /etc/profile.d/xxjihad-banner.sh << 'PROFOF'
if [[ "$USER" != "root" ]] && id -nG | grep -q "xxjusers"; then
    /etc/xxjihad/banners/login_info.sh 2>/dev/null
fi
PROFOF
    chmod +x /etc/profile.d/xxjihad-banner.sh
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null
}

user_menu() {
    while true; do
        echo ""
        echo -e " ${CB}${CYN}--- User Management ---${CR}"
        echo ""
        echo -e "   ${CYN}[ 1]${CR} Create User"
        echo -e "   ${CYN}[ 2]${CR} Delete User"
        echo -e "   ${CYN}[ 3]${CR} List Users"
        echo -e "   ${GRY}[ 0]${CR} Back"
        echo ""
        read -rp " Choice: " ch
        [[ -z "$ch" ]] && continue
        if [[ "$ch" == "0" ]]; then return; fi
        case "$ch" in
            1) create_user ;;
            2) delete_user ;;
            3) list_users ;;
            *) msg_err "Invalid option" ;;
        esac
    done
}

_select_user_interface() {
    SELECTED_USER=""
    if [[ ! -s "$DB_FILE" ]]; then
        msg_warn "No users found."
        SELECTED_USER="NO_USERS"
        return
    fi
    local users=()
    while IFS=: read -r user _rest; do
        [[ -z "$user" || "$user" == \#* ]] && continue
        users+=("$user")
    done < "$DB_FILE"
    echo -e " ${CYN}$1:${CR}"
    for i in "${!users[@]}"; do
        printf "   [%2d] %s\n" "$((i+1))" "${users[$i]}"
    done
    echo ""
    read -rp " Select user number: " idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -ge 1 ]] && [[ "$idx" -le "${#users[@]}" ]]; then
        SELECTED_USER="${users[$((idx-1))]}"
    else
        msg_err "Invalid selection."
    fi
}
