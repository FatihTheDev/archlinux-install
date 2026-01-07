#!/bin/bash

# ==========================================
# PRE-FLIGHT
# ==========================================
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

if [ ! -t 0 ]; then
    exec < /dev/tty
fi

echo -e "${BLUE}=== Archinstall Auto-Wrapper (Advanced Btrfs) ===${NC}"

# Ensure fzf
if ! command -v fzf &> /dev/null; then
    pacman -Sy --noconfirm fzf &> /dev/null
fi

# Always upgrade archinstall (ISO version is outdated)
pip install --upgrade archinstall &> /dev/null

# ==========================================
# GATHER DATA
# ==========================================

read -p "Username: " USER_NAME
read -s -p "User Password: " USER_PASS
echo ""
read -s -p "Root Password: " ROOT_PASS
echo ""

GPU_LABEL=$(echo -e "AMD\nIntel\nNVIDIA\nVMware/VirtualBox" | \
    fzf --prompt="GPU > " --height=10%)

case "$GPU_LABEL" in
    "AMD") GPU_DRIVER="amd" ;;
    "Intel") GPU_DRIVER="intel" ;;
    "NVIDIA") GPU_DRIVER="nvidia" ;;
    *) GPU_DRIVER="all-open" ;;
esac

# ==========================================
# DISK SELECTION
# ==========================================

RAW_DISK_LIST=$(lsblk -pdno NAME,SIZE,MODEL | grep -v "loop" | grep -v "sr")
SELECTED_LINE=$(echo "$RAW_DISK_LIST" | fzf --prompt="Select Disk > " --height=15%)
TARGET_DISK=$(echo "$SELECTED_LINE" | awk '{print $1}')

[[ -z "$TARGET_DISK" ]] && exit 1

DISK_MODE=$(printf "Use entire disk\nUse remaining free space\nManual partitioning" | \
    fzf --prompt="Disk layout > " --height=10%)

[[ -z "$DISK_MODE" ]] && exit 1

if [[ "$DISK_MODE" == "Use entire disk" ]]; then
    echo -e "${RED}WIPING $TARGET_DISK! Type 'yes': ${NC}"
    read -p "> " CONFIRM
    [[ "$CONFIRM" != "yes" ]] && exit 1
    PARTITION_SCHEME="entire_disk"

elif [[ "$DISK_MODE" == "Use remaining free space" ]]; then
    PARTITION_SCHEME="free_space"

else
    echo -e "${BLUE}Launching cfdisk on ${TARGET_DISK}...${NC}"
    cfdisk "$TARGET_DISK"
    PARTITION_SCHEME="manual"
fi

# ==========================================
# GENERATE CONFIG JSON (FIXED SCHEMA)
# ==========================================

echo -e "${BLUE}Generating auto_config.json...${NC}"

python3 - <<EOF
import json, subprocess

disk = "$TARGET_DISK"
mode = "$PARTITION_SCHEME"

config = {
    "version": "2.9.0",
    "archinstall-language": "English",
    "keyboard-layout": "us",
    "mirror-region": {"United States": 10, "Germany": 10},
    "sys-language": "en_US.UTF-8",
    "sys-encoding": "UTF-8",
    "profile": {"path": "minimal"},
    "harddrives": [disk],
    "kernels": ["linux"],
    "packages": ["vim", "git", "networkmanager"],
    "network_config": {"type": "nm"},
    "timezone": "UTC",
    "ntp": True,
    "gfx_driver": "$GPU_DRIVER",
    "!users": [
        {"username": "$USER_NAME", "password": "$USER_PASS", "sudo": True}
    ]
}

root_pass = "$ROOT_PASS"
if root_pass:
    config["!root_password"] = root_pass

# ================================================================
# REQUIRED FIX:
# disk_config MUST be structured as:
#   "disk_config": { "config": [ ... ] }
# ================================================================
disk_wrapper = { "config": [] }

# ==========================================
# MODE 1: ENTIRE DISK (WIPE + BTRFS SUBVOLS)
# ==========================================
if mode == "entire_disk":
    disk_wrapper["config"].append(
        {
            "device": disk,
            "wipe": True,
            "partitions": [
                {
                    "boot": True,
                    "filesystem": {"name": "fat32"},
                    "mountpoint": "/boot/efi",
                    "size": "512MiB",
                    "start": "1MiB",
                    "type": "primary"
                },
                {
                    "filesystem": {"name": "btrfs"},
                    "mountpoint": "/",
                    "size": "100%",
                    "type": "primary",
                    "subvolumes": {
                        "@": "/",
                        "@home": "/home",
                        "@snapshots": "/.snapshots",
                        "@cache": "/var/cache",
                        "@log": "/var/log"
                    },
                    "mount_options": ["compress=zstd"]
                }
            ]
        }
    )

# ==========================================
# MODE 2: USE FREE SPACE
# ==========================================
elif mode == "free_space":
    disk_wrapper["config"].append(
        {
            "device": disk,
            "use_existing": True,
            "filesystem_type": "btrfs",
            "mount_options": ["compress=zstd"]
        }
    )

# ==========================================
# MODE 3: MANUAL PARTITIONING (CFDISK)
# ==========================================
else:
    parts_raw = subprocess.check_output(
        ["lsblk", "-lnpo", "NAME,TYPE", disk]
    ).decode().splitlines()

    partitions = [p.split()[0] for p in parts_raw if p.endswith("part")]

    disk_wrapper["config"].append(
        {
            "device": disk,
            "use_existing": True,
            "partitions": [
                {"device": part, "mountpoint": None}
                for part in partitions
            ]
        }
    )

# Attach fixed structure
config["disk_config"] = disk_wrapper

with open("auto_config.json", "w") as f:
    json.dump(config, f, indent=4)

EOF

# ==========================================
# EXECUTE ARCHINSTALL
# ==========================================

echo -e "${GREEN}Starting Archinstall...${NC}"

archinstall --config auto_config.json --silent --debug

EXIT_CODE=$?
rm -f auto_config.json

if [[ $EXIT_CODE -eq 0 ]]; then
    echo -e "${GREEN}=== SUCCESS ===${NC}"
else
    echo -e "${RED}Failed. Check /var/log/archinstall/install.log${NC}"
fi
