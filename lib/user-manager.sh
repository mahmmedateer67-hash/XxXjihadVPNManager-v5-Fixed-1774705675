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

renew_user() {
    echo ""
    echo -e " ${CB}${CYN}--- Renew User Account ---${CR}"
    echo ""
    _select_user_interface "Select user to renew"
    local u=$SELECTED_USER
    [[ "$u" == "NO_USERS" || -z "$u" ]] && return
    read -rp " New duration (days) [30]: " days
    days=${days:-30}
    [[ ! "$days" =~ ^[0-9]+$ ]] && { msg_err "Invalid number."; return; }
    local new_expiry
    new_expiry=$(date -d "+${days} days" +%Y-%m-%d)
    chage -E "$new_expiry" "$u"
    local line pass limit bw
    line=$(grep "^${u}:" "$DB_FILE")
    pass=$(echo "$line" | cut -d: -f2)
    limit=$(echo "$line" | cut -d: -f4)
    bw=$(echo "$line" | cut -d: -f5)
    sed -i "/^${u}:/d" "$DB_FILE"
    echo "$u:$pass:$new_expiry:$limit:$bw" >> "$DB_FILE"
    usermod -U "$u" 2>/dev/null
    msg_ok "User '$u' renewed until $new_expiry"
    update_ssh_banners_config
}

change_user_password() {
    echo ""
    echo -e " ${CB}${CYN}--- Change User Password ---${CR}"
    echo ""
    _select_user_interface "Select user"
    local u=$SELECTED_USER
    [[ "$u" == "NO_USERS" || -z "$u" ]] && return
    local new_pass
    new_pass=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 8)
    read -rp " New password [$new_pass]: " input_pass
    new_pass=${input_pass:-$new_pass}
    echo "$u:$new_pass" | chpasswd
    local line expiry limit bw
    line=$(grep "^${u}:" "$DB_FILE")
    expiry=$(echo "$line" | cut -d: -f3)
    limit=$(echo "$line" | cut -d: -f4)
    bw=$(echo "$line" | cut -d: -f5)
    sed -i "/^${u}:/d" "$DB_FILE"
    echo "$u:$new_pass:$expiry:$limit:$bw" >> "$DB_FILE"
    msg_ok "Password for '$u' changed to: $new_pass"
}

lock_user() {
    echo ""
    echo -e " ${CB}${YLW}--- Lock User Account ---${CR}"
    echo ""
    _select_user_interface "Select user to lock"
    local u=$SELECTED_USER
    [[ "$u" == "NO_USERS" || -z "$u" ]] && return
    if passwd -S "$u" 2>/dev/null | grep -q " L "; then
        msg_warn "User '$u' is already locked."; return
    fi
    usermod -L "$u" 2>/dev/null
    killall -u "$u" -9 2>/dev/null
    msg_ok "User '$u' has been locked and disconnected."
}

unlock_user() {
    echo ""
    echo -e " ${CB}${GRN}--- Unlock User Account ---${CR}"
    echo ""
    _select_user_interface "Select user to unlock"
    local u=$SELECTED_USER
    [[ "$u" == "NO_USERS" || -z "$u" ]] && return
    if ! passwd -S "$u" 2>/dev/null | grep -q " L "; then
        msg_warn "User '$u' is not locked."; return
    fi
    usermod -U "$u" 2>/dev/null
    msg_ok "User '$u' has been unlocked."
}

edit_user() {
    echo ""
    echo -e " ${CB}${CYN}--- Edit User Account ---${CR}"
    echo ""
    _select_user_interface "Select user to edit"
    local u=$SELECTED_USER
    [[ "$u" == "NO_USERS" || -z "$u" ]] && return
    local line pass expiry limit bw
    line=$(grep "^${u}:" "$DB_FILE")
    pass=$(echo "$line" | cut -d: -f2)
    expiry=$(echo "$line" | cut -d: -f3)
    limit=$(echo "$line" | cut -d: -f4)
    bw=$(echo "$line" | cut -d: -f5)
    echo -e " Current settings for ${YLW}${u}${CR}:"
    echo -e "   Password:   ${WHT}${pass}${CR}"
    echo -e "   Expires:    ${WHT}${expiry}${CR}"
    echo -e "   Conn Limit: ${WHT}${limit}${CR}"
    echo -e "   Bandwidth:  ${WHT}${bw:-0} GB${CR}"
    echo ""
    read -rp " New password [$pass]: " new_pass
    new_pass=${new_pass:-$pass}
    read -rp " New expiry date (YYYY-MM-DD) [$expiry]: " new_expiry
    new_expiry=${new_expiry:-$expiry}
    read -rp " New connection limit [$limit]: " new_limit
    new_limit=${new_limit:-$limit}
    read -rp " New bandwidth limit in GB (0=unlimited) [${bw:-0}]: " new_bw
    new_bw=${new_bw:-${bw:-0}}
    if [[ "$new_pass" != "$pass" ]]; then
        echo "$u:$new_pass" | chpasswd
    fi
    if [[ "$new_expiry" != "$expiry" ]]; then
        chage -E "$new_expiry" "$u"
    fi
    sed -i "/^${u}:/d" "$DB_FILE"
    echo "$u:$new_pass:$new_expiry:$new_limit:$new_bw" >> "$DB_FILE"
    msg_ok "User '$u' updated successfully."
    update_ssh_banners_config
}

