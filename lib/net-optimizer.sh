#!/bin/bash
###############################################################################
#  XxXjihad :: NETWORK OPTIMIZER v5.0                                         #
#  BBR, sysctl tuning, TCP optimization, Traffic Monitor, Torrent Block,      #
#  Auto-Reboot, SSH Banner, Certbot SSL                                       #
###############################################################################

CR=$'\033[0m'; CB=$'\033[1m'
RED=$'\033[38;5;196m'; GRN=$'\033[38;5;46m'; YLW=$'\033[38;5;226m'
BLU=$'\033[38;5;39m'; CYN=$'\033[38;5;51m'; WHT=$'\033[38;5;255m'
GRY=$'\033[38;5;245m'; ORG=$'\033[38;5;208m'; PRP=$'\033[38;5;135m'

msg_ok()   { echo -e " ${GRN}[OK]${CR} $*"; }
msg_err()  { echo -e " ${RED}[ERROR]${CR} $*"; }
msg_warn() { echo -e " ${YLW}[WARN]${CR} $*"; }
msg_info() { echo -e " ${BLU}[INFO]${CR} $*"; }

# ========================= BBR SETUP =========================================
setup_bbr() {
    msg_info "Checking BBR availability..."
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        msg_ok "BBR is already active"
        return 0
    fi
    if ! modprobe tcp_bbr 2>/dev/null; then
        msg_warn "BBR kernel module not available on this system"
        return 1
    fi
    # Remove old BBR entries
    sed -i '/XxXjihad BBR/d; /net.core.default_qdisc=fq/d; /net.ipv4.tcp_congestion_control=bbr/d' /etc/sysctl.conf 2>/dev/null
    cat >> /etc/sysctl.conf <<'BBREOF'
# XxXjihad BBR Optimization
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
BBREOF
    sysctl -p >/dev/null 2>&1
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        msg_ok "BBR enabled successfully"
    else
        msg_warn "BBR could not be enabled"
    fi
}

# ========================= SYSCTL TUNING =====================================
apply_sysctl_optimizations() {
    msg_info "Applying network optimizations (Safe Mode)..."

    # Ensure SSH is allowed
    fw_allow 22 tcp 2>/dev/null

    local SYSCTL_FILE="/etc/sysctl.d/99-xxjihad.conf"
    cat > "$SYSCTL_FILE" <<'SYSEOF'
# XxXjihad Network Optimizations v5.0
# TCP Buffer Sizes
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.ipv4.tcp_rmem=4096 1048576 16777216
net.ipv4.tcp_wmem=4096 1048576 16777216

# TCP Performance
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_max_tw_buckets=2000000
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0

# Connection Tracking
net.netfilter.nf_conntrack_max=1048576
net.nf_conntrack_max=1048576

# Core Network
net.core.somaxconn=65535
net.core.netdev_max_backlog=65536
net.core.optmem_max=25165824

# IP Forwarding (for VPN)
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# UDP Optimization (for DNSTT)
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# File Descriptors
fs.file-max=1048576
fs.nr_open=1048576

# VM Tuning
vm.swappiness=10
vm.dirty_ratio=30
vm.dirty_background_ratio=5
SYSEOF

    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || msg_warn "Some sysctl settings could not be applied"

    # Increase file descriptor limits
    if ! grep -q "xxjihad" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf <<'LIMEOF'
# XxXjihad File Descriptor Limits
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMEOF
    fi

    msg_ok "Network optimizations applied"
}

