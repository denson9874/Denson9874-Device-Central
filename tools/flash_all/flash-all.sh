#!/usr/bin/env bash
# ==============================================================================
# ExpressiveOS Fastboot Flash Installer for Pixel 11 Pro / XL
# ==============================================================================

set -e

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_CYAN="\033[36m"
CLR_GREEN="\033[32m"
CLR_YELLOW="\033[33m"
CLR_RED="\033[31m"

echo -e "${CLR_BOLD}${CLR_CYAN}======================================================${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}      ExpressiveOS Flasher — Pixel 11 Pro / XL        ${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}======================================================${CLR_RESET}"

if ! command -v fastboot &> /dev/null; then
    echo -e "${CLR_RED}Error: fastboot command not found! Please install Android SDK platform-tools.${CLR_RESET}"
    exit 1
fi

FASTBOOT_VER=$(fastboot --version | head -n 1)
echo -e "Detected ${FASTBOOT_VER}"

echo -e "\nWaiting for Pixel 11 Pro / XL device in bootloader mode..."
fastboot wait-for-device

PRODUCT=$(fastboot getvar product 2>&1 | grep "product:" | awk '{print $2}')
echo -e "Device Product ID: ${CLR_GREEN}${PRODUCT}${CLR_RESET}"

# Flash bootloader and radio if packaged
if [ -f "bootloader-pixel11.img" ]; then
    echo -e "Flashing bootloader..."
    fastboot flash bootloader bootloader-pixel11.img
    fastboot reboot-bootloader
    sleep 5
fi

if [ -f "radio-pixel11.img" ]; then
    echo -e "Flashing radio firmware..."
    fastboot flash radio radio-pixel11.img
    fastboot reboot-bootloader
    sleep 5
fi

# Flash system factory update zip
IMAGE_ZIP=$(ls image-expressive_pixel11-*.zip 2>/dev/null | head -n 1 || true)
if [ -z "${IMAGE_ZIP}" ] && [ -f "image-expressive_pixel11.zip" ]; then
    IMAGE_ZIP="image-expressive_pixel11.zip"
fi

if [ -n "${IMAGE_ZIP}" ]; then
    echo -e "${CLR_CYAN}Flashing ExpressiveOS system images from ${IMAGE_ZIP}...${CLR_RESET}"
    fastboot update -w "${IMAGE_ZIP}"
    echo -e "\n${CLR_BOLD}${CLR_GREEN}======================================================${CLR_RESET}"
    echo -e "${CLR_BOLD}${CLR_GREEN}   ExpressiveOS installed successfully! Rebooting...  ${CLR_RESET}"
    echo -e "${CLR_BOLD}${CLR_GREEN}======================================================${CLR_RESET}"
else
    echo -e "${CLR_YELLOW}Notice: No image zip found in current directory. Flashing modular partitions...${CLR_RESET}"
    [ -f "boot.img" ] && fastboot flash boot boot.img
    [ -f "init_boot.img" ] && fastboot flash init_boot init_boot.img
    [ -f "vendor_boot.img" ] && fastboot flash vendor_boot vendor_boot.img
    [ -f "dtbo.img" ] && fastboot flash dtbo dtbo.img
    [ -f "super.img" ] && fastboot flash super super.img
    fastboot reboot
fi
