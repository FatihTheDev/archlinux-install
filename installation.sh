#!/bin/bash

# Telva Linux Installation Script with ncurses TUI
# This script provides a user-friendly installation interface similar to Debian installer
#
# Usage:
#   Direct execution: sudo bash install.sh
#   Piped execution:  sudo wget -qO- https://script-url | bash
#   Download first:   wget -qO- https://script-url > install.sh && sudo bash install.sh
#
# Note: This script requires an interactive terminal for the ncurses TUI interface.
# When piping, ensure you're running in a terminal (not via SSH without -t flag).

# Use set -euo but handle piped execution gracefully
set -eu
# Only enable pipefail if stdin is a terminal (not a pipe)
# This allows the script to work when piped: wget -qO- URL | bash
if [[ -t 0 ]]; then
    set -o pipefail
fi

# Check for TTY (required for dialog)
check_tty() {
    # Dialog needs stdout and stderr to be terminals (stdin can be piped)
    # When piping: stdin is pipe, but stdout/stderr are still terminals
    if [[ ! -t 1 ]] || [[ ! -t 2 ]]; then
        echo "ERROR: This script requires stdout and stderr to be connected to a terminal." >&2
        echo "Dialog (ncurses) needs a terminal to display the interface." >&2
        echo "" >&2
        echo "If piping, ensure you're running in a terminal:" >&2
        echo "  sudo wget -qO- URL | bash" >&2
        echo "" >&2
        echo "Or download first:" >&2
        echo "  wget -qO- URL > install.sh && sudo bash install.sh" >&2
        exit 1
    fi
    
    # Detect TTY environment and set appropriate TERM
    local tty_device=""
    if [[ -t 0 ]]; then
        tty_device=$(tty 2>/dev/null || echo "")
    fi
    
    # If TERM is not set or invalid, detect and set appropriate value
    if [[ -z "${TERM:-}" ]] || (command -v tput &> /dev/null && ! tput longname &> /dev/null 2>&1); then
        # Detect terminal type based on device
        if [[ -n "$tty_device" ]]; then
            if [[ "$tty_device" =~ ^/dev/tty[1-9] ]] || [[ "$tty_device" =~ ^/dev/ttyS ]] || [[ "$tty_device" =~ ^/dev/console ]]; then
                # Virtual console (tty1-tty6) or serial console - use 'linux' term
                export TERM=linux
            elif [[ "$tty_device" =~ ^/dev/pts ]]; then
                # Pseudo-terminal (SSH, X terminal) - use xterm
                export TERM=xterm
            else
                # Unknown device, try linux first
                export TERM=linux
            fi
        else
            # Can't detect tty device, check if we're likely in a virtual console
            # by checking if X is running or if we're in a graphical environment
            if [[ -z "${DISPLAY:-}" ]] && [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
                # Likely in a virtual console (TTY)
                export TERM=linux
            else
                # Likely in a graphical terminal
                export TERM=xterm
            fi
        fi
    fi
    
    # Ensure TERM is set (fallback to linux for TTY compatibility)
    export TERM="${TERM:-linux}"
    
    # Verify TERM is valid by testing tput (if available)
    if command -v tput &> /dev/null; then
        if ! tput longname &> /dev/null 2>&1; then
            # TERM might be invalid, try common TTY terms
            for term in linux vt100 xterm; do
                if TERM="$term" tput longname &> /dev/null 2>&1; then
                    export TERM="$term"
                    break
                fi
            done
        fi
    fi
    
    # Test if dialog can actually work
    if ! command -v dialog &> /dev/null; then
        return 0  # Will be caught by check_dependencies
    fi
    
    # Test dialog with current TERM
    if ! dialog --version &> /dev/null; then
        # Try with a more basic TERM if current one fails
        local original_term="$TERM"
        for fallback_term in linux vt100 xterm; do
            export TERM="$fallback_term"
            if dialog --version &> /dev/null; then
                break
            fi
        done
        if ! dialog --version &> /dev/null; then
            echo "WARNING: Dialog may not work properly in this environment." >&2
            export TERM="$original_term"
        fi
    fi
}

# Dialog configuration
# Use /dev/null to prevent reading config file, dialog will auto-detect terminal capabilities
export DIALOGRC=/dev/null

# Setup dialog for TTY compatibility
setup_dialog_colors() {
    # Dialog automatically adapts to terminal capabilities
    # We just need to ensure TERM is set correctly (done in check_tty)
    # Dialog will work fine in TTY without any special options
    
    # Set dialog label defaults for consistent TTY experience
    export DIALOG_OK_LABEL="OK"
    export DIALOG_CANCEL_LABEL="Cancel"
    export DIALOG_EXTRA_LABEL="Extra"
    export DIALOG_HELP_LABEL="Help"
    export DIALOG_YES_LABEL="Yes"
    export DIALOG_NO_LABEL="No"
    
    # Ensure dialog can access the terminal properly
    # This is especially important for TTY environments
    if command -v dialog &> /dev/null; then
        # Test that dialog can actually display (silent test)
        if ! dialog --print-version &> /dev/null 2>&1; then
            echo "WARNING: Dialog may have issues in this terminal environment." >&2
            echo "TERM is set to: $TERM" >&2
        fi
    fi
}

# Installation variables
ROOT_PASSWORD=""
LOCK_ROOT=false
USERNAME=""
USER_PASSWORD=""
SELECTED_COUNTRIES=()
TIMEZONE=""
KEYBOARD_LAYOUTS=()
LOCALE=""
SELECTED_KERNELS=()
KERNEL_PACKAGES=()
INSTALL_DISK=""
PARTITION_METHOD=""
MOUNT_POINT="/mnt"
EFI_PARTITION=""
ROOT_PARTITION=""

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        if command -v dialog &> /dev/null && [[ -t 1 ]] && [[ -t 2 ]]; then
            dialog --msgbox "This script must be run as root!" 7 50
        else
            echo "ERROR: This script must be run as root!" >&2
            echo "Please run with: sudo bash install.sh" >&2
        fi
        exit 1
    fi
}