# ========================= NETWORK STATUS ====================================
show_network_status() {
    echo ""
    echo -e " ${CB}${CYN}--- Network Status ---${CR}"
    echo ""

    # BBR Status
    local bbr_status="${RED}Disabled${CR}"
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr && bbr_status="${GRN}Active${CR}"
    echo -e "   BBR:              $bbr_status"

    # IP Forward
    local fwd_status="${RED}Disabled${CR}"
    [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] && fwd_status="${GRN}Enabled${CR}"
    echo -e "   IP Forward:       $fwd_status"

    # Public IP
    local ip4
    ip4=$(curl -s -4 --max-time 5 icanhazip.com 2>/dev/null)
    echo -e "   Public IPv4:      ${YLW}${ip4:-N/A}${CR}"

    local ip6
    ip6=$(curl -s -6 --max-time 5 icanhazip.com 2>/dev/null)
    [[ -n "$ip6" ]] && echo -e "   Public IPv6:      ${YLW}${ip6}${CR}"

    # Connections
    local total_conn
    total_conn=$(ss -s 2>/dev/null | grep "TCP:" | awk '{print $2}')
    echo -e "   TCP Connections:  ${WHT}${total_conn:-N/A}${CR}"

    # Memory
    local mem_info
    mem_info=$(free -h 2>/dev/null | awk '/^Mem:/{printf "%s / %s", $3, $2}')
    echo -e "   Memory:           ${WHT}${mem_info:-N/A}${CR}"

    # Disk
    local disk_info
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')
    echo -e "   Disk:             ${WHT}${disk_info:-N/A}${CR}"

    # CPU Load
    local load_info
    load_info=$(cat /proc/loadavg 2>/dev/null | awk '{printf "%s %s %s", $1, $2, $3}')
    echo -e "   Load Average:     ${WHT}${load_info:-N/A}${CR}"

    # Uptime
    local uptime_info
    uptime_info=$(uptime -p 2>/dev/null)
    echo -e "   Uptime:           ${WHT}${uptime_info:-N/A}${CR}"
    echo ""
}

# ========================= TRAFFIC MONITOR ===================================
traffic_monitor_menu() {
    echo ""
    echo -e " ${CB}${CYN}--- Traffic Monitor ---${CR}"
    echo ""

    if ! command -v vnstat &>/dev/null; then
        msg_info "Installing vnstat..."
        apt-get install -y -qq vnstat >/dev/null 2>&1
        systemctl enable vnstat &>/dev/null
        systemctl start vnstat &>/dev/null
        sleep 2
    fi

    local iface
    iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    [[ -z "$iface" ]] && iface="eth0"

    echo -e " ${CYN}Interface: ${WHT}${iface}${CR}"
    echo ""
    echo -e "   ${CYN}[1]${CR} Live Traffic (5s)"
    echo -e "   ${CYN}[2]${CR} Hourly Stats"
    echo -e "   ${CYN}[3]${CR} Daily Stats"
    echo -e "   ${CYN}[4]${CR} Monthly Stats"
    echo -e "   ${CYN}[5]${CR} Top 10 Connections"
    echo -e "   ${GRY}[0]${CR} Back"
    echo ""
    read -rp " Choice: " ch
    case "$ch" in
        1)
            echo -e " ${YLW}Live traffic (press Ctrl+C to stop):${CR}"
            vnstat -l -i "$iface" 2>/dev/null || {
                msg_warn "vnstat not ready yet, showing ss stats..."
                ss -s
            }
            ;;
        2) vnstat -h -i "$iface" 2>/dev/null || msg_warn "No hourly data yet" ;;
        3) vnstat -d -i "$iface" 2>/dev/null || msg_warn "No daily data yet" ;;
        4) vnstat -m -i "$iface" 2>/dev/null || msg_warn "No monthly data yet" ;;
        5)
            echo -e " ${CYN}Top 10 connections by state:${CR}"
            ss -tan 2>/dev/null | awk 'NR>1{print $1}' | sort | uniq -c | sort -rn | head -10
            echo ""
            echo -e " ${CYN}Top 10 connected IPs:${CR}"
            ss -tn 2>/dev/null | awk 'NR>1{split($5,a,":");print a[1]}' | sort | uniq -c | sort -rn | head -10
            ;;
        0) return ;;
        *) msg_err "Invalid option" ;;
    esac
}

