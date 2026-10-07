#!/usr/bin/env bash
set -e

# ==============================================================================
# ExpressiveOS AVB 2.0 Titan M Key Enrollment & Bootloader Locking Tool
# Target: Google Pixel 11 Pro / XL
# ==============================================================================

KEY_IMG="vendor/expressive/keys/avb_custom_key.img"

if [ ! -f "${KEY_IMG}" ]; then
    echo "Error: ${KEY_IMG} not found! Run tools/avb/generate_keys.sh first."
    exit 1
fi

echo "=========================================================="
echo " ExpressiveOS AVB 2.0 Bootloader Locking for Pixel 11 Pro/XL"
echo "=========================================================="
echo "1. Connect your Pixel 11 Pro / XL in Bootloader (Fastboot) mode."
echo "2. Press ENTER to enroll the custom key."
read -r

echo "Enrolling custom AVB key into Titan M security chip..."
fastboot flashing set-custom-key "${KEY_IMG}"

echo "Custom key enrolled successfully!"
echo "Would you like to lock the bootloader now? (y/N)"
read -r response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    echo "Locking bootloader... Follow prompts on device display to confirm."
    fastboot flashing lock
    echo "✓ Bootloader locked with green/yellow verified boot active!"
else
    echo "Bootloader left unlocked. Lock when ready using 'fastboot flashing lock'."
fi