# Install dialog if missing (required for TUI)
install_dialog_if_missing() {
    if ! command -v dialog &> /dev/null; then
        echo "Installing dialog package..." >&2
        if command -v pacman &> /dev/null; then
            pacman -Sy --noconfirm dialog || {
                echo "ERROR: Failed to install dialog. Please install it manually: pacman -Sy dialog" >&2
                exit 1
            }
        else
            echo "ERROR: pacman not found. Cannot install dialog automatically." >&2
            echo "Please install dialog manually before running this script." >&2
            exit 1
        fi
    fi
}

# Check for required tools
check_dependencies() {
    local missing=()
    
    # Dialog is now auto-installed, so we don't check for it here
    for cmd in reflector cfdisk mkfs.btrfs mount umount pacstrap genfstab arch-chroot parted lsblk; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        if command -v dialog &> /dev/null && [[ -t 1 ]] && [[ -t 2 ]]; then
            dialog --msgbox "Missing required tools: ${missing[*]}\n\nPlease install:\n- reflector\n- arch-install-scripts\n- btrfs-progs\n- parted\n- util-linux" 12 60
        else
            echo "ERROR: Missing required tools: ${missing[*]}" >&2
            echo "Please install: reflector arch-install-scripts btrfs-progs parted util-linux" >&2
        fi
        exit 1
    fi
}

# Welcome screen
show_welcome() {
    dialog --backtitle "Telva Linux Installer" \
           --title "Welcome" \
           --msgbox "Welcome to the Telva Linux Installation Script!\n\nThis installer will guide you through the installation process.\n\nPress OK to continue." 10 60
}

