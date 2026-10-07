#!/usr/bin/env bash
# ==============================================================================
# ExpressiveOS Environment Setup Script for Pixel 11 Pro / XL (Android 17 / API 37)
# ==============================================================================

export OS_NAME="ExpressiveOS"
export OS_VERSION="1.0.0"
export TARGET_ARCH="arm64"
export ANDROID_VERSION="17"
export API_LEVEL="37"

# Color constants
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_CYAN="\033[36m"
CLR_GREEN="\033[32m"
CLR_YELLOW="\033[33m"
CLR_RED="\033[31m"

echo -e "${CLR_BOLD}${CLR_CYAN}======================================================${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}       Initializing ExpressiveOS Build Environment      ${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}          Android 17 / Pixel 11 Pro & XL (API 37)       ${CLR_RESET}"
echo -e "${CLR_BOLD}${CLR_CYAN}======================================================${CLR_RESET}"

# Verify JDK 21 Native Toolchain
if [ -z "$JAVA_HOME" ]; then
    if [ -d "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home" ]; then
        export JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
    elif [ -d "/usr/lib/jvm/java-21-openjdk-amd64" ]; then
        export JAVA_HOME="/usr/lib/jvm/java-21-openjdk-amd64"
    fi
fi

if [ -n "$JAVA_HOME" ]; then
    export PATH="$JAVA_HOME/bin:$PATH"
    echo -e "${CLR_GREEN}✓ Using Java: $(${JAVA_HOME}/bin/java -version 2>&1 | head -n 1)${CLR_RESET}"
else
    echo -e "${CLR_YELLOW}! Warning: JAVA_HOME is not set to JDK 21. Ensure JDK 21 is active.${CLR_RESET}"
fi

# Source base AOSP build envsetup if present
if [ -f "build/envsetup.sh" ]; then
    source build/envsetup.sh
fi

# Define Expressive Lunch Targets
function lunch_expressive() {
    local variant="${1:-userdebug}"
    echo -e "${CLR_CYAN}Setting target: expressive_pixel11-${variant}...${CLR_RESET}"
    export TARGET_PRODUCT="expressive_pixel11"
    export TARGET_BUILD_VARIANT="${variant}"
    export TARGET_BUILD_TYPE="release"
    
    # Privileged System Integration Flags
    export PRODUCT_SYSTEM_SERVER_COMPILER_FILTER="speed-profile"
    export PRODUCT_USE_DYNAMIC_PARTITIONS="true"
    export PRODUCT_RETROFIT_DYNAMIC_PARTITIONS="false"
    export BOARD_AVB_ENABLE="true"
    export EXPRESSIVE_BUILD="true"
    
    echo -e "${CLR_GREEN}✓ Environment ready for ${TARGET_PRODUCT}-${TARGET_BUILD_VARIANT}${CLR_RESET}"
}

# Aliases for quick building
alias lunch_pixel11="lunch_expressive user"
alias lunch_pixel11_debug="lunch_expressive userdebug"

function make_expressive() {
    local jobs=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 8)
    echo -e "${CLR_BOLD}${CLR_GREEN}Building ExpressiveOS target-files package with ${jobs} threads...${CLR_RESET}"
    m -j"${jobs}" target-files-package otatools
}

function package_expressive_release() {
    echo -e "${CLR_BOLD}${CLR_CYAN}Running ExpressiveOS Automated Release Pipeline...${CLR_RESET}"
    python3 build/release_pipeline.py --product pixel11 --channel "${1:-qa}"
}

echo -e "${CLR_GREEN}Functions loaded:${CLR_RESET}"
echo -e "  - ${CLR_BOLD}lunch_pixel11${CLR_RESET}        : Configure for production signed Pixel 11 release"
echo -e "  - ${CLR_BOLD}lunch_pixel11_debug${CLR_RESET}  : Configure for debuggable Pixel 11 development build"
echo -e "  - ${CLR_BOLD}make_expressive${CLR_RESET}      : Build platform target-files package"
echo -e "  - ${CLR_BOLD}package_expressive_release [qa|stable]${CLR_RESET} : Generate signed fastboot & OTA bundle"