# ========================= TORRENT BLOCKING ==================================
torrent_block_menu() {
    echo ""
    echo -e " ${CB}${CYN}--- Torrent / P2P Blocking ---${CR}"
    echo ""

    local torrent_active=false
    iptables -L INPUT -n 2>/dev/null | grep -q "xxjihad-torrent" && torrent_active=true

    if $torrent_active; then
        echo -e "   Status: ${GRN}Active (Blocking)${CR}"
    else
        echo -e "   Status: ${RED}Inactive${CR}"
    fi
    echo ""
    echo -e "   ${CYN}[1]${CR} Enable Torrent Blocking"
    echo -e "   ${CYN}[2]${CR} Disable Torrent Blocking"
    echo -e "   ${CYN}[3]${CR} View Blocked Packets Count"
    echo -e "   ${GRY}[0]${CR} Back"
    echo ""
    read -rp " Choice: " ch
    case "$ch" in
        1) _apply_torrent_rules ;;
        2) _flush_torrent_rules ;;
        3)
            echo ""
            echo -e " ${CYN}Blocked packet counts:${CR}"
            iptables -L -n -v 2>/dev/null | grep "xxjihad-torrent" || msg_warn "No torrent rules active"
            ;;
        0) return ;;
        *) msg_err "Invalid option" ;;
    esac
}

_apply_torrent_rules() {
    msg_info "Applying torrent blocking rules..."

    # Block common BitTorrent ports
    local bt_ports="6881:6999"
    iptables -A INPUT -p tcp --dport $bt_ports -m comment --comment "xxjihad-torrent" -j DROP 2>/dev/null
    iptables -A INPUT -p udp --dport $bt_ports -m comment --comment "xxjihad-torrent" -j DROP 2>/dev/null
    iptables -A OUTPUT -p tcp --dport $bt_ports -m comment --comment "xxjihad-torrent" -j DROP 2>/dev/null
    iptables -A OUTPUT -p udp --dport $bt_ports -m comment --comment "xxjihad-torrent" -j DROP 2>/dev/null

    # Block BitTorrent protocol strings
    iptables -A FORWARD -m string --string "BitTorrent" --algo bm -j DROP -m comment --comment "xxjihad-torrent" 2>/dev/null
    iptables -A FORWARD -m string --string "BitTorrent protocol" --algo bm -j DROP -m comment --comment "xxjihad-torrent" 2>/dev/null
    iptables -A FORWARD -m string --string "peer_id=" --algo bm -j DROP -m comment --comment "xxjihad-torrent" 2>/dev/null
    iptables -A FORWARD -m string --string ".torrent" --algo bm -j DROP -m comment --comment "xxjihad-torrent" 2>/dev/null
    iptables -A FORWARD -m string --string "announce.php?passkey=" --algo bm -j DROP -m comment --comment "xxjihad-torrent" 2>/dev/null
    iptables -A FORWARD -m string --string "torrent" --algo bm -j DROP -m comment --comment "xxjihad-torrent" 2>/dev/null
    iptables -A FORWARD -m string --string "announce" --algo bm -j DROP -m comment --comment "xxjihad-torrent" 2>/dev/null
    iptables -A OUTPUT -m string --string "BitTorrent" --algo bm -j DROP -m comment --comment "xxjihad-torrent" 2>/dev/null
    iptables -A OUTPUT -m string --string "BitTorrent protocol" --algo bm -j DROP -m comment --comment "xxjihad-torrent" 2>/dev/null

    # Save rules
    if command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi

    msg_ok "Torrent blocking rules applied"
}

_flush_torrent_rules() {
    msg_info "Removing torrent blocking rules..."
    # Remove all rules with xxjihad-torrent comment
    while iptables -L INPUT -n --line-numbers 2>/dev/null | grep -q "xxjihad-torrent"; do
        local line
        line=$(iptables -L INPUT -n --line-numbers 2>/dev/null | grep "xxjihad-torrent" | head -1 | awk '{print $1}')
        iptables -D INPUT "$line" 2>/dev/null
    done
    while iptables -L OUTPUT -n --line-numbers 2>/dev/null | grep -q "xxjihad-torrent"; do
        local line
        line=$(iptables -L OUTPUT -n --line-numbers 2>/dev/null | grep "xxjihad-torrent" | head -1 | awk '{print $1}')
        iptables -D OUTPUT "$line" 2>/dev/null
    done
    while iptables -L FORWARD -n --line-numbers 2>/dev/null | grep -q "xxjihad-torrent"; do
        local line
        line=$(iptables -L FORWARD -n --line-numbers 2>/dev/null | grep "xxjihad-torrent" | head -1 | awk '{print $1}')
        iptables -D FORWARD "$line" 2>/dev/null
    done

    if command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi

    msg_ok "Torrent blocking rules removed"
}

