#!/bin/bash
###############################################################################
#                                                                             #
#   XxXjihad :: 1-Click Smart Infrastructure Installer v5.1.0                 #
#   Enhanced deSEC.io API Integration & 200 OK Verified Binaries              #
#                                                                             #
#   Usage:  bash <(curl -fsSL https://thefirewoods.org/xxjihad.sh)            #
#   Menu:   xxjihad                                                           #
#                                                                             #
#   Telegram: https://t.me/XxXjihad                                           #
#                                                                             #
###############################################################################

# REPO BASE - Use verified repository for direct 200 OK access
REPO_BASE="https://raw.githubusercontent.com/jamal7720077-debug/XxXjihadVPNManager/main"
XXJIHAD_DIR="/etc/xxjihad"
XXJIHAD_BIN="/usr/local/bin"
XXJIHAD_LIB="/usr/local/lib/xxjihad"
XXJIHAD_LOG="/var/log/xxjihad"
VERSION="5.1.0"

# ========================= COLORS ===========================================
CR=$'\033[0m'; CB=$'\033[1m'; RED=$'\033[38;5;196m'; GRN=$'\033[38;5;46m'
YLW=$'\033[38;5;226m'; BLU=$'\033[38;5;39m'; CYN=$'\033[38;5;51m'; WHT=$'\033[38;5;255m'

# ========================= PRE-CHECKS =======================================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] This script must be run as root (sudo).${CR}"
    exit 1
fi

clear
echo ""
echo -e "${CYN}  +====================================================+${CR}"
echo -e "${CYN}  |          ${CB}${WHT}XxXjihad${CR}${CYN} Smart Infrastructure Installer  |${CR}"
echo -e "${CYN}  |              Version ${VERSION}                        |${CR}"
echo -e "${CYN}  |      Telegram: ${WHT}https://t.me/XxXjihad${CR}${CYN}               |${CR}"
echo -e "${CYN}  +====================================================+${CR}"
echo ""

# ========================= STEP 1: DEPENDENCIES (Smart UI) ===================
echo -e "${BLU}[1/5]${CR} Installing system dependencies..."
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

# ========================= STEP 2: DIRECTORIES ==============================
echo -e "${BLU}[2/5]${CR} Creating directory structure..."
mkdir -p "$XXJIHAD_DIR"/{dnstt/keys,dns,network,ssl,db,backups,bandwidth,banners} \
         "$XXJIHAD_LIB" "$XXJIHAD_LOG" 2>/dev/null
[[ ! -f "$XXJIHAD_DIR/db/users.db" ]] && touch "$XXJIHAD_DIR/db/users.db"
chmod 600 "$XXJIHAD_DIR/db/users.db" 2>/dev/null
echo -e "${GRN}[OK]${CR} Directories created"

# ========================= STEP 3: DOWNLOAD MODULES (200 OK Check) ===========
echo -e "${BLU}[3/5]${CR} Downloading XxXjihad modules..."
MODULES=(dnstt-core.sh net-optimizer.sh user-manager.sh menu-system.sh ssl-tunnel.sh protocols.sh)
for mod in "${MODULES[@]}"; do
    local_path="${XXJIHAD_LIB}/${mod}"
    remote_url="${REPO_BASE}/lib/${mod}"
    echo -en "  ${GRY}Fetching ${mod}...${CR}"
    if wget -q --timeout=30 -O "$local_path" "$remote_url" 2>/dev/null && [[ -s "$local_path" ]]; then
        echo -e "\r  ${GRN}[200 OK]${CR} ${mod} downloaded successfully"
    else
        echo -e "\r  ${RED}[ERROR]${CR} Failed to download: ${mod}"
        exit 1
    fi
done
chmod +x "$XXJIHAD_LIB"/*.sh 2>/dev/null
echo -e "${GRN}[OK]${CR} All modules downloaded"

# ========================= STEP 4: CREATE MENU COMMAND =======================
echo -e "${BLU}[4/5]${CR} Creating 'xxjihad' command..."
cat > "${XXJIHAD_BIN}/xxjihad" <<'XXJCMD'
#!/bin/bash
XXJIHAD_LIB="/usr/local/lib/xxjihad"
source "$XXJIHAD_LIB/dnstt-core.sh"
source "$XXJIHAD_LIB/net-optimizer.sh"
source "$XXJIHAD_LIB/user-manager.sh"
source "$XXJIHAD_LIB/ssl-tunnel.sh"
source "$XXJIHAD_LIB/protocols.sh"
source "$XXJIHAD_LIB/menu-system.sh"
init_dirs
main_menu
XXJCMD
chmod +x "${XXJIHAD_BIN}/xxjihad"
echo -e "${GRN}[OK]${CR} Command 'xxjihad' installed"

# ========================= STEP 5: OPTIMIZATIONS ============================
echo -e "${BLU}[5/5]${CR} Applying network optimizations..."
source "$XXJIHAD_LIB/net-optimizer.sh"
setup_bbr 2>/dev/null
apply_sysctl_optimizations 2>/dev/null
echo -e "${GRN}[OK]${CR} Network optimized"

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
