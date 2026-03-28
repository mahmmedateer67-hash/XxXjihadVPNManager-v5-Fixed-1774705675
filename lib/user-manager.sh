#!/bin/bash
###############################################################################
#  XxXjihad :: USER MANAGER v5.0                                              #
#  Create/Delete/List/Renew/Lock/Unlock/Edit/Backup/Restore users,            #
#  Trial accounts, Bulk create, Bandwidth, Expired cleanup                    #
###############################################################################

DB_DIR="/etc/xxjihad/db"
DB_FILE="$DB_DIR/users.db"
BANDWIDTH_DIR="/etc/xxjihad/bandwidth"
BANNER_DIR="/etc/xxjihad/banners"
BACKUP_DIR="/etc/xxjihad/backups"
LIMITER_SERVICE="/etc/systemd/system/xxjihad-limiter.service"
LIMITER_SCRIPT="/usr/local/bin/xxjihad-limiter"
TRIAL_CLEANUP_SCRIPT="/usr/local/bin/xxjihad-trial-cleanup"
LOGIN_INFO_SCRIPT="/etc/xxjihad/banners/login_info.sh"
SSHD_XX_CONFIG="/etc/ssh/sshd_config.d/xxjihad-banner.conf"

CR=$'\033[0m'; CB=$'\033[1m'; CD=$'\033[2m'
RED=$'\033[38;5;196m'; GRN=$'\033[38;5;46m'; YLW=$'\033[38;5;226m'
BLU=$'\033[38;5;39m'; PRP=$'\033[38;5;135m'; CYN=$'\033[38;5;51m'
WHT=$'\033[38;5;255m'; GRY=$'\033[38;5;245m'; ORG=$'\033[38;5;208m'

msg_ok()   { echo -e " ${GRN}[OK]${CR} $*"; }
msg_err()  { echo -e " ${RED}[ERROR]${CR} $*"; }
msg_warn() { echo -e " ${YLW}[WARN]${CR} $*"; }
msg_info() { echo -e " ${BLU}[INFO]${CR} $*"; }

init_user_db() {
    mkdir -p "$DB_DIR" "$BANDWIDTH_DIR" "$BANNER_DIR" "$BACKUP_DIR"
    [[ -f "$DB_FILE" ]] || touch "$DB_FILE"
    chmod 600 "$DB_FILE"
    groupadd xxjusers 2>/dev/null
}

create_user() {
    echo ""
    echo -e " ${CB}${CYN}--- Create New SSH User ---${CR}"
    echo ""
    read -rp " Username: " username
    [[ -z "$username" ]] && { msg_err "Username cannot be empty."; return; }
    if id "$username" &>/dev/null || grep -q "^${username}:" "$DB_FILE"; then
        msg_err "User '$username' already exists."; return
    fi
    local default_pass
    default_pass=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 8)
    read -rp " Password [$default_pass]: " password
    password=${password:-$default_pass}
    read -rp " Duration (days) [30]: " days
    days=${days:-30}
    [[ ! "$days" =~ ^[0-9]+$ ]] && { msg_err "Invalid number."; return; }
    read -rp " Connection limit [1]: " limit
    limit=${limit:-1}
    [[ ! "$limit" =~ ^[0-9]+$ ]] && { msg_err "Invalid number."; return; }
    read -rp " Bandwidth limit in GB (0 = unlimited) [0]: " bandwidth_gb
    bandwidth_gb=${bandwidth_gb:-0}
    [[ ! "$bandwidth_gb" =~ ^[0-9]+\.?[0-9]*$ ]] && { msg_err "Invalid number."; return; }
    local expire_date
    expire_date=$(date -d "+${days} days" +%Y-%m-%d)
    
    # FIX: Ensure VPN users cannot access Shell but can use SSH for tunneling
    useradd -m -s /usr/sbin/nologin "$username" 2>/dev/null
    usermod -aG xxjusers "$username" 2>/dev/null
    echo "$username:$password" | chpasswd
    chage -E "$expire_date" "$username"
    echo "$username:$password:$expire_date:$limit:$bandwidth_gb" >> "$DB_FILE"
    
    local bw_display="Unlimited"
    [[ "$bandwidth_gb" != "0" ]] && bw_display="${bandwidth_gb} GB"
    echo ""
    echo -e " ${GRN}User created successfully!${CR}"
    echo -e " ${CYN}+====================================+${CR}"
    echo -e " ${CYN}|${CR}  Username:     ${YLW}$username${CR}"
    echo -e " ${CYN}|${CR}  Password:     ${YLW}$password${CR}"
    echo -e " ${CYN}|${CR}  Expires:      ${YLW}$expire_date${CR}"
    echo -e " ${CYN}|${CR}  Conn. Limit:  ${YLW}$limit${CR}"
    echo -e " ${CYN}|${CR}  Bandwidth:    ${YLW}$bw_display${CR}"
    echo -e " ${CYN}+====================================+${CR}"
    echo ""
    read -rp " Generate client config? (y/n): " gen_conf
    [[ "$gen_conf" =~ ^[Yy]$ ]] && generate_client_config "$username" "$password"
    update_ssh_banners_config
}

