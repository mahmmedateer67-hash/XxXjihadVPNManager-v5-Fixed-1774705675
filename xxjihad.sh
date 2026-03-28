#!/bin/bash
###############################################################################
#                                                                             #
#   XxXjihad :: 1-Click Infrastructure Installer v5.0.0 (Enhanced)            #
#                                                                             #
#   Usage:  bash <(curl -fsSL https://thefirewoods.org/xxjihad.sh)            #
#   Menu:   xxjihad                                                           #
#                                                                             #
#   Telegram: https://t.me/XxXjihad                                           #
#                                                                             #
###############################################################################

REPO_BASE="https://raw.githubusercontent.com/jamal7720077-debug/XxXjihadVPNManager/main"
XXJIHAD_DIR="/etc/xxjihad"
XXJIHAD_BIN="/usr/local/bin"
XXJIHAD_LIB="/usr/local/lib/xxjihad"
XXJIHAD_LOG="/var/log/xxjihad"
XXJIHAD_RUN="/var/run/xxjihad"
VERSION="5.0.0"

# ========================= COLORS (Cyan/White Theme) =========================
CR=$'\033[0m'; CB=$'\033[1m'; CD=$'\033[2m'; CU=$'\033[4m'
RED=$'\033[38;5;196m'; GRN=$'\033[38;5;46m'; YLW=$'\033[38;5;226m'
BLU=$'\033[38;5;39m'; PRP=$'\033[38;5;135m'; CYN=$'\033[38;5;51m'
WHT=$'\033[38;5;255m'; GRY=$'\033[38;5;245m'; ORG=$'\033[38;5;208m'

# ========================= PRE-CHECKS =======================================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] This script must be run as root (sudo).${CR}"
    exit 1
fi