cleanup_expired_users() {
    echo ""
    echo -e " ${CB}${RED}--- Cleanup Expired Users ---${CR}"
    echo ""
    if [[ ! -s "$DB_FILE" ]]; then
        msg_warn "No users in database."; return
    fi
    local now_ts expired_users=()
    now_ts=$(date +%s)
    while IFS=: read -r user pass expiry limit bw _extra; do
        [[ -z "$user" || "$user" == \#* ]] && continue
        if [[ "$expiry" != "Never" && -n "$expiry" ]]; then
            local exp_ts
            exp_ts=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
            if [[ $exp_ts -lt $now_ts && $exp_ts -ne 0 ]]; then
                expired_users+=("$user:$expiry")
            fi
        fi
    done < "$DB_FILE"
    if [[ ${#expired_users[@]} -eq 0 ]]; then
        msg_ok "No expired users found."; return
    fi
    echo -e " ${YLW}Found ${#expired_users[@]} expired user(s):${CR}"
    for entry in "${expired_users[@]}"; do
        local eu=$(echo "$entry" | cut -d: -f1)
        local ee=$(echo "$entry" | cut -d: -f2)
        echo -e "   ${RED}*${CR} ${eu} (expired: ${ee})"
    done
    echo ""
    read -rp " Delete all expired users? (y/n): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { msg_warn "Cancelled"; return; }
    local deleted=0
    for entry in "${expired_users[@]}"; do
        local eu=$(echo "$entry" | cut -d: -f1)
        killall -u "$eu" -9 2>/dev/null
        userdel -r "$eu" 2>/dev/null
        sed -i "/^${eu}:/d" "$DB_FILE"
        rm -f "$BANDWIDTH_DIR/${eu}.usage"
        rm -f "$BANNER_DIR/${eu}.txt"
        deleted=$((deleted + 1))
    done
    msg_ok "Deleted $deleted expired user(s)."
    update_ssh_banners_config
}

create_trial_account() {
    echo ""
    echo -e " ${CB}${CYN}--- Create Trial/Test Account ---${CR}"
    echo ""
    if ! command -v at &>/dev/null; then
        msg_info "Installing 'at' for scheduled auto-expiry..."
        apt-get update > /dev/null 2>&1 && apt-get install -y at >/dev/null 2>&1 || {
            msg_err "Failed to install 'at'."; return
        }
        systemctl enable atd &>/dev/null
        systemctl start atd &>/dev/null
    fi
    [[ ! $(systemctl is-active atd 2>/dev/null) == "active" ]] && systemctl start atd &>/dev/null
    echo -e " ${CYN}Select trial duration:${CR}"
    echo ""
    echo -e "   ${GRN}[1]${CR} 1 Hour"
    echo -e "   ${GRN}[2]${CR} 2 Hours"
    echo -e "   ${GRN}[3]${CR} 3 Hours"
    echo -e "   ${GRN}[4]${CR} 6 Hours"
    echo -e "   ${GRN}[5]${CR} 12 Hours"
    echo -e "   ${GRN}[6]${CR} 1 Day"
    echo -e "   ${GRN}[7]${CR} 3 Days"
    echo -e "   ${GRN}[8]${CR} Custom (enter hours)"
    echo -e "   ${RED}[0]${CR} Cancel"
    echo ""
    read -rp " Select duration: " dur_choice
    local duration_hours=0 duration_label=""
    case $dur_choice in
        1) duration_hours=1;  duration_label="1 Hour" ;;
        2) duration_hours=2;  duration_label="2 Hours" ;;
        3) duration_hours=3;  duration_label="3 Hours" ;;
        4) duration_hours=6;  duration_label="6 Hours" ;;
        5) duration_hours=12; duration_label="12 Hours" ;;
        6) duration_hours=24; duration_label="1 Day" ;;
        7) duration_hours=72; duration_label="3 Days" ;;
        8) read -rp " Enter custom duration in hours: " custom_hours
           if ! [[ "$custom_hours" =~ ^[0-9]+$ ]] || [[ "$custom_hours" -lt 1 ]]; then
               msg_err "Invalid number of hours."; return
           fi
           duration_hours=$custom_hours; duration_label="$custom_hours Hours" ;;
        0) return ;;
        *) msg_err "Invalid option."; return ;;
    esac
    local rand_suffix
    rand_suffix=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 5)
    local default_username="trial_${rand_suffix}"
    read -rp " Username [$default_username]: " username
    username=${username:-$default_username}
    if id "$username" &>/dev/null || grep -q "^$username:" "$DB_FILE"; then
        msg_err "User '$username' already exists."; return
    fi
    local password
    password=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 8)
    read -rp " Password [$password]: " custom_pass
    password=${custom_pass:-$password}
    read -rp " Connection limit [1]: " limit
    limit=${limit:-1}
    [[ ! "$limit" =~ ^[0-9]+$ ]] && { msg_err "Invalid number."; return; }
    read -rp " Bandwidth limit in GB (0 = unlimited) [0]: " bandwidth_gb
    bandwidth_gb=${bandwidth_gb:-0}
    local expire_date
    if [[ "$duration_hours" -ge 24 ]]; then
        local days=$((duration_hours / 24))
        expire_date=$(date -d "+$days days" +%Y-%m-%d)
    else
        expire_date=$(date -d "+1 day" +%Y-%m-%d)
    fi
    local expiry_timestamp
    expiry_timestamp=$(date -d "+${duration_hours} hours" '+%Y-%m-%d %H:%M:%S')
    useradd -m -s /usr/sbin/nologin "$username" 2>/dev/null
    usermod -aG xxjusers "$username" 2>/dev/null
    echo "$username:$password" | chpasswd
    chage -E "$expire_date" "$username"
    echo "$username:$password:$expire_date:$limit:$bandwidth_gb" >> "$DB_FILE"
    echo "$TRIAL_CLEANUP_SCRIPT $username" | at now + ${duration_hours} hours 2>/dev/null
    local bw_display="Unlimited"
    [[ "$bandwidth_gb" != "0" ]] && bw_display="${bandwidth_gb} GB"
    echo ""
    echo -e " ${GRN}Trial account created successfully!${CR}"
    echo -e " ${YLW}========================================${CR}"
    echo -e "   TRIAL ACCOUNT"
    echo -e " ${YLW}========================================${CR}"
    echo -e "   Username:          ${YLW}$username${CR}"
    echo -e "   Password:          ${YLW}$password${CR}"
    echo -e "   Duration:          ${CYN}$duration_label${CR}"
    echo -e "   Auto-expires at:   ${RED}$expiry_timestamp${CR}"
    echo -e "   Connection Limit:  ${YLW}$limit${CR}"
    echo -e "   Bandwidth Limit:   ${YLW}$bw_display${CR}"
    echo -e " ${YLW}========================================${CR}"
    echo ""
    read -rp " Generate client config for this trial user? (y/n): " gen_conf
    [[ "$gen_conf" =~ ^[Yy]$ ]] && generate_client_config "$username" "$password"
    update_ssh_banners_config
}