# Get root password
get_root_password() {
    while true; do
        ROOT_PASSWORD=$(dialog --backtitle "Telva Linux Installer" \
                                --title "Root Password" \
                                --insecure \
                                --passwordbox "Enter root password (leave blank to lock root account):" 10 60 3>&1 1>&2 2>&3)
        local ret=$?
        
        if [[ $ret -ne 0 ]]; then
            dialog --msgbox "Installation cancelled." 7 50
            exit 1
        fi
        
        if [[ -z "$ROOT_PASSWORD" ]]; then
            # IMPORTANT: under `set -e`, a "No" (exit code 1) from dialog would exit the script
            # unless we capture it via an `if dialog ...; then ... else ... fi` block.
            if dialog --backtitle "Telva Linux Installer" \
                      --title "Lock Root Account" \
                      --yesno "WARNING: You left the root password blank.\n\nDo you want to lock the root account?\n(Recommended for security)\n\nSelect 'No' to go back and set a root password." 12 70; then
                LOCK_ROOT=true
                break
            else
                continue
            fi
        else
            ROOT_PASSWORD_CONFIRM=$(dialog --backtitle "Telva Linux Installer" \
                                           --title "Confirm Root Password" \
                                           --insecure \
                                           --passwordbox "Re-enter root password:" 10 60 3>&1 1>&2 2>&3)
            local ret=$?
            
            if [[ $ret -ne 0 ]]; then
                continue
            fi
            
            if [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD_CONFIRM" ]]; then
                break
            else
                dialog --msgbox "Passwords do not match! Please try again." 7 50
            fi
        fi
    done
}

# Get username
get_username() {
    while true; do
        USERNAME=$(dialog --backtitle "Telva Linux Installer" \
                          --title "Username" \
                          --inputbox "Enter username for the new user:" 10 60 3>&1 1>&2 2>&3)
        local ret=$?
        
        if [[ $ret -ne 0 ]]; then
            dialog --msgbox "Installation cancelled." 7 50
            exit 1
        fi
        
        if [[ -z "$USERNAME" ]]; then
            dialog --msgbox "Username cannot be empty!" 7 50
            continue
        fi
        
        # Validate username (lowercase letters, numbers, underscore, hyphen)
        if [[ ! "$USERNAME" =~ ^[a-z][a-z0-9_-]*$ ]]; then
            dialog --msgbox "Invalid username!\n\nUsername must:\n- Start with a lowercase letter\n- Contain only lowercase letters, numbers, underscore, or hyphen" 10 60
            continue
        fi
        
        break
    done
}

# Get user password
get_user_password() {
    while true; do
        USER_PASSWORD=$(dialog --backtitle "Telva Linux Installer" \
                                --title "User Password" \
                                --insecure \
                                --passwordbox "Enter password for user '$USERNAME':" 10 60 3>&1 1>&2 2>&3)
        local ret=$?
        
        if [[ $ret -ne 0 ]]; then
            dialog --msgbox "Installation cancelled." 7 50
            exit 1
        fi
        
        if [[ -z "$USER_PASSWORD" ]]; then
            dialog --msgbox "Password cannot be empty!" 7 50
            continue
        fi
        
        USER_PASSWORD_CONFIRM=$(dialog --backtitle "Telva Linux Installer" \
                                       --title "Confirm User Password" \
                                       --insecure \
                                       --passwordbox "Re-enter password for user '$USERNAME':" 10 60 3>&1 1>&2 2>&3)
        local ret=$?
        
        if [[ $ret -ne 0 ]]; then
            continue
        fi
        
        if [[ "$USER_PASSWORD" == "$USER_PASSWORD_CONFIRM" ]]; then
            break
        else
            dialog --msgbox "Passwords do not match! Please try again." 7 50
        fi
    done
}

# Get timezone
get_timezone() {
    # Use timedatectl list-timezones if available (simpler)
    if command -v timedatectl &> /dev/null; then
        local timezones=()
        while IFS= read -r tz; do
            if [[ -n "$tz" ]]; then
                local display_name=$(echo "$tz" | sed 's|_| |g' | sed 's|/| - |g')
                timezones+=("$tz" "$display_name")
            fi
        done < <(timedatectl list-timezones | head -800)
        
        if [[ ${#timezones[@]} -gt 0 ]]; then
            TIMEZONE=$(dialog --backtitle "Telva Linux Installer" \
                              --title "Select Timezone" \
                              --menu "Select your timezone:" 20 60 15 \
                              "${timezones[@]}" 3>&1 1>&2 2>&3)
            local ret=$?
            
            if [[ $ret -ne 0 ]] || [[ -z "$TIMEZONE" ]]; then
                TIMEZONE="UTC"
            fi
            return 0
        fi
    fi
    
    # Fallback: Get list of timezones (regions) from /usr/share/zoneinfo
    local regions=()
    if [[ -d /usr/share/zoneinfo ]]; then
        while IFS= read -r region; do
            if [[ -n "$region" ]] && [[ -d "/usr/share/zoneinfo/$region" ]] && [[ ! "$region" =~ ^(right|posix|SystemV|Etc)$ ]]; then
                regions+=("$region" "$region")
            fi
        done < <(find /usr/share/zoneinfo -maxdepth 1 -type d ! -path /usr/share/zoneinfo | sort | sed 's|/usr/share/zoneinfo/||' | head -30)
    fi
    
    if [[ ${#regions[@]} -eq 0 ]]; then
        # Fallback if timezone info not available
        TIMEZONE="UTC"
        return 0
    fi
    
    local selected_region=$(dialog --backtitle "Telva Linux Installer" \
                                   --title "Select Timezone Region" \
                                   --menu "Select your timezone region:" 20 60 12 \
                                   "${regions[@]}" 3>&1 1>&2 2>&3)
    local ret=$?
    
    if [[ $ret -ne 0 ]] || [[ -z "$selected_region" ]]; then
        TIMEZONE="UTC"
        return 0
    fi
    
    # Get cities in selected region
    local cities=()
    if [[ -d "/usr/share/zoneinfo/$selected_region" ]]; then
        while IFS= read -r city; do
            if [[ -n "$city" ]] && [[ -f "/usr/share/zoneinfo/$selected_region/$city" ]] && [[ ! "$city" =~ \.tab$ ]]; then
                cities+=("$city" "$city")
            fi
        done < <(find "/usr/share/zoneinfo/$selected_region" -maxdepth 1 -type f | sort | sed "s|/usr/share/zoneinfo/$selected_region/||" | head -30)
    fi
    
    if [[ ${#cities[@]} -eq 0 ]]; then
        TIMEZONE="$selected_region"
        return 0
    fi
    
    local selected_city=$(dialog --backtitle "Telva Linux Installer" \
                                 --title "Select City" \
                                 --menu "Select your city in $selected_region:" 20 60 12 \
                                 "${cities[@]}" 3>&1 1>&2 2>&3)
    ret=$?
    
    if [[ $ret -ne 0 ]] || [[ -z "$selected_city" ]]; then
        TIMEZONE="$selected_region"
    else
        TIMEZONE="$selected_region/$selected_city"
    fi
}

# Get keyboard layouts
get_keyboard_layouts() {
    # Keep this list intentionally small and beginner-friendly.
    # This config applies to the console/shell (TTY/vconsole), not GUI.
    local layouts=()

    if command -v localectl &> /dev/null; then
        local available_keymaps
        available_keymaps="$(localectl list-keymaps 2>/dev/null || true)"

        add_keymap_if_exists() {
            local keymap="$1"
            local label="$2"
            if echo "$available_keymaps" | grep -Fxq "$keymap"; then
                layouts+=("$keymap" "$label" "off")
            fi
        }

        # Basic/commonly requested console keymaps (only added if present)
        add_keymap_if_exists "us" "English (US)"
        add_keymap_if_exists "uk" "English (UK)"
        add_keymap_if_exists "de" "German"
        add_keymap_if_exists "ru" "Russian"
        add_keymap_if_exists "hr" "Croatian"
        add_keymap_if_exists "dvorak" "Dvorak (US)"
    fi

    # Fallback: minimal set (may vary by environment, but avoids an empty dialog)
    if [[ ${#layouts[@]} -eq 0 ]]; then
        layouts=(
            "us" "English (US)" "off"
            "uk" "English (UK)" "off"
            "de" "German" "off"
            "ru" "Russian" "off"
            "hr" "Croatian" "off"
            "dvorak" "Dvorak (US)" "off"
        )
    fi
    
    local result=$(dialog --backtitle "Telva Linux Installer" \
                          --title "Select Keyboard Layouts" \
                          --checklist "Select one or more console/shell keyboard layouts (TTY/vconsole).\n\nNote: This does NOT configure your future GUI keyboard layout.\n\nPress SPACE to select/deselect, ENTER to confirm." 22 72 12 \
                          "${layouts[@]}" 3>&1 1>&2 2>&3)
    local ret=$?
    
    if [[ $ret -ne 0 ]]; then
        dialog --msgbox "Installation cancelled." 7 50
        exit 1
    fi
    
    KEYBOARD_LAYOUTS=($result)
    
    # Default to US if nothing selected
    if [[ ${#KEYBOARD_LAYOUTS[@]} -eq 0 ]]; then
        KEYBOARD_LAYOUTS=("us")
        dialog --msgbox "No keyboard layouts selected. Using 'us' as default." 7 50
    fi
}

# Get kernels to install
get_kernels() {
    # `dialog` doesn't support hover tooltips.
    # Best alternative: show the one-liner directly in the checklist description column.
    local kernel_items=(
        "linux" "Default: best compatibility, well-tested" "on"
        "linux-lts" "LTS: older/stable series, fewer surprises" "off"
        "linux-zen" "Zen: tuned for responsiveness/performance" "off"
        "linux-hardened" "Hardened: stronger security defaults" "off"
    )

    local result
    result=$(dialog --backtitle "Telva Linux Installer" \
                    --title "Select Kernels" \
                    --checklist "Choose which kernels to install:\n\nPress SPACE to select/deselect, ENTER to confirm." 20 72 10 \
                    "${kernel_items[@]}" 3>&1 1>&2 2>&3)
    local ret=$?

    if [[ $ret -ne 0 ]]; then
        dialog --msgbox "Installation cancelled." 7 50
        exit 1
    fi

    SELECTED_KERNELS=($result)
    if [[ ${#SELECTED_KERNELS[@]} -eq 0 ]]; then
        SELECTED_KERNELS=("linux")
        dialog --msgbox "No kernels selected. Using 'linux' as default." 7 50
    fi

    # Build pacstrap kernel package list (kernel + matching headers)
    KERNEL_PACKAGES=()
    local k
    for k in "${SELECTED_KERNELS[@]}"; do
        case "$k" in
            linux)
                KERNEL_PACKAGES+=("linux" "linux-headers")
                ;;
            linux-lts)
                KERNEL_PACKAGES+=("linux-lts" "linux-lts-headers")
                ;;
            linux-zen)
                KERNEL_PACKAGES+=("linux-zen" "linux-zen-headers")
                ;;
            linux-hardened)
                KERNEL_PACKAGES+=("linux-hardened" "linux-hardened-headers")
                ;;
        esac
    done
}

# Get locale
get_locale() {
    # 1. Set the default immediately
    LOCALE="en_US.UTF-8"

    # 2. Ask the user if they want to change the default
    # Modification Details:
    # --yes-label "No":   Changes the left button (default/return 0) to display "No".
    # --no-label "Yes":   Changes the right button (return 1) to display "Yes".
    # ! dialog:           Inverts the logic. If user selects "Yes" (Right button), 
    #                     dialog returns 1. '! 1' becomes 0 (True), entering the block.
    if ! dialog --backtitle "Telva Linux Installer" \
                --title "Locale Selection" \
                --yes-label "No" \
                --no-label "Yes" \
                --yesno "The default locale is configured as 'en_US.UTF-8'.\n\nDo you wish to select a different one?" 10 60; then
        
        # Get list of available locales
        local locales=()

        if [[ -f /etc/locale.gen ]]; then
            while IFS= read -r line; do
                if [[ "$line" =~ ^#?([a-z]{2}_[A-Z]{2}\.UTF-8) ]]; then
                    local locale="${BASH_REMATCH[1]}"
                    local display_name=$(echo "$locale" | sed 's/_/ /g' | sed 's/\.UTF-8//')
                    locales+=("$locale" "$display_name")
                fi
            done < /etc/locale.gen
        fi
        
        # Fallback common locales
        if [[ ${#locales[@]} -eq 0 ]]; then
            locales=(
                "en_US.UTF-8" "English (US)"
                "en_GB.UTF-8" "English (UK)"
                "de_DE.UTF-8" "German"
                "fr_FR.UTF-8" "French"
                "es_ES.UTF-8" "Spanish"
                "it_IT.UTF-8" "Italian"
                "pt_BR.UTF-8" "Portuguese (Brazil)"
                "ru_RU.UTF-8" "Russian"
                "ja_JP.UTF-8" "Japanese"
                "zh_CN.UTF-8" "Chinese (Simplified)"
            )
        fi
        
        # Show the selection menu
        local SELECTED_LOCALE
        SELECTED_LOCALE=$(dialog --backtitle "Telva Linux Installer" \
                                --title "Select Locale" \
                                --menu "Select your locale:" 20 60 15 \
                                "${locales[@]}" 3>&1 1>&2 2>&3)
        
        local ret=$?

        # Update LOCALE only if they made a valid selection
        if [[ $ret -eq 0 ]] && [[ -n "$SELECTED_LOCALE" ]]; then
            LOCALE="$SELECTED_LOCALE"
        else
            dialog --msgbox "Selection cancelled. Reverting to default: 'en_US.UTF-8'." 7 50
        fi

    else
        : 
    fi
}

# Get country mirrors
get_country_mirrors() {
    # List of countries for mirrors
    local countries=(
    "Australia" "AU"
    "Austria" "AT"
    "Belgium" "BE"
    "Brazil" "BR"
    "Canada" "CA"
    "China" "CN"
    "Czech Republic" "CZ"
    "Denmark" "DK"
    "Finland" "FI"
    "France" "FR"
    "Germany" "DE"
    "Greece" "GR"
    "India" "IN"
    "Ireland" "IE"
    "Italy" "IT"
    "Japan" "JP"
    "Netherlands" "NL"
    "Norway" "NO"
    "Poland" "PL"
    "Portugal" "PT"
    "Russia" "RU"
    "Singapore" "SG"
    "South Korea" "KR"
    "Spain" "ES"
    "Sweden" "SE"
    "Switzerland" "CH"
    "Taiwan" "TW"
    "United Kingdom" "GB"
    "United States" "US"
)
    
    # Create checklist
    local checklist_items=()
    for ((i=0; i<${#countries[@]}; i+=2)); do
        checklist_items+=("${countries[i]}" "${countries[i+1]}" "off")
    done
    
    local result=$(dialog --backtitle "Telva Linux Installer" \
                          --title "Select Mirror Countries" \
                          --checklist "Select one or more countries for mirror selection:\n\nPress SPACE to select/deselect, ENTER to confirm." 20 60 15 \
                          "${checklist_items[@]}" 3>&1 1>&2 2>&3)
    local ret=$?
    
    if [[ $ret -ne 0 ]]; then
        dialog --msgbox "Installation cancelled." 7 50
        exit 1
    fi
    
    SELECTED_COUNTRIES=($result)
    
    if [[ ${#SELECTED_COUNTRIES[@]} -eq 0 ]]; then
        dialog --msgbox "No countries selected! Using default mirrors." 7 50
        SELECTED_COUNTRIES=("US")
    fi
}

# Update mirrors with reflector
update_mirrors() {
    dialog --infobox "Updating mirror list with reflector..." 5 50
    
    local country_list=$(IFS=','; echo "${SELECTED_COUNTRIES[*]}")
    
    reflector --country "$country_list" \
              --protocol https \
              --latest 20 \
              --sort rate \
              --save /etc/pacman.d/mirrorlist
    
    if [[ $? -eq 0 ]]; then
        dialog --msgbox "Mirror list updated successfully!" 7 50
    else
        dialog --msgbox "Warning: Failed to update mirrors. Continuing with default mirrors." 8 60
    fi
}

# Get available disks
get_disks() {
    local disks=()
    while IFS= read -r line; do
        local disk=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')
        local model=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')
        disks+=("$disk" "$size - $model")
    done < <(lsblk -dno NAME,SIZE,MODEL | grep -E '^sd[a-z]|^nvme|^vd[a-z]')
    
    if [[ ${#disks[@]} -eq 0 ]]; then
        dialog --msgbox "No suitable disks found!" 7 50
        exit 1
    fi
    
    INSTALL_DISK=$(dialog --backtitle "Telva Linux Installer" \
                          --title "Select Installation Disk" \
                          --menu "Select the disk to install Telva Linux:" 15 60 8 \
                          "${disks[@]}" 3>&1 1>&2 2>&3)
    local ret=$?
    
    if [[ $ret -ne 0 ]] || [[ -z "$INSTALL_DISK" ]]; then
        dialog --msgbox "No disk selected! Installation cancelled." 7 50
        exit 1
    fi
}

# Get partition method
get_partition_method() {
    PARTITION_METHOD=$(dialog --backtitle "Telva Linux Installer" \
                              --title "Partitioning Method" \
                              --menu "Select partitioning method for $INSTALL_DISK:" 12 60 4 \
                              "1" "Use full disk (WARNING: All data will be erased!)" \
                              "2" "Use remaining free space" \
                              "3" "Manual partitioning (cfdisk)" 3>&1 1>&2 2>&3)
    local ret=$?
    
    if [[ $ret -ne 0 ]] || [[ -z "$PARTITION_METHOD" ]]; then
        dialog --msgbox "No method selected! Installation cancelled." 7 50
        exit 1
    fi
}

# Check if system is UEFI
is_uefi() {
    [[ -d /sys/firmware/efi ]]
}

# Partition disk - full disk
partition_full_disk() {
    local disk="/dev/$INSTALL_DISK"
    
    dialog --backtitle "Telva Linux Installer" \
           --title "WARNING" \
           --yesno "WARNING: This will erase ALL data on $disk!\n\nAre you sure you want to continue?" 10 60
    
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    dialog --infobox "Partitioning $disk..." 5 50
    
    # Create partition table
    if is_uefi; then
        parted -s "$disk" mklabel gpt
        # EFI partition (512MB)
        parted -s "$disk" mkpart primary fat32 1MiB 513MiB
        parted -s "$disk" set 1 esp on
        # Root partition (rest of disk)
        parted -s "$disk" mkpart primary btrfs 513MiB 100%
    else
        parted -s "$disk" mklabel msdos
        # Root partition (entire disk)
        parted -s "$disk" mkpart primary btrfs 1MiB 100%
        parted -s "$disk" set 1 boot on
    fi
    
    # Wait for partitions to be created
    sleep 2
    
    # Set partition variables
    if is_uefi; then
        if [[ "$INSTALL_DISK" =~ ^nvme ]]; then
            EFI_PARTITION="${disk}p1"
            ROOT_PARTITION="${disk}p2"
        else
            EFI_PARTITION="${disk}1"
            ROOT_PARTITION="${disk}2"
        fi
    else
        if [[ "$INSTALL_DISK" =~ ^nvme ]]; then
            ROOT_PARTITION="${disk}p1"
        else
            ROOT_PARTITION="${disk}1"
        fi
    fi
}

# Partition disk - free space
partition_free_space() {
    local disk="/dev/$INSTALL_DISK"
    
    dialog --infobox "Checking for free space on $disk..." 5 50
    
    # Get free space information
    local free_info=$(parted -s "$disk" print free | grep "Free Space" | tail -1)
    
    if [[ -z "$free_info" ]]; then
        dialog --msgbox "No free space found on $disk!\n\nPlease select a different disk or use full disk option." 10 60
        exit 1
    fi
    
    # Extract start and end from free space (format: "Free Space  1024MiB  2048MiB")
    local start=$(echo "$free_info" | awk '{print $3}' | sed 's/MiB//')
    local end=$(echo "$free_info" | awk '{print $4}' | sed 's/MiB//')
    
    if [[ -z "$start" ]] || [[ -z "$end" ]] || [[ "$start" == "$end" ]]; then
        dialog --msgbox "No sufficient free space found on $disk!\n\nPlease select a different disk or use full disk option." 10 60
        exit 1
    fi
    
    dialog --infobox "Creating partition in free space..." 5 50
    
    # Create partition in free space
    if is_uefi; then
        # Check if EFI partition exists
        local efi_exists=$(parted -s "$disk" print | grep -c "esp" || true)
        if [[ "$efi_exists" -eq 0 ]]; then
            # Check if we have enough space for EFI partition (512MB)
            local efi_end=$((start + 512))
            if [[ $efi_end -lt $end ]]; then
                parted -s "$disk" mkpart primary fat32 "${start}MiB" "${efi_end}MiB"
                local efi_part_num=$(parted -s "$disk" print | grep -v "^$" | tail -1 | awk '{print $1}')
                parted -s "$disk" set "$efi_part_num" esp on
                start=$efi_end
                
                # Set EFI partition path
                if [[ "$INSTALL_DISK" =~ ^nvme ]]; then
                    EFI_PARTITION="${disk}p${efi_part_num}"
                else
                    EFI_PARTITION="${disk}${efi_part_num}"
                fi
            fi
        else
            # Find existing EFI partition
            local efi_part_num=$(parted -s "$disk" print | grep "esp" | awk '{print $1}')
            if [[ "$INSTALL_DISK" =~ ^nvme ]]; then
                EFI_PARTITION="${disk}p${efi_part_num}"
            else
                EFI_PARTITION="${disk}${efi_part_num}"
            fi
        fi
        # Create root partition
        parted -s "$disk" mkpart primary btrfs "${start}MiB" "${end}MiB"
    else
        parted -s "$disk" mkpart primary btrfs "${start}MiB" "${end}MiB"
        local root_part_num=$(parted -s "$disk" print | tail -1 | awk '{print $1}')
        parted -s "$disk" set "$root_part_num" boot on
    fi
    
    sleep 2
    
    # Set root partition variable
    local root_part_num=$(parted -s "$disk" print | grep -v "^$" | tail -1 | awk '{print $1}')
    if [[ "$INSTALL_DISK" =~ ^nvme ]]; then
        ROOT_PARTITION="${disk}p${root_part_num}"
    else
        ROOT_PARTITION="${disk}${root_part_num}"
    fi
}

# Partition disk - manual
partition_manual() {
    local disk="/dev/$INSTALL_DISK"
    
    if is_uefi; then
        dialog --msgbox "You will now be taken to cfdisk for manual partitioning.\n\nAfter partitioning:\n- Make sure you have a root partition (btrfs)\n- Make sure you have an EFI partition (fat32, ~512MB)\n- Mark EFI partition as ESP/boot\n\nPress OK to continue." 12 60
    else
        dialog --msgbox "You will now be taken to cfdisk for manual partitioning.\n\nAfter partitioning:\n- Make sure you have a root partition (btrfs)\n- Mark root partition as boot\n\nPress OK to continue." 12 60
    fi
    
    cfdisk "$disk"
    
    dialog --msgbox "Please enter the partition numbers:\n\n(Check with: lsblk /dev/$INSTALL_DISK)" 10 60
    
    if is_uefi; then
        local efi_part=$(dialog --backtitle "Telva Linux Installer" \
                                --title "EFI Partition" \
                                --inputbox "Enter EFI partition number (e.g., 1):" 10 60 3>&1 1>&2 2>&3)
        local ret=$?
        
        if [[ $ret -ne 0 ]] || [[ -z "$efi_part" ]]; then
            dialog --msgbox "EFI partition number required!" 7 50
            exit 1
        fi
        
        if [[ "$INSTALL_DISK" =~ ^nvme ]]; then
            EFI_PARTITION="${disk}p${efi_part}"
        else
            EFI_PARTITION="${disk}${efi_part}"
        fi
    fi
    
    local root_part=$(dialog --backtitle "Telva Linux Installer" \
                             --title "Root Partition" \
                             --inputbox "Enter root partition number (e.g., 2):" 10 60 3>&1 1>&2 2>&3)
    local ret=$?
    
    if [[ $ret -ne 0 ]] || [[ -z "$root_part" ]]; then
        dialog --msgbox "Root partition number required!" 7 50
        exit 1
    fi
    
    if [[ "$INSTALL_DISK" =~ ^nvme ]]; then
        ROOT_PARTITION="${disk}p${root_part}"
    else
        ROOT_PARTITION="${disk}${root_part}"
    fi
}

# Format partitions
format_partitions() {
    dialog --infobox "Formatting partitions..." 5 50
    
    # Format EFI partition if UEFI
    if is_uefi && [[ -n "$EFI_PARTITION" ]]; then
        mkfs.fat -F32 "$EFI_PARTITION"
    fi
    
    # Format root partition with btrfs
    mkfs.btrfs -f "$ROOT_PARTITION"
    
    # Mount root partition
    mount "$ROOT_PARTITION" "$MOUNT_POINT"
    
    # Create btrfs subvolumes
    btrfs subvolume create "$MOUNT_POINT/@"
    btrfs subvolume create "$MOUNT_POINT/@home"
    btrfs subvolume create "$MOUNT_POINT/@var"
    btrfs subvolume create "$MOUNT_POINT/@snapshots"
    
    # Unmount to remount with subvolumes
    umount "$MOUNT_POINT"
    
    # Mount with subvolumes
    mount -o subvol=@,compress=zstd,noatime "$ROOT_PARTITION" "$MOUNT_POINT"
    
    # Create mount points
    mkdir -p "$MOUNT_POINT/home"
    mkdir -p "$MOUNT_POINT/var"
    mkdir -p "$MOUNT_POINT/.snapshots"
    
    # Mount subvolumes
    mount -o subvol=@home,compress=zstd,noatime "$ROOT_PARTITION" "$MOUNT_POINT/home"
    mount -o subvol=@var,compress=zstd,noatime "$ROOT_PARTITION" "$MOUNT_POINT/var"
    mount -o subvol=@snapshots,compress=zstd,noatime "$ROOT_PARTITION" "$MOUNT_POINT/.snapshots"
    
    # Mount EFI partition if UEFI
    if is_uefi && [[ -n "$EFI_PARTITION" ]]; then
        mkdir -p "$MOUNT_POINT/boot/efi"
        mount "$EFI_PARTITION" "$MOUNT_POINT/boot/efi"
    fi
}

# Install base system
install_base() {
    dialog --infobox "Installing base system and essential packages..." 5 60
    
    # Base packages
    pacstrap "$MOUNT_POINT" base base-devel "${KERNEL_PACKAGES[@]}" linux-firmware \
             btrfs-progs networkmanager dialog reflector nano sudo \
             grub efibootmgr dosfstools os-prober mtools
    
    if [[ $? -ne 0 ]]; then
        dialog --msgbox "Error installing base system!" 7 50
        exit 1
    fi
}

# Generate fstab
generate_fstab() {
    dialog --infobox "Generating fstab..." 5 50
    genfstab -U "$MOUNT_POINT" >> "$MOUNT_POINT/etc/fstab"
    
    # Update fstab with subvolume options
    sed -i 's|subvol=@|subvol=@,compress=zstd,noatime|g' "$MOUNT_POINT/etc/fstab"
    sed -i 's|subvol=@home|subvol=@home,compress=zstd,noatime|g' "$MOUNT_POINT/etc/fstab"
    sed -i 's|subvol=@var|subvol=@var,compress=zstd,noatime|g' "$MOUNT_POINT/etc/fstab"
    sed -i 's|subvol=@snapshots|subvol=@snapshots,compress=zstd,noatime|g' "$MOUNT_POINT/etc/fstab"
}

# Configure zram swap
configure_zram_swap() {
    dialog --infobox "Configuring zram swap..." 5 50
    
    # Create zram service file
    cat > "$MOUNT_POINT/etc/systemd/system/zram.service" <<'EOF'
[Unit]
Description=Swap with zram
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/modprobe zram
ExecStart=/usr/bin/bash -c 'echo lz4 > /sys/block/zram0/comp_algorithm'
ExecStart=/usr/bin/bash -c 'echo 50% > /sys/block/zram0/disksize'
ExecStart=/usr/bin/mkswap /dev/zram0
ExecStart=/usr/bin/swapon /dev/zram0 --priority 5
ExecStop=/usr/bin/swapoff /dev/zram0
ExecStop=/usr/bin/rmmod zram

[Install]
WantedBy=multi-user.target
EOF
    
    # Enable zram service
    arch-chroot "$MOUNT_POINT" systemctl enable zram.service
}

# Configure system
configure_system() {
    dialog --infobox "Configuring system..." 5 50
    
    # Set timezone
    if [[ -n "$TIMEZONE" ]] && [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
        arch-chroot "$MOUNT_POINT" ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    else
        arch-chroot "$MOUNT_POINT" ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    fi
    arch-chroot "$MOUNT_POINT" hwclock --systohc
    
    # Configure keyboard layouts
    if [[ ${#KEYBOARD_LAYOUTS[@]} -gt 0 ]]; then
        local keymap_line="KEYMAP=${KEYBOARD_LAYOUTS[0]}"
        echo "$keymap_line" > "$MOUNT_POINT/etc/vconsole.conf"

        # Set systemd-localed if available (for console keymap)
        if [[ -f "$MOUNT_POINT/usr/bin/localectl" ]]; then
            arch-chroot "$MOUNT_POINT" localectl set-keymap "${KEYBOARD_LAYOUTS[0]}" 2>/dev/null || true
        fi
    fi
    
    # Generate locale
    if [[ -n "$LOCALE" ]]; then
        # Uncomment locale in locale.gen
        sed -i "s|^#\($LOCALE\)|\1|" "$MOUNT_POINT/etc/locale.gen"
        arch-chroot "$MOUNT_POINT" locale-gen
        
        # Set default locale
        echo "LANG=$LOCALE" > "$MOUNT_POINT/etc/locale.conf"
        echo "LC_ALL=$LOCALE" >> "$MOUNT_POINT/etc/locale.conf"
    else
        # Fallback to en_US.UTF-8
        sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$MOUNT_POINT/etc/locale.gen"
        arch-chroot "$MOUNT_POINT" locale-gen
        echo "LANG=en_US.UTF-8" > "$MOUNT_POINT/etc/locale.conf"
    fi
    
    # Set hostname
    echo "archlinux" > "$MOUNT_POINT/etc/hostname"
    
    # Configure hosts file
    cat > "$MOUNT_POINT/etc/hosts" <<EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	archlinux.localdomain	archlinux
EOF
    
    # Configure root password or lock account
    if [[ "$LOCK_ROOT" == true ]]; then
        arch-chroot "$MOUNT_POINT" passwd -l root 2>/dev/null || true
    else
        echo "root:$ROOT_PASSWORD" | arch-chroot "$MOUNT_POINT" chpasswd
    fi
    
    # Create user
    arch-chroot "$MOUNT_POINT" useradd -m -G wheel,audio,video,optical,storage "$USERNAME"
    echo "$USERNAME:$USER_PASSWORD" | arch-chroot "$MOUNT_POINT" chpasswd
    
    # Configure sudo
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' "$MOUNT_POINT/etc/sudoers"
    
    # Enable NetworkManager
    arch-chroot "$MOUNT_POINT" systemctl enable NetworkManager
    
    # Configure zram swap
    configure_zram_swap
    
    # Install and configure GRUB
    if is_uefi; then
        arch-chroot "$MOUNT_POINT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    else
        arch-chroot "$MOUNT_POINT" grub-install --target=i386-pc "/dev/$INSTALL_DISK"
    fi
    
    arch-chroot "$MOUNT_POINT" grub-mkconfig -o /boot/grub/grub.cfg
}

# Main installation function
main() {
    check_root
    install_dialog_if_missing
    check_tty
    setup_dialog_colors
    check_dependencies
    show_welcome
    get_root_password
    get_username
    get_user_password
    get_timezone
    get_keyboard_layouts
    get_kernels
    get_locale
    get_country_mirrors
    update_mirrors
    get_disks
    get_partition_method
    
    # Partition based on method
    case "$PARTITION_METHOD" in
        "1")
            partition_full_disk
            ;;
        "2")
            partition_free_space
            ;;
        "3")
            partition_manual
            ;;
    esac
    
    # Confirm before proceeding
    local kernels_display
    kernels_display=$(IFS=' '; echo "${SELECTED_KERNELS[*]}")
    dialog --backtitle "Telva Linux Installer" \
           --title "Confirm Installation" \
           --yesno "Ready to install Telva Linux!\n\nDisk: $INSTALL_DISK\nRoot Partition: $ROOT_PARTITION\nKernels: $kernels_display\nUsername: $USERNAME\n\nContinue with installation?" 13 70
    
    if [[ $? -ne 0 ]]; then
        dialog --msgbox "Installation cancelled." 7 50
        exit 1
    fi
    
    format_partitions
    install_base
    generate_fstab
    configure_system
    
    dialog --backtitle "Telva Linux Installer" \
           --title "Installation Complete" \
           --msgbox "Installation completed successfully!\n\nYou can now reboot into your new Telva Linux system.\n\nRemember to:\n- Remove installation media\n- Reboot the system (reboot)" 12 60
}

# Run main function
main
