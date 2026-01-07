#!/bin/bash

# ==========================================
# ⚡ PRE-FLIGHT CHECKS
# ==========================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Fix input stream for pipes
if [ ! -t 0 ]; then
    exec < /dev/tty
fi

echo -e "${BLUE}=== Archinstall Auto-Wrapper (Fixed Disk Logic) ===${NC}"

# Install FZF if missing
if ! command -v fzf &> /dev/null; then
    echo -e "${GREEN}--> Installing fzf...${NC}"
    pacman -Sy --noconfirm fzf &> /dev/null
fi

# Update Archinstall to latest
echo -e "${GREEN}--> Updating archinstall...${NC}"
pip install --upgrade archinstall &> /dev/null

# ==========================================
# ⚡ INTERACTIVE SETUP
# ==========================================

# --- Credentials ---
read -p "Enter Username: " USER_NAME
read -s -p "Enter User Password: " USER_PASS
echo ""
read -s -p "Enter Root Password: " ROOT_PASS
echo ""

# --- Menus ---
GPU_LABEL=$(echo -e "AMD (Open Source)\nIntel (Open Source)\nNVIDIA (Proprietary)\nVMware/VirtualBox" | fzf --prompt="Select GPU > " --height=15% --layout=reverse)
case "$GPU_LABEL" in
    *"AMD"*)    GPU_DRIVER="amd" ;;
    *"Intel"*)  GPU_DRIVER="intel" ;;
    *"NVIDIA"*) GPU_DRIVER="nvidia" ;;
    *)          GPU_DRIVER="all-open" ;;
esac

DE_LABEL=$(echo -e "KDE Plasma\nGnome\nHyprland\nMinimal" | fzf --prompt="Select Desktop > " --height=15% --layout=reverse)
case "$DE_LABEL" in
    *"KDE"*)      PROFILE="desktop"; DE="kde" ;;
    *"Gnome"*)    PROFILE="desktop"; DE="gnome" ;;
    *"Hyprland"*) PROFILE="desktop"; DE="hyprland" ;;
    *)            PROFILE="minimal"; DE="" ;;
esac

# --- Disk Selection (Reliable lsblk) ---
echo -e "\n${BLUE}--- Disk Selection ---${NC}"
# -p gives full path (/dev/sda), -d skips partitions, -n no header
RAW_DISK_LIST=$(lsblk -pdno NAME,SIZE,MODEL | grep -v "loop" | grep -v "sr")

SELECTED_LINE=$(echo "$RAW_DISK_LIST" | fzf --prompt="Select Target Disk > " --height=15% --layout=reverse)
TARGET_DISK=$(echo "$SELECTED_LINE" | awk '{print $1}')

if [[ -z "$TARGET_DISK" ]]; then
    echo -e "${RED}No disk selected. Exiting.${NC}"
    exit 1
fi

echo -e "${RED}WARNING: THIS WILL WIPE $TARGET_DISK${NC}"
read -p "Type 'yes' to confirm: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then exit 1; fi

# ==========================================
# ⚡ GENERATE CONFIG (The "Correct" Schema)
# ==========================================

echo -e "\n${BLUE}Generating configuration...${NC}"

# We specify the full layout structure here to avoid the "No disk config" error
python3 -c "
import json

config = {
    'version': '2.8.1',
    'archinstall-language': 'English',
    'keyboard-layout': 'us',
    'mirror-region': {'United States': 10, 'Germany': 10},
    'sys-language': 'en_US.UTF-8',
    'sys-encoding': 'UTF-8',
    'profile': {
        'path': '$PROFILE',
        'details': ['$DE'] if '$DE' else []
    },
    'harddrives': ['$TARGET_DISK'],
    'disk_layout': {
        'device': '$TARGET_DISK',
        'wipe': True,
        'partitions': [
            {
                'type': 'primary',
                'start': '1MiB',
                'size': '512MiB',
                'boot': True,
                'mountpoint': '/boot/efi',
                'filesystem': {'name': 'fat32'}
            },
            {
                'type': 'primary',
                'start': '513MiB',
                'size': '100%',
                'mountpoint': '/',
                'filesystem': {'name': 'btrfs'}
            }
        ]
    },
    'gfx_driver': '$GPU_DRIVER',
    'audio': 'pipewire',
    'kernels': ['linux'],
    'packages': ['vim', 'git', 'networkmanager'],
    'network_config': {'type': 'nm'},
    'timezone': 'UTC',
    'ntp': True,
    '!users': [
        {'username': '$USER_NAME', 'password': '$USER_PASS', 'sudo': True}
    ]
}

if '$ROOT_PASS':
    config['!root_password'] = '$ROOT_PASS'

with open('auto_config.json', 'w') as f:
    json.dump(config, f, indent=4)
"

# ==========================================
# ⚡ EXECUTION
# ==========================================

echo -e "\n${GREEN}Starting Automated Install...${NC}"

# Archinstall needs the config file. We run it in silent mode.
archinstall --config auto_config.json --silent

EXIT_CODE=$?
rm -f auto_config.json

if [[ $EXIT_CODE -eq 0 ]]; then
    echo -e "\n${GREEN}=== INSTALLATION COMPLETE ===${NC}"
else
    echo -e "\n${RED}Installation Failed. Usually this is due to mirror timeouts.${NC}"
fi