# ========================= AUTO-REBOOT =======================================
auto_reboot_menu() {
    echo ""
    echo -e " ${CB}${CYN}--- Auto-Reboot Management ---${CR}"
    echo ""

    local current_cron
    current_cron=$(crontab -l 2>/dev/null | grep "systemctl reboot")
    if [[ -n "$current_cron" ]]; then
        echo -e "   Current schedule: ${GRN}${current_cron}${CR}"
    else
        echo -e "   Current schedule: ${GRY}None${CR}"
    fi
    echo ""
    echo -e "   ${CYN}[1]${CR} Set daily auto-reboot"
    echo -e "   ${CYN}[2]${CR} Set weekly auto-reboot"
    echo -e "   ${CYN}[3]${CR} Set custom schedule"
    echo -e "   ${CYN}[4]${CR} Remove auto-reboot"
    echo -e "   ${GRY}[0]${CR} Back"
    echo ""
    read -rp " Choice: " ch
    case "$ch" in
        1)
            read -rp " Reboot time (HH:MM, 24h format) [04:00]: " reboot_time
            reboot_time=${reboot_time:-04:00}
            local hour minute
            hour=$(echo "$reboot_time" | cut -d: -f1)
            minute=$(echo "$reboot_time" | cut -d: -f2)
            (crontab -l 2>/dev/null | grep -v "systemctl reboot"; echo "$minute $hour * * * /bin/systemctl reboot # xxjihad-auto-reboot") | crontab -
            msg_ok "Daily auto-reboot set at ${reboot_time}"
            ;;
        2)
            read -rp " Day of week (0=Sun, 1=Mon, ..., 6=Sat) [0]: " dow
            dow=${dow:-0}
            read -rp " Reboot time (HH:MM) [04:00]: " reboot_time
            reboot_time=${reboot_time:-04:00}
            local hour minute
            hour=$(echo "$reboot_time" | cut -d: -f1)
            minute=$(echo "$reboot_time" | cut -d: -f2)
            (crontab -l 2>/dev/null | grep -v "systemctl reboot"; echo "$minute $hour * * $dow /bin/systemctl reboot # xxjihad-auto-reboot") | crontab -
            msg_ok "Weekly auto-reboot set"
            ;;
        3)
            echo -e " ${YLW}Enter cron expression (min hour dom mon dow):${CR}"
            read -rp " Cron: " cron_expr
            if [[ -n "$cron_expr" ]]; then
                (crontab -l 2>/dev/null | grep -v "systemctl reboot"; echo "$cron_expr /bin/systemctl reboot # xxjihad-auto-reboot") | crontab -
                msg_ok "Custom auto-reboot schedule set"
            else
                msg_err "Empty cron expression"
            fi
            ;;
        4)
            (crontab -l 2>/dev/null | grep -v "systemctl reboot") | crontab - 2>/dev/null
            msg_ok "Auto-reboot removed"
            ;;
        0) return ;;
        *) msg_err "Invalid option" ;;
    esac
}

# ========================= SSH BANNER MANAGEMENT =============================
ssh_banner_menu() {
    while true; do
        echo ""
        echo -e " ${CB}${CYN}--- SSH Banner Management ---${CR}"
        echo ""
        local banner_status="${RED}Disabled${CR}"
        [[ -f "/etc/xxjihad/banners_enabled" ]] && banner_status="${GRN}Enabled${CR}"
        echo -e "   Status: $banner_status"
        echo ""
        echo -e "   ${CYN}[1]${CR} Enable SSH Banners"
        echo -e "   ${CYN}[2]${CR} Disable SSH Banners"
        echo -e "   ${CYN}[3]${CR} Preview Banner (for a user)"
        echo -e "   ${GRY}[0]${CR} Back"
        echo ""
        read -rp " Choice: " ch
        case "$ch" in
            1)
                touch /etc/xxjihad/banners_enabled
                msg_ok "SSH Banners enabled. Users will see account info on login."
                ;;
            2)
                rm -f /etc/xxjihad/banners_enabled
                msg_ok "SSH Banners disabled."
                ;;
            3)
                local DB_FILE="/etc/xxjihad/db/users.db"
                if [[ ! -s "$DB_FILE" ]]; then
                    msg_warn "No users found."; continue
                fi
                local first_user
                first_user=$(head -1 "$DB_FILE" | cut -d: -f1)
                local banner_file="/etc/xxjihad/banners/${first_user}.txt"
                if [[ -f "$banner_file" ]]; then
                    echo ""
                    echo -e " ${YLW}Banner preview for: $first_user${CR}"
                    cat "$banner_file"
                else
                    msg_warn "No banner generated yet for '$first_user'. Wait for limiter cycle."
                fi
                ;;
            0) return ;;
            *) msg_err "Invalid option" ;;
        esac
        echo ""
        echo -e " ${GRY}Press Enter to continue...${CR}"
        read -r
    done
}