# ========================= SMART INSTALLER: DETECT OLD VERSION ===============
detect_and_remove_old() {
    local old_found=false

    if [[ -f "${XXJIHAD_BIN}/xxjihad" ]]; then
        local old_ver
        old_ver=$(grep -oP 'v[0-9]+\.[0-9]+' "${XXJIHAD_BIN}/xxjihad" 2>/dev/null | head -1)
        if [[ -n "$old_ver" ]]; then
            echo -e "${YLW}[SMART]${CR} Detected existing installation: ${old_ver}"
            old_found=true
        fi
    fi

    if [[ -d "$XXJIHAD_LIB" ]] && ls "$XXJIHAD_LIB"/*.sh &>/dev/null; then
        old_found=true
    fi

    if $old_found; then
        echo -e "${YLW}[SMART]${CR} Removing old version files (preserving user data)..."
        systemctl stop xxjihad-limiter 2>/dev/null
        rm -f "$XXJIHAD_LIB"/*.sh 2>/dev/null
        rm -f "${XXJIHAD_BIN}/xxjihad" 2>/dev/null
        echo -e "${GRN}[OK]${CR} Old version cleaned (user data preserved)"
    fi
}

clear
echo ""
echo -e "${CYN}  +====================================================+${CR}"
echo -e "${CYN}  |          ${CB}${WHT}XxXjihad${CR}${CYN} Infrastructure Installer        |${CR}"
echo -e "${CYN}  |              Version ${VERSION}                        |${CR}"
echo -e "${CYN}  |      Telegram: ${WHT}https://t.me/XxXjihad${CR}${CYN}               |${CR}"
echo -e "${CYN}  +====================================================+${CR}"
echo ""

# ========================= STEP 1: SMART CLEANUP ============================
echo -e "${BLU}[1/7]${CR} Smart detection & cleanup..."
detect_and_remove_old
echo -e "${GRN}[OK]${CR} Environment ready"

# ========================= STEP 2: DEPENDENCIES (Smart UI) ===================
echo -e "${BLU}[2/7]${CR} Installing system dependencies..."
DEPS=(curl wget jq bc openssl net-tools dnsutils at iptables vnstat unzip zip)
for dep in "${DEPS[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
        echo -en "  ${GRY}Installing ${dep}...${CR}"
        apt-get install -y -qq "$dep" >/dev/null 2>&1
        echo -e "\r  ${GRN}[INSTALLED]${CR} ${dep}   "
    else
        echo -e "  ${GRN}[OK]${CR} ${dep} is already installed"
    fi
done
echo -e "${GRN}[OK]${CR} All dependencies ready"

# ========================= STEP 3: DIRECTORIES ==============================
echo -e "${BLU}[3/7]${CR} Creating directory structure..."
mkdir -p "$XXJIHAD_DIR"/{dnstt/keys,dns,network,ssl,db,backups,bandwidth,banners} \
         "$XXJIHAD_LIB" "$XXJIHAD_LOG" "$XXJIHAD_RUN" 2>/dev/null

if [[ ! -f "$XXJIHAD_DIR/db/users.db" ]]; then
    touch "$XXJIHAD_DIR/db/users.db"
fi
chmod 600 "$XXJIHAD_DIR/db/users.db" 2>/dev/null
echo -e "${GRN}[OK]${CR} Directories created"

# ========================= STEP 4: DOWNLOAD MODULES (200 OK Check) ===========
echo -e "${BLU}[4/7]${CR} Downloading XxXjihad modules..."

MODULES=(dnstt-core.sh net-optimizer.sh user-manager.sh menu-system.sh ssl-tunnel.sh protocols.sh)
download_ok=true

for mod in "${MODULES[@]}"; do
    local_path="${XXJIHAD_LIB}/${mod}"
    remote_url="${REPO_BASE}/lib/${mod}"

    echo -en "  ${GRY}Fetching ${mod}...${CR}"
    if wget -q --timeout=30 -O "$local_path" "$remote_url" 2>/dev/null && [[ -s "$local_path" ]]; then
        echo -e "\r  ${GRN}[200 OK]${CR} ${mod} downloaded successfully"
    else
        echo -e "\r  ${RED}[404/ERR]${CR} Failed to download: ${mod}"
        download_ok=false
        break
    fi
done

if ! $download_ok; then
    echo -e "${RED}[ERROR] Module download failed. Installation aborted.${CR}"
    exit 1
fi

chmod +x "$XXJIHAD_LIB"/*.sh 2>/dev/null
sed -i 's/\r$//' "$XXJIHAD_LIB"/*.sh 2>/dev/null
echo -e "${GRN}[OK]${CR} All modules downloaded"

# ========================= STEP 5: CREATE MENU COMMAND =======================
echo -e "${BLU}[5/7]${CR} Creating 'xxjihad' command..."

cat > "${XXJIHAD_BIN}/xxjihad" <<'XXJCMD'
#!/bin/bash
# XxXjihad Menu Launcher v5.0.0
XXJIHAD_LIB="/usr/local/lib/xxjihad"
XXJIHAD_DIR="/etc/xxjihad"

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run as root: sudo xxjihad"
    exit 1
fi

# Source all modules in correct order
source "$XXJIHAD_LIB/dnstt-core.sh"
source "$XXJIHAD_LIB/net-optimizer.sh"
source "$XXJIHAD_LIB/user-manager.sh"
source "$XXJIHAD_LIB/ssl-tunnel.sh"
source "$XXJIHAD_LIB/protocols.sh"
source "$XXJIHAD_LIB/menu-system.sh"

# Initialize directories
init_dirs

# Handle arguments
case "${1:-}" in
    --status) xxjihad_status ;;
    --info) show_dnstt_info ;;
    --help|-h)
        echo "Usage: xxjihad [option]"
        echo "  (no args)  Open management menu"
        echo "  --status   Show service status"
        echo "  --info     Show DNSTT connection info"
        echo "  --help     Show this help"
        ;;
    *) main_menu ;;
esac
XXJCMD
chmod +x "${XXJIHAD_BIN}/xxjihad"
echo -e "${GRN}[OK]${CR} Command 'xxjihad' installed"

# ========================= STEP 6: NETWORK OPTIMIZATION =====================
echo -e "${BLU}[6/7]${CR} Applying network optimizations..."
source "$XXJIHAD_LIB/dnstt-core.sh"
source "$XXJIHAD_LIB/net-optimizer.sh"
setup_bbr 2>/dev/null
apply_sysctl_optimizations 2>/dev/null
echo -e "${GRN}[OK]${CR} Network optimized (BBR + sysctl tuning)"

# ========================= STEP 7: BACKGROUND SERVICES ======================
echo -e "${BLU}[7/7]${CR} Setting up background services..."
source "$XXJIHAD_LIB/user-manager.sh"
source "$XXJIHAD_LIB/menu-system.sh"
install_limiter 2>/dev/null
install_cleaner 2>/dev/null
echo -e "${GRN}[OK]${CR} Limiter & Cleaner services active"

# ========================= DONE =============================================
echo ""
echo -e "${CYN}  +====================================================+${CR}"
echo -e "${CYN}  |     ${CB}${WHT}XxXjihad v${VERSION}${CR}${CYN} installed successfully!       |${CR}"
echo -e "${CYN}  +====================================================+${CR}"
echo -e "${CYN}  |${CR}                                                      ${CYN}|${CR}"
echo -e "${CYN}  |${CR}  Type ${YLW}xxjihad${CR} to open the management menu.        ${CYN}|${CR}"
echo -e "${CYN}  |${CR}                                                      ${CYN}|${CR}"
echo -e "${CYN}  +====================================================+${CR}"
echo ""
