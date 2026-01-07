#!/bin/bash

# ==========================================
# ⚡ PRE-FLIGHT
# ==========================================
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

if [ ! -t 0 ]; then
    exec < /dev/tty
fi

echo -e "${BLUE}=== Archinstall Auto-Wrapper (Minimal) ===${NC}"

# Ensure FZF
if ! command -v fzf &> /dev/null; then
    pacman -Sy --noconfirm fzf &> /dev/null
fi

# Ensure latest archinstall (The ISO version is almost always broken)
pip install --upgrade archinstall &> /dev/null

# ==========================================
# ⚡ GATHER DATA
# ==========================================

read -p "Username: " USER_NAME
read -s -p "User Password: " USER_PASS
echo ""
read -s -p "Root Password: " ROOT_PASS
echo ""

GPU_LABEL=$(echo -e "AMD\nIntel\nNVIDIA\nVMware/VirtualBox" | fzf --prompt="GPU > " --height=10%)
case "$GPU_LABEL" in
    "AMD") GPU_DRIVER="amd" ;;
    "Intel") GPU_DRIVER="intel" ;;
    "NVIDIA") GPU_DRIVER="nvidia" ;;
    *) GPU_DRIVER="all-open" ;;
esac

# Disk Selection
RAW_DISK_LIST=$(lsblk -pdno NAME,SIZE,MODEL | grep -v "loop" | grep -v "sr")
SELECTED_LINE=$(echo "$RAW_DISK_LIST" | fzf --prompt="Select Disk > " --height=15%)
TARGET_DISK=$(echo "$SELECTED_LINE" | awk '{print $1}')

if [[ -z "$TARGET_DISK" ]]; then exit 1; fi

echo -e "${RED}WIPING $TARGET_DISK! Type 'yes': ${NC}"
read -p "> " CONFIRM
[[ "$CONFIRM" != "yes" ]] && exit 1

# ==========================================
# ⚡ THE FIX: "GUIDED" DISK LAYOUT SCHEMA
# ==========================================
echo -e "\n${BLUE}Generating verified JSON config...${NC}"

python3 -c "
import json

config = {
    'version': '2.8.1',
    'archinstall-language': 'English',
    'keyboard-layout': 'us',
    'mirror-region': {'United States': 10, 'Germany': 10},
    'sys-language': 'en_US.UTF-8',
    'sys-encoding': 'UTF-8',
    'profile': {'path': 'minimal'},
    'harddrives': ['$TARGET_DISK'],
    # Using the 'disk_layouts' (plural) list which is the new standard
    'disk_layouts': [
        {
            'device': '$TARGET_DISK',
            'wipe': True,
            'filesystem_type': 'btrfs',
            'mount_options': ['compress=zstd'],
            'partitions': [
                {
                    'boot': True,
                    'filesystem': {'name': 'fat32'},
                    'mountpoint': '/boot/efi',
                    'size': '512MiB',
                    'start': '1MiB',
                    'type': 'primary'
                },
                {
                    'filesystem': {'name': 'btrfs'},
                    'mountpoint': '/',
                    'size': '100%',
                    'start': '513MiB',
                    'type': 'primary'
                }
            ]
        }
    ],
    'gfx_driver': '$GPU_DRIVER',
    'audio': None, # Handled by your other script
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
echo -e "\n${GREEN}Starting Install...${NC}"

# Running with --debug helps see exactly why a disk config might fail
archinstall --config auto_config.json --silent

EXIT_CODE=$?
rm -f auto_config.json

if [[ $EXIT_CODE -eq 0 ]]; then
    echo -e "\n${GREEN}=== SUCCESS ===${NC}"
else
    echo -e "\n${RED}Failed. Check /var/log/archinstall/install.log${NC}"
fi