# ========================= CERTBOT SSL ======================================
request_certbot_ssl() {
    echo ""
    echo -e " ${CB}${CYN}--- Certbot SSL Certificate ---${CR}"
    echo ""

    if ! command -v certbot &>/dev/null; then
        msg_info "Installing certbot..."
        apt-get install -y -qq certbot >/dev/null 2>&1
    fi

    read -rp " Enter your domain: " domain
    [[ -z "$domain" ]] && { msg_err "Domain cannot be empty."; return; }

    read -rp " Enter your email (for Let's Encrypt): " email
    [[ -z "$email" ]] && { msg_err "Email cannot be empty."; return; }

    msg_info "Requesting SSL certificate for $domain..."

    # Stop services that might use port 80
    local nginx_was_running=false haproxy_was_running=false
    if systemctl is-active --quiet nginx 2>/dev/null; then
        nginx_was_running=true
        systemctl stop nginx 2>/dev/null
    fi
    if systemctl is-active --quiet haproxy 2>/dev/null; then
        haproxy_was_running=true
        systemctl stop haproxy 2>/dev/null
    fi

    certbot certonly --standalone -d "$domain" --email "$email" --agree-tos --non-interactive 2>&1

    if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
        msg_ok "SSL certificate obtained for $domain"
        echo -e "   Certificate: /etc/letsencrypt/live/${domain}/fullchain.pem"
        echo -e "   Private Key: /etc/letsencrypt/live/${domain}/privkey.pem"

        # Store domain info
        mkdir -p /etc/xxjihad/ssl
        echo "SSL_DOMAIN=\"$domain\"" > /etc/xxjihad/ssl/certbot.conf
        echo "SSL_CERT=\"/etc/letsencrypt/live/${domain}/fullchain.pem\"" >> /etc/xxjihad/ssl/certbot.conf
        echo "SSL_KEY=\"/etc/letsencrypt/live/${domain}/privkey.pem\"" >> /etc/xxjihad/ssl/certbot.conf

        # Setup auto-renewal
        (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload haproxy nginx' 2>/dev/null") | crontab -
        msg_ok "Auto-renewal cron job added"
    else
        msg_err "Failed to obtain SSL certificate"
    fi

    # Restart services
    $nginx_was_running && systemctl start nginx 2>/dev/null
    $haproxy_was_running && systemctl start haproxy 2>/dev/null
}

# ========================= NETWORK MENU ======================================
network_menu() {
    while true; do
        echo ""
        echo -e " ${CB}${CYN}=========================================${CR}"
        echo -e " ${CB}${CYN}         Network Optimization Menu       ${CR}"
        echo -e " ${CB}${CYN}=========================================${CR}"
        echo ""
        echo -e "   ${CYN}[1]${CR} Show Network Status"
        echo -e "   ${CYN}[2]${CR} Enable BBR"
        echo -e "   ${CYN}[3]${CR} Apply Sysctl Optimizations"
        echo -e "   ${CYN}[4]${CR} Apply All Optimizations"
        echo -e "   ${GRY}[0]${CR} Back"
        echo ""
        read -rp " Choice: " ch
        case "$ch" in
            1) show_network_status ;;
            2) setup_bbr ;;
            3) apply_sysctl_optimizations ;;
            4) setup_bbr; apply_sysctl_optimizations ;;
            0) return ;;
            *) msg_err "Invalid option" ;;
        esac
        echo ""
        echo -e " ${GRY}Press Enter to continue...${CR}"
        read -r
    done
}