bulk_create_users() {
    echo ""
    echo -e " ${CB}${CYN}--- Bulk Create Users ---${CR}"
    echo ""
    read -rp " Username prefix (e.g., 'user'): " prefix
    [[ -z "$prefix" ]] && { msg_err "Prefix cannot be empty."; return; }
    read -rp " How many users to create? " count
    if ! [[ "$count" =~ ^[0-9]+$ ]] || [[ "$count" -lt 1 ]] || [[ "$count" -gt 100 ]]; then
        msg_err "Invalid count (1-100)."; return
    fi
    read -rp " Account duration (in days): " days
    [[ ! "$days" =~ ^[0-9]+$ ]] && { msg_err "Invalid number."; return; }
    read -rp " Connection limit per user [1]: " limit
    limit=${limit:-1}
    read -rp " Bandwidth limit in GB per user (0 = unlimited) [0]: " bandwidth_gb
    bandwidth_gb=${bandwidth_gb:-0}
    local expire_date
    expire_date=$(date -d "+$days days" +%Y-%m-%d)
    local bw_display="Unlimited"
    [[ "$bandwidth_gb" != "0" ]] && bw_display="${bandwidth_gb} GB"
    echo ""
    echo -e " ${BLU}Creating $count users with prefix '${prefix}'...${CR}"
    echo ""
    printf " ${CB}${WHT}%-20s | %-15s | %-12s${CR}\n" "USERNAME" "PASSWORD" "EXPIRES"
    echo -e " ${YLW}$(printf '%.0s-' {1..55})${CR}"
    local created=0
    for ((i=1; i<=count; i++)); do
        local username="${prefix}${i}"
        if id "$username" &>/dev/null || grep -q "^$username:" "$DB_FILE"; then
            echo -e " ${RED}  Skipping '$username' -- already exists${CR}"; continue
        fi
        local password
        password=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 8)
        useradd -m -s /usr/sbin/nologin "$username" 2>/dev/null
        usermod -aG xxjusers "$username" 2>/dev/null
        echo "$username:$password" | chpasswd
        chage -E "$expire_date" "$username"
        echo "$username:$password:$expire_date:$limit:$bandwidth_gb" >> "$DB_FILE"
        printf " ${GRN}%-20s${CR} | ${YLW}%-15s${CR} | ${CYN}%-12s${CR}\n" "$username" "$password" "$expire_date"
        created=$((created + 1))
    done
    echo -e " ${YLW}$(printf '%.0s-' {1..55})${CR}"
    echo ""
    msg_ok "Created $created users. Conn Limit: ${limit} | BW: ${bw_display}"
    update_ssh_banners_config
}

