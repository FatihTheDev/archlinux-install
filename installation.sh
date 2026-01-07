#!/bin/bash

# ==========================================
# ⚡ PRE-FLIGHT CHECKS & DEPENDENCIES
# ==========================================

# Define Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# 1. Fix Input Stream (Crucial for pipes!)
if [ ! -t 0 ]; then
    exec < /dev/tty
fi

echo -e "${BLUE}=== Archinstall Auto-Wrapper (Native Linux Edition) ===${NC}"

# 2. Install FZF if missing
if ! command -v fzf &> /dev/null; then
    echo -e "${GREEN}--> Installing fzf...${NC}"
    pacman -Sy --noconfirm fzf &> /dev/null
fi

# 3. Update Archinstall
echo -e "${GREEN}--> Updating archinstall...${NC}"
pip install --upgrade archinstall &> /dev/null

# ==========================================
# ⚡ INTERACTIVE SETUP (FZF)
# ==========================================

# --- Credentials ---
echo -e "\n${BLUE}--- User Configuration ---${NC}"
read -p "Enter Username: " USER_NAME
while [[ -z "$USER_NAME" ]]; do
    read -p "Username cannot be empty: " USER_NAME
done

read -s -p "Enter User Password: " USER_PASS
echo ""
read -s -p "Enter Root Password (leave empty to disable): " ROOT_PASS
echo ""

# --- GPU Selection ---
echo -e "\n${BLUE}--- Hardware Setup ---${NC}"
GPU_LABEL=$(echo -e "AMD (Open Source)\nIntel (Open Source)\nNVIDIA (Proprietary)\nVMware/VirtualBox (Open)" | fzf --prompt="Select GPU Driver > " --height=20% --layout=reverse)

case "$GPU_LABEL" in
    *"AMD"*)    GPU_DRIVER="amd" ;;
    *"Intel"*)  GPU_DRIVER="intel" ;;
    *"NVIDIA"*) GPU_DRIVER="nvidia" ;;
    *)          GPU_DRIVER="all-open" ;;
esac
echo -e "${GREEN}Selected GPU: $GPU_DRIVER${NC}"

# --- Desktop Environment ---
echo -e "\n${BLUE}--- Software Setup ---${NC}"
DE_LABEL=$(echo -e "KDE Plasma\nGnome\nHyprland\nMinimal (CLI only)" | fzf --prompt="Select Desktop > " --height=20% --layout=reverse)

case "$DE_LABEL" in
    *"KDE"*)      PROFILE="desktop"; DE="kde" ;;
    *"Gnome"*)    PROFILE="desktop"; DE="gnome" ;;
    *"Hyprland"*) PROFILE="desktop"; DE="hyprland" ;;
    *)            PROFILE="minimal"; DE="" ;;
esac
echo -e "${GREEN}Selected Profile: $PROFILE ($DE)${NC}"

# --- Disk Selection (NATIVE LINUX TOOLS) ---
echo -e "\n${BLUE}--- Disk Selection ---${NC}"

# lsblk -d: List block devices (no partitions)
# -n: No header
# -o: Output columns
# grep -v "loop": Remove loopback devices (live ISO junk)
# grep -v "sr": Remove CD-ROMs
RAW_DISK_LIST=$(lsblk -dno NAME,SIZE,MODEL,TYPE | grep "disk" | grep -v "loop" | grep -v "sr")

if [[ -z "$RAW_DISK_LIST" ]]; then
    echo -e "${RED}No suitable disks found! (Is the virtual disk attached?)${NC}"
    lsblk # Print full tree for debugging
    exit 1
fi

# Show the menu
SELECTED_LINE=$(echo "$RAW_DISK_LIST" | fzf --prompt="Select Target Disk > " --height=20% --layout=reverse)

if [[ -z "$SELECTED_LINE" ]]; then
    echo -e "${RED}No disk selected. Exiting.${NC}"
    exit 1
fi

# Extract just the name (e.g., "sda" or "nvme0n1") from the first column
DISK_NAME=$(echo "$SELECTED_LINE" | awk '{print $1}')
TARGET_DISK="/dev/$DISK_NAME"

echo -e "${RED}WARNING: THIS WILL WIPE $TARGET_DISK${NC}"
read -p "Type 'yes' to confirm: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then exit 1; fi

# ==========================================
# ⚡ GENERATE CONFIG & INSTALL
# ==========================================

echo -e "\n${BLUE}Generating configuration...${NC}"

# We still use Python here just to write the JSON safely (avoiding syntax errors)
python3 -c "
import json

# Base structure
config = {
    'version': '2.8.0',
    'archinstall-language': 'English',
    'keyboard-layout': 'us',
    'mirror-region': {'United States': 10, 'Germany': 10, 'United Kingdom': 10},
    'sys-language': 'en_US.UTF-8',
    'sys-encoding': 'UTF-8',
    'profile': {
        'path': '$PROFILE',
        'details': ['$DE'] if '$DE' else []
    },
    'dry-run': False,
    'harddrives': ['$TARGET_DISK'],
    'disk_layout': {
        'config_type': 'default_layout',
        'filesystem_type': 'btrfs'
    },
    'gfx_driver': '$GPU_DRIVER',
    'audio': 'pipewire',
    'kernels': ['linux'],
    'packages': [
        'vim', 'git', 'wget', 'neofetch', 'firefox', 'networkmanager'
    ],
    'network_config': {
        'type': 'nm'
    },
    'timezone': 'UTC',
    'ntp': True
}

# User Creds
creds = {
    '!users': [
        {
            'username': '$USER_NAME',
            'password': '$USER_PASS',
            'sudo': True
        }
    ]
}

if '$ROOT_PASS':
    creds['!root_password'] = '$ROOT_PASS'

config.update(creds)

with open('auto_config.json', 'w') as f:
    json.dump(config, f, indent=4)
"

echo -e "\n${GREEN}Starting Automated Install...${NC}"
echo "Log file: /var/log/archinstall/install.log"

# Run it
archinstall --config auto_config.json --silent

EXIT_CODE=$?

# Cleanup
rm -f auto_config.json

if [[ $EXIT_CODE -eq 0 ]]; then
    echo -e "\n${GREEN}=== INSTALLATION COMPLETE ===${NC}"
    echo "You can now reboot."
else
    echo -e "\n${RED}Installation Failed!${NC}"
    echo "Check the logs above."
fi