delete_user() {
    echo ""
    echo -e " ${CB}${RED}--- Delete SSH User ---${CR}"
    echo ""
    _select_user_interface "Select user to delete"
    local u=$SELECTED_USER
    [[ "$u" == "NO_USERS" || -z "$u" ]] && return
    read -rp " Delete user '$u'? (y/n): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { msg_warn "Cancelled"; return; }
    killall -u "$u" -9 2>/dev/null
    userdel -r "$u" 2>/dev/null
    sed -i "/^${u}:/d" "$DB_FILE"
    rm -f "$BANDWIDTH_DIR/${u}.usage"
    rm -f "$BANNER_DIR/${u}.txt"
    msg_ok "User '$u' deleted."
    update_ssh_banners_config
}

list_users() {
    echo ""
    echo -e " ${CB}${CYN}--- SSH User List ---${CR}"
    echo ""
    if [[ ! -s "$DB_FILE" ]]; then
        msg_warn "No users found."; return
    fi
    printf " ${CB}${WHT}%-18s %-15s %-12s %-8s %-10s %-8s %-8s${CR}\n" "USERNAME" "PASSWORD" "EXPIRES" "LIMIT" "BANDWIDTH" "ONLINE" "STATUS"
    echo -e " ${CYN}$(printf '%.0s-' {1..85})${CR}"
    while IFS=: read -r user pass expiry limit bandwidth_gb _extra; do
        [[ -z "$user" || "$user" == \#* ]] && continue
        local online
        online=$(pgrep -c -u "$user" sshd 2>/dev/null || echo 0)
        local bw_display="Unlimited"
        [[ -n "$bandwidth_gb" && "$bandwidth_gb" != "0" ]] && bw_display="${bandwidth_gb}GB"
        local status_color="$WHT" status_text="Active"
        if passwd -S "$user" 2>/dev/null | grep -q " L "; then
            status_color="$RED"; status_text="Locked"
        fi
        if [[ "$expiry" != "Never" && -n "$expiry" ]]; then
            local exp_ts now_ts
            exp_ts=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
            now_ts=$(date +%s)
            if [[ $exp_ts -lt $now_ts && $exp_ts -ne 0 ]]; then
                status_color="$RED"; status_text="Expired"
            fi
        fi
        printf " ${status_color}%-18s %-15s %-12s %-8s %-10s %-8s %-8s${CR}\n" "$user" "$pass" "$expiry" "$limit" "$bw_display" "$online" "$status_text"
    done < "$DB_FILE"
    echo ""
}

update_ssh_banners_config() {
    mkdir -p "$(dirname "$LOGIN_INFO_SCRIPT")"
    cat > "$LOGIN_INFO_SCRIPT" << 'BANEOF'
#!/bin/bash
BANNER_DIR="/etc/xxjihad/banners"
user=$(whoami)
# Prevent root from being affected by any banner issues
[[ "$user" == "root" ]] && exit 0
if [[ -f "$BANNER_DIR/${user}.txt" ]]; then
    cat "$BANNER_DIR/${user}.txt"
fi
BANEOF
    chmod +x "$LOGIN_INFO_SCRIPT"
    
    # FIX: Ensure SSH configuration is clean and doesn't block root
    mkdir -p /etc/ssh/sshd_config.d/
    rm -f "$SSHD_XX_CONFIG"
    rm -f /etc/ssh/sshd_config.d/xxjihad.conf
    
    # Add to global profile safely
    cat > /etc/profile.d/xxjihad-banner.sh << 'PROFOF'
# Only run for non-root users in the xxjusers group
if [[ "$USER" != "root" ]] && id -nG | grep -q "xxjusers"; then
    /etc/xxjihad/banners/login_info.sh 2>/dev/null
fi
PROFOF
    chmod +x /etc/profile.d/xxjihad-banner.sh

    # Critical: Ensure PermitRootLogin is preserved
    if ! grep -q "PermitRootLogin yes" /etc/ssh/sshd_config; then
        sed -i 's/^#?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    fi

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
        echo -e "   ${CYN}[ 4]${CR} Renew User"
        echo -e "   ${CYN}[ 5]${CR} Change Password"
        echo -e "   ${CYN}[ 6]${CR} View User Bandwidth"
        echo -e "   ${CYN}[ 7]${CR} Create Trial Account"
        echo -e "   ${CYN}[ 8]${CR} Bulk Create Users"
        echo -e "   ${CYN}[ 9]${CR} Generate Client Config"
        echo -e "   ${CYN}[10]${CR} Lock User"
        echo -e "   ${CYN}[11]${CR} Unlock User"
        echo -e "   ${CYN}[12]${CR} Edit User"
        echo -e "   ${CYN}[13]${CR} Cleanup Expired Users"
        echo -e "   ${CYN}[14]${CR} Backup Users"
        echo -e "   ${CYN}[15]${CR} Restore Users"
        echo -e "   ${GRY}[ 0]${CR} Back"
        echo ""
        read -rp " Choice: " ch
        [[ -z "$ch" ]] && continue
        if [[ "$ch" == "0" ]]; then return; fi
        case "$ch" in
            1) create_user ;;
            2) delete_user ;;
            3) list_users ;;
            4) renew_user ;;
            5) change_user_password ;;
            6) view_user_bandwidth ;;
            7) create_trial_account ;;
            8) bulk_create_users ;;
            9) 
                _select_user_interface "Select user"
                [[ -n "$SELECTED_USER" ]] && generate_client_config "$SELECTED_USER"
                ;;
            10) lock_user ;;
            11) unlock_user ;;
            12) edit_user ;;
            13) cleanup_expired_users ;;
            14) backup_users ;;
            15) restore_users ;;
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