view_user_bandwidth() {
    _select_user_interface "--- View User Bandwidth ---"
    local u=$SELECTED_USER
    [[ "$u" == "NO_USERS" || -z "$u" ]] && return
    echo ""
    echo -e " ${CB}${CYN}--- Bandwidth Details: ${YLW}$u${CYN} ---${CR}"
    echo ""
    local line bandwidth_gb
    line=$(grep "^$u:" "$DB_FILE")
    bandwidth_gb=$(echo "$line" | cut -d: -f5)
    [[ -z "$bandwidth_gb" ]] && bandwidth_gb="0"
    local used_bytes=0
    [[ -f "$BANDWIDTH_DIR/${u}.usage" ]] && used_bytes=$(cat "$BANDWIDTH_DIR/${u}.usage" 2>/dev/null)
    [[ -z "$used_bytes" ]] && used_bytes=0
    local used_mb used_gb
    used_mb=$(awk "BEGIN {printf \"%.2f\", $used_bytes / 1048576}")
    used_gb=$(awk "BEGIN {printf \"%.3f\", $used_bytes / 1073741824}")
    echo -e "   Data Used:        ${WHT}${used_gb} GB${CR} (${used_mb} MB)"
    if [[ "$bandwidth_gb" == "0" ]]; then
        echo -e "   Bandwidth Limit:  ${GRN}Unlimited${CR}"
    else
        local quota_bytes percentage remaining_bytes remaining_gb
        quota_bytes=$(awk "BEGIN {printf \"%.0f\", $bandwidth_gb * 1073741824}")
        percentage=$(awk "BEGIN {printf \"%.1f\", ($used_bytes / $quota_bytes) * 100}")
        remaining_bytes=$((quota_bytes - used_bytes))
        [[ "$remaining_bytes" -lt 0 ]] && remaining_bytes=0
        remaining_gb=$(awk "BEGIN {printf \"%.3f\", $remaining_bytes / 1073741824}")
        echo -e "   Bandwidth Limit:  ${YLW}${bandwidth_gb} GB${CR}"
        echo -e "   Remaining:        ${WHT}${remaining_gb} GB${CR}"
        echo -e "   Usage:            ${WHT}${percentage}%${CR}"
        local bar_width=30 filled
        filled=$(awk "BEGIN {printf \"%.0f\", ($percentage / 100) * $bar_width}")
        [[ "$filled" -gt "$bar_width" ]] && filled=$bar_width
        local empty=$((bar_width - filled))
        local bar_color="$GRN"
        (( $(awk "BEGIN {print ($percentage > 80)}" ) )) && bar_color="$RED"
        (( $(awk "BEGIN {print ($percentage > 50)}" ) )) && bar_color="$YLW"
        printf "   Progress:         ${bar_color}["
        for ((j=0; j<filled; j++)); do printf "#"; done
        for ((j=0; j<empty; j++)); do printf "."; done
        printf "]${CR} ${percentage}%%\n"
        [[ "$used_bytes" -ge "$quota_bytes" ]] && echo -e "\n   ${RED}BANDWIDTH EXCEEDED -- ACCOUNT LOCKED${CR}"
    fi
}

backup_users() {
    echo ""
    echo -e " ${CB}${CYN}--- Backup User Database ---${CR}"
    echo ""
    mkdir -p "$BACKUP_DIR"
    local backup_name="xxjihad_backup_$(date +%Y%m%d_%H%M%S)"
    local backup_file="${BACKUP_DIR}/${backup_name}.tar.gz"
    local files_to_backup=()
    [[ -f "$DB_FILE" ]] && files_to_backup+=("$DB_FILE")
    [[ -d "$BANDWIDTH_DIR" ]] && files_to_backup+=("$BANDWIDTH_DIR")
    [[ -d "$BANNER_DIR" ]] && files_to_backup+=("$BANNER_DIR")
    if [[ ${#files_to_backup[@]} -eq 0 ]]; then
        msg_warn "Nothing to backup."; return
    fi
    tar -czf "$backup_file" "${files_to_backup[@]}" 2>/dev/null
    if [[ -f "$backup_file" ]]; then
        local size
        size=$(du -h "$backup_file" | cut -f1)
        msg_ok "Backup created: ${backup_file} (${size})"
    else
        msg_err "Failed to create backup."
    fi
}

restore_users() {
    echo ""
    echo -e " ${CB}${CYN}--- Restore User Database ---${CR}"
    echo ""
    mkdir -p "$BACKUP_DIR"
    local backups=()
    mapfile -t backups < <(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null)
    if [[ ${#backups[@]} -eq 0 ]]; then
        msg_warn "No backups found in $BACKUP_DIR"; return
    fi
    echo -e " ${CYN}Available backups:${CR}"
    for i in "${!backups[@]}"; do
        local bname bsize
        bname=$(basename "${backups[$i]}")
        bsize=$(du -h "${backups[$i]}" | cut -f1)
        printf "   ${GRN}[%2d]${CR} %s (%s)\n" "$((i+1))" "$bname" "$bsize"
    done
    echo -e "   ${RED}[ 0]${CR} Cancel"
    echo ""
    read -rp " Select backup: " choice
    [[ "$choice" == "0" ]] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "${#backups[@]}" ]]; then
        msg_err "Invalid selection."; return
    fi
    local selected="${backups[$((choice-1))]}"
    read -rp " This will overwrite current user data. Continue? (y/n): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { msg_warn "Cancelled"; return; }
    tar -xzf "$selected" -C / 2>/dev/null
    if [[ -f "$DB_FILE" ]]; then
        while IFS=: read -r user pass expiry limit bw _extra; do
            [[ -z "$user" || "$user" == \#* ]] && continue
            if ! id "$user" &>/dev/null; then
                useradd -m -s /usr/sbin/nologin "$user" 2>/dev/null
                usermod -aG xxjusers "$user" 2>/dev/null
                echo "$user:$pass" | chpasswd
                chage -E "$expiry" "$user"
            fi
        done < "$DB_FILE"
    fi
    msg_ok "Backup restored successfully."
    update_ssh_banners_config
}

generate_client_config() {
    local user=$1 pass=$2
    local host_ip
    host_ip=$(curl -s -4 icanhazip.com 2>/dev/null)
    local host_domain="$host_ip"
    if [[ -f "$DNS_INFO_FILE" ]]; then
        local managed_domain
        managed_domain=$(grep 'FULL_DOMAIN' "$DNS_INFO_FILE" | cut -d'"' -f2)
        [[ -n "$managed_domain" ]] && host_domain="$managed_domain"
    fi
    if [[ -f "$NGINX_CONFIG_FILE" ]]; then
        local nginx_domain
        nginx_domain=$(grep -oP 'server_name \K[^\s;]+' "$NGINX_CONFIG_FILE" | head -n 1)
        [[ "$nginx_domain" != "_" && -n "$nginx_domain" ]] && host_domain="$nginx_domain"
    fi
    echo ""
    echo -e " ${CB}${CYN}--- Client Connection Configuration ---${CR}"
    echo ""
    echo -e " ${YLW}========================================${CR}"
    echo -e "   User Details"
    echo -e "   Username: ${WHT}$user${CR}"
    echo -e "   Password: ${WHT}$pass${CR}"
    echo -e "   Host/IP : ${WHT}$host_domain${CR}"
    echo -e " ${YLW}========================================${CR}"
    echo -e "\n   SSH Direct:"
    echo -e "   Host: $host_domain"
    echo -e "   Port: 22"
    if systemctl is-active --quiet haproxy 2>/dev/null; then
        echo -e "\n   SSH + SSL (Edge Stack):"
        echo -e "   Host: $host_domain"
        echo -e "   Ports: 80, 443"
        echo -e "   SNI: $host_domain"
    fi
    if systemctl is-active --quiet nginx 2>/dev/null && [[ -f "$NGINX_PORTS_FILE" ]]; then
        source "$NGINX_PORTS_FILE"
        echo -e "\n   Internal Nginx:"
        echo -e "   HTTP Port: ${HTTP_PORTS:-8880}"
        echo -e "   TLS Port: ${TLS_PORTS:-8443}"
    fi
    if systemctl is-active --quiet falconproxy 2>/dev/null && [[ -f "$FALCONPROXY_CONFIG_FILE" ]]; then
        source "$FALCONPROXY_CONFIG_FILE"
        echo -e "\n   Falcon Proxy (WebSocket):"
        echo -e "   Host: $host_domain"
        echo -e "   Port(s): ${PORTS:-8080}"
    fi
    if [[ -f "$DNSTT_CONF" ]]; then
        local _tun _key
        _tun=$(grep '^TUNNEL_DOMAIN=' "$DNSTT_CONF" | cut -d'"' -f2)
        _key=$(grep '^PUBLIC_KEY=' "$DNSTT_CONF" | cut -d'"' -f2)
        if [[ -n "$_tun" ]]; then
            echo -e "\n   DNS Tunnel (DNSTT):"
            echo -e "   Tunnel Domain: $_tun"
            echo -e "   Public Key: $_key"
        fi
    fi
    echo ""
}

_select_user_interface() {
    local title="${1:-Select User}"
    SELECTED_USER=""
    if [[ ! -s "$DB_FILE" ]]; then
        msg_warn "No users found in database."
        SELECTED_USER="NO_USERS"
        return
    fi
    echo ""
    echo -e " ${CB}${CYN}--- $title ---${CR}"
    echo ""
    local users=()
    local i=1
    while IFS=: read -r user _rest; do
        [[ -z "$user" || "$user" == \#* ]] && continue
        users+=("$user")
        local online
        online=$(pgrep -c -u "$user" sshd 2>/dev/null || echo 0)
        local status_icon="${GRY}o${CR}"
        [[ "$online" -gt 0 ]] && status_icon="${GRN}*${CR}"
        local lock_icon=""
        passwd -S "$user" 2>/dev/null | grep -q " L " && lock_icon=" ${RED}[LOCKED]${CR}"
        printf "   ${CYN}[%2d]${CR} %-20s [${status_icon}] %s online%s\n" "$i" "$user" "$online" "$lock_icon"
        i=$((i + 1))
    done < "$DB_FILE"
    if [[ ${#users[@]} -eq 0 ]]; then
        msg_warn "No users found."
        SELECTED_USER="NO_USERS"
        return
    fi
    echo -e "   ${GRY}[ 0]${CR} Cancel"
    echo ""
    read -rp " Enter number: " choice
    [[ "$choice" == "0" ]] && { SELECTED_USER=""; return; }
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#users[@]}" ]]; then
        SELECTED_USER="${users[$((choice-1))]}"
    else
        msg_err "Invalid selection."
        SELECTED_USER=""
    fi
}

install_limiter() {
    cat > "$LIMITER_SCRIPT" << 'LIMEOF'
#!/bin/bash
DB_FILE="/etc/xxjihad/db/users.db"
BW_DIR="/etc/xxjihad/bandwidth"
PID_DIR="$BW_DIR/pidtrack"
BANNER_DIR="/etc/xxjihad/banners"
mkdir -p "$BW_DIR" "$PID_DIR" "$BANNER_DIR"
while true; do
    [[ ! -f "$DB_FILE" ]] && { sleep 30; continue; }
    current_ts=$(date +%s)
    while IFS=: read -r user pass expiry limit bandwidth_gb _extra; do
        [[ -z "$user" || "$user" == \#* ]] && continue
        if [[ "$expiry" != "Never" && "$expiry" != "" ]]; then
            expiry_ts=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
            if [[ $expiry_ts -lt $current_ts && $expiry_ts -ne 0 ]]; then
                if ! passwd -S "$user" | grep -q " L "; then
                    usermod -L "$user" &>/dev/null
                    killall -u "$user" -9 &>/dev/null
                fi
                continue
            fi
        fi
        online_count=$(pgrep -c -u "$user" sshd 2>/dev/null || echo 0)
        [[ ! "$limit" =~ ^[0-9]+$ ]] && limit=1
        if [[ "$online_count" -gt "$limit" ]]; then
            if ! passwd -S "$user" | grep -q " L "; then
                usermod -L "$user" &>/dev/null
                killall -u "$user" -9 &>/dev/null
                (sleep 120; usermod -U "$user" &>/dev/null) &
            else
                killall -u "$user" -9 &>/dev/null
            fi
        fi
        if [[ -f "/etc/xxjihad/banners_enabled" ]]; then
            days_left="N/A"
            if [[ "$expiry" != "Never" && -n "$expiry" ]]; then
                expiry_ts=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
                if [[ $expiry_ts -gt 0 ]]; then
                    diff_secs=$((expiry_ts - current_ts))
                    if [[ $diff_secs -le 0 ]]; then days_left="EXPIRED"
                    else
                        d_l=$(( diff_secs / 86400 ))
                        h_l=$(( (diff_secs % 86400) / 3600 ))
                        [[ $d_l -eq 0 ]] && days_left="${h_l}h left" || days_left="${d_l}d ${h_l}h"
                    fi
                fi
            fi
            bw_info="Unlimited"
            if [[ "$bandwidth_gb" != "0" && -n "$bandwidth_gb" ]]; then
                usagefile="$BW_DIR/${user}.usage"
                accum_disp=0
                [[ -f "$usagefile" ]] && accum_disp=$(cat "$usagefile" 2>/dev/null)
                used_gb=$(awk "BEGIN {printf \"%.2f\", $accum_disp / 1073741824}")
                remain_gb=$(awk "BEGIN {r=$bandwidth_gb - $used_gb; if(r<0) r=0; printf \"%.2f\", r}")
                bw_info="${used_gb}/${bandwidth_gb} GB used | ${remain_gb} GB left"
            fi
            {
                echo -e "<br><font color=\"cyan\"><b>      XxXjihad - ACCOUNT STATUS      </b></font><br><br>"
                echo -e "<font color=\"white\">Username   : $user</font><br>"
                echo -e "<font color=\"white\">Expiration : $expiry ($days_left)</font><br>"
                echo -e "<font color=\"white\">Bandwidth  : $bw_info</font><br>"
                echo -e "<font color=\"white\">Sessions   : $online_count/$limit</font><br><br>"
            } > "$BANNER_DIR/${user}.txt"
        fi
        [[ -z "$bandwidth_gb" || "$bandwidth_gb" == "0" ]] && continue
        user_uid=$(id -u "$user" 2>/dev/null)
        [[ -z "$user_uid" ]] && continue
        pids=$(pgrep -u "$user" sshd 2>/dev/null | tr '\n' ' ')
        for p in /proc/[0-9]*/loginuid; do
            [[ ! -f "$p" ]] && continue
            luid=$(cat "$p" 2>/dev/null)
            [[ -z "$luid" || "$luid" == "4294967295" ]] && continue
            [[ "$luid" != "$user_uid" ]] && continue
            pid_dir=$(dirname "$p")
            pid_num=$(basename "$pid_dir")
            cname=$(cat "$pid_dir/comm" 2>/dev/null)
            [[ "$cname" != "sshd" ]] && continue
            ppid_val=$(awk '/^PPid:/{print $2}' "$pid_dir/status" 2>/dev/null)
            [[ "$ppid_val" == "1" ]] && continue
            pids="$pids $pid_num"
        done
        pids=$(echo "$pids" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
        usagefile="$BW_DIR/${user}.usage"
        accumulated=0
        if [[ -f "$usagefile" ]]; then
            accumulated=$(cat "$usagefile" 2>/dev/null)
            [[ ! "$accumulated" =~ ^[0-9]+$ ]] && accumulated=0
        fi
        if [[ -z "$pids" ]]; then
            rm -f "$PID_DIR/${user}__"*.last 2>/dev/null
            continue
        fi
        delta_total=0
        for pid in $pids; do
            [[ -z "$pid" ]] && continue
            io_file="/proc/$pid/io"
            if [[ -r "$io_file" ]]; then
                rchar=$(awk '/^rchar:/{print $2}' "$io_file" 2>/dev/null)
                wchar=$(awk '/^wchar:/{print $2}' "$io_file" 2>/dev/null)
                [[ -z "$rchar" ]] && rchar=0
                [[ -z "$wchar" ]] && wchar=0
                cur=$((rchar + wchar))
            else
                cur=0
            fi
            pidfile="$PID_DIR/${user}__${pid}.last"
            if [[ -f "$pidfile" ]]; then
                prev=$(cat "$pidfile" 2>/dev/null)
                [[ ! "$prev" =~ ^[0-9]+$ ]] && prev=0
                [[ "$cur" -ge "$prev" ]] && d=$((cur - prev)) || d=$cur
                delta_total=$((delta_total + d))
            fi
            echo "$cur" > "$pidfile"
        done
        for f in "$PID_DIR/${user}__"*.last; do
            [[ ! -f "$f" ]] && continue
            fpid=$(basename "$f" .last)
            fpid=${fpid#${user}__}
            [[ ! -d "/proc/$fpid" ]] && rm -f "$f"
        done
        new_total=$((accumulated + delta_total))
        echo "$new_total" > "$usagefile"
        quota_bytes=$(awk "BEGIN {printf \"%.0f\", $bandwidth_gb * 1073741824}")
        if [[ "$new_total" -ge "$quota_bytes" ]]; then
            if ! passwd -S "$user" 2>/dev/null | grep -q " L "; then
                usermod -L "$user" &>/dev/null
                killall -u "$user" -9 &>/dev/null
            fi
        fi
    done < "$DB_FILE"
    sleep 15
done
LIMEOF
    chmod +x "$LIMITER_SCRIPT"
    sed -i 's/\r$//' "$LIMITER_SCRIPT" 2>/dev/null
    cat > "$LIMITER_SERVICE" <<SVCEOF
[Unit]
Description=XxXjihad Active User Limiter
After=network.target

[Service]
Type=simple
ExecStart=$LIMITER_SCRIPT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
    sed -i 's/\r$//' "$LIMITER_SERVICE" 2>/dev/null
    pkill -f "xxjihad-limiter" 2>/dev/null
    systemctl daemon-reload
    systemctl enable xxjihad-limiter &>/dev/null
    systemctl start xxjihad-limiter --no-block &>/dev/null
}

install_cleaner() {
    cat > "$TRIAL_CLEANUP_SCRIPT" << 'CLEANEOF'
#!/bin/bash
DB_FILE="/etc/xxjihad/db/users.db"
BW_DIR="/etc/xxjihad/bandwidth"
BANNER_DIR="/etc/xxjihad/banners"
user="$1"
[[ -z "$user" ]] && exit 1
killall -u "$user" -9 2>/dev/null
userdel -r "$user" 2>/dev/null
sed -i "/^${user}:/d" "$DB_FILE"
rm -f "$BW_DIR/${user}.usage"
rm -f "$BANNER_DIR/${user}.txt"
CLEANEOF
    chmod +x "$TRIAL_CLEANUP_SCRIPT"
    sed -i 's/\r$//' "$TRIAL_CLEANUP_SCRIPT" 2>/dev/null
}

update_ssh_banners_config() {
    mkdir -p "$(dirname "$LOGIN_INFO_SCRIPT")"
    cat > "$LOGIN_INFO_SCRIPT" << 'BANEOF'
#!/bin/bash
BANNER_DIR="/etc/xxjihad/banners"
user=$(whoami)
if [[ -f "$BANNER_DIR/${user}.txt" ]]; then
    # Print the banner and then clear the buffer to avoid issues with some clients
    cat "$BANNER_DIR/${user}.txt"
fi
BANEOF
    chmod +x "$LOGIN_INFO_SCRIPT"
    
    # FIX: Remove ForceCommand as it breaks Shell access. 
    # Use /etc/profile.d/ or .bashrc for user-specific banners instead.
    mkdir -p /etc/ssh/sshd_config.d/
    # We will use a more standard approach that doesn't hijack the session
    rm -f "$SSHD_XX_CONFIG"
    
    # Add to global profile to show on login for xxjusers group
    cat > /etc/profile.d/xxjihad-banner.sh << 'PROFOF'
if id -nG | grep -q "xxjusers"; then
    /etc/xxjihad/banners/login_info.sh
fi
PROFOF
    chmod +x /etc/profile.d/xxjihad-banner.sh

    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null
}

user_menu() {
    while true; do
        echo ""
        echo -e " ${CB}${CYN}=========================================${CR}"
        echo -e " ${CB}${CYN}         User Management Menu            ${CR}"
        echo -e " ${CB}${CYN}=========================================${CR}"
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
                _select_user_interface "Select user for config"
                local u=$SELECTED_USER
                [[ "$u" == "NO_USERS" || -z "$u" ]] && continue
                local line pass
                line=$(grep "^${u}:" "$DB_FILE")
                pass=$(echo "$line" | cut -d: -f2)
                generate_client_config "$u" "$pass"
                ;;
            10) lock_user ;;
            11) unlock_user ;;
            12) edit_user ;;
            13) cleanup_expired_users ;;
            14) backup_users ;;
            15) restore_users ;;
            0) return ;;
            *) msg_err "Invalid option" ;;
        esac
        echo ""
        echo -e " ${GRY}Press Enter to continue...${CR}"
        read -r
    done
}
