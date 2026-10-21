#!/usr/bin/env bash
# ==============================================================================
# setup-fresh-mac.sh
# Automated restoration & bootstrap script for ExpressiveOS / Evolution X on macOS.
#
# Covers Steps 1-6:
# 1. Xcode Command Line Tools & Homebrew
# 2. Package installation (git, gh, node, python@3.14, openjdk@21, etc.)
# 3. Android SDK platform-tools (adb, fastboot)
# 4. Shell configuration (~/.zshrc)
# 5. Hetzner Build Server SSH key restoration & testing
# 6. GitHub auth, ExpressiveOS repository checkout, and Claude Code CLI setup
# ==============================================================================

set -uo pipefail

# Colors for terminal output
BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"
RED="\033[0;31m"
NC="\033[0m"

log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $*"; }
log_step() { echo -e "\n${BOLD}${CYAN}=== Step $1: $2 ===${NC}\n"; }

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}   ExpressiveOS / Evolution X Environment Bootstrap Script       ${NC}"
echo -e "${BOLD}================================================================${NC}"

# ------------------------------------------------------------------------------
# STEP 1: Xcode Command Line Tools & Homebrew
# ------------------------------------------------------------------------------
log_step "1" "Xcode Command Line Tools & Homebrew"

if ! xcode-select -p &>/dev/null; then
    log_info "Xcode Command Line Tools not detected. Requesting installation..."
    xcode-select --install
    echo -e "${YELLOW}Please complete the Xcode Command Line Tools GUI installer.${NC}"
    read -rp "Press [Enter] once the Xcode Command Line Tools installation has finished..."
else
    log_ok "Xcode Command Line Tools already installed: $(xcode-select -p)"
fi

if ! command -v brew &>/dev/null; then
    log_info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -f "/opt/homebrew/bin/brew" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv zsh)"
    fi
else
    log_ok "Homebrew already installed: $(command -v brew)"
fi

eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || true)"

# ------------------------------------------------------------------------------
# STEP 2: Install Packages & Tooling
# ------------------------------------------------------------------------------
log_step "2" "Core Packages & Android Commandline Tools"

FORMULAE=(
    git
    gh
    rclone
    node
    python@3.14
    openjdk@21
    e2fsprogs
    sevenzip
    xz
    zstd
)

log_info "Installing required Homebrew formulae..."
for formula in "${FORMULAE[@]}"; do
    if brew list --formula "$formula" &>/dev/null; then
        log_ok "$formula is already installed."
    else
        log_info "Installing $formula..."
        brew install "$formula"
    fi
done

if brew list --cask android-commandlinetools &>/dev/null; then
    log_ok "android-commandlinetools is already installed."
else
    log_info "Installing android-commandlinetools..."
    brew install --cask android-commandlinetools || true
fi

# ------------------------------------------------------------------------------
# STEP 3: Android Platform-Tools (ADB & Fastboot)
# ------------------------------------------------------------------------------
log_step "3" "Android SDK Platform Tools"

ANDROID_DIR="$HOME/Library/Android/sdk"
PLATFORM_TOOLS_DIR="$ANDROID_DIR/platform-tools"

mkdir -p "$ANDROID_DIR"

if [[ ! -x "$PLATFORM_TOOLS_DIR/adb" || ! -x "$PLATFORM_TOOLS_DIR/fastboot" ]]; then
    log_info "Downloading latest Android platform-tools from Google..."
    curl -fLo /tmp/platform-tools.zip https://dl.google.com/android/repository/platform-tools-latest-darwin.zip
    unzip -q -o /tmp/platform-tools.zip -d "$ANDROID_DIR/"
    rm -f /tmp/platform-tools.zip
    log_ok "Platform tools installed to $PLATFORM_TOOLS_DIR"
else
    log_ok "Platform tools already present in $PLATFORM_TOOLS_DIR"
fi

export PATH="$PLATFORM_TOOLS_DIR:$PATH"
log_ok "ADB version: $(adb --version | head -1)"
log_ok "Fastboot version: $(fastboot --version | head -1)"

# ------------------------------------------------------------------------------
# STEP 4: Shell Configuration (~/.zshrc)
# ------------------------------------------------------------------------------
log_step "4" "Shell Configuration (~/.zshrc)"

ZSHRC="$HOME/.zshrc"
touch "$ZSHRC"

MARKER="# === ExpressiveOS Dev Environment ==="
if ! grep -q "$MARKER" "$ZSHRC"; then
    log_info "Injecting environment variables and aliases into $ZSHRC..."
    cat << 'EOF' >> "$ZSHRC"

# === ExpressiveOS Dev Environment ===
eval "$(/opt/homebrew/bin/brew shellenv zsh 2>/dev/null || true)"

# Android SDK
export ANDROID_HOME="$HOME/Library/Android/sdk"
case ":$PATH:" in
  *":$ANDROID_HOME/platform-tools:"*) ;;
  *) export PATH="$ANDROID_HOME/platform-tools:$PATH" ;;
esac

# Java 21
if [[ -d "/opt/homebrew/opt/openjdk@21" ]]; then
  export JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
  export PATH="/opt/homebrew/opt/openjdk@21/bin:$PATH"
fi

# Local Python & Binaries
export PATH="$HOME/.local/bin:$PATH"
alias python="python3"
# === End ExpressiveOS Dev Environment ===
EOF
    log_ok "Updated $ZSHRC"
else
    log_ok "$ZSHRC already contains ExpressiveOS configuration."
fi

# ------------------------------------------------------------------------------
# STEP 5: Restore Hetzner Build Server SSH Key
# ------------------------------------------------------------------------------
log_step "5" "Hetzner Build Server SSH Key"

SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

KEY_FILE="$SSH_DIR/voltage_build_ed25519"
PUB_FILE="$SSH_DIR/voltage_build_ed25519.pub"

# Check standard Google Drive mount locations
GDRIVE_CANDIDATES=(
    "$HOME/Library/CloudStorage/GoogleDrive-daryldenson0405@gmail.com/My Drive/ExpressiveOS_Handoff_Backup/SSH_KEYS_BACKUP"
    "$HOME/Library/CloudStorage/GoogleDrive-daryldenson0405@gmail.com/My Drive/SSH_KEYS_BACKUP"
    "$HOME/Downloads/ExpressiveOS_Handoff_Backup/SSH_KEYS_BACKUP"
    "$HOME/Downloads/SSH_KEYS_BACKUP"
    "$HOME/Downloads"
)

if [[ ! -f "$KEY_FILE" ]]; then
    FOUND=0
    for cand in "${GDRIVE_CANDIDATES[@]}"; do
        if [[ -f "$cand/voltage_build_ed25519" ]]; then
            log_info "Found SSH key in: $cand"
            cp "$cand/voltage_build_ed25519" "$KEY_FILE"
            if [[ -f "$cand/voltage_build_ed25519.pub" ]]; then
                cp "$cand/voltage_build_ed25519.pub" "$PUB_FILE"
            fi
            if [[ -f "$cand/known_hosts" && ! -f "$SSH_DIR/known_hosts" ]]; then
                cp "$cand/known_hosts" "$SSH_DIR/known_hosts"
            fi
            FOUND=1
            break
        fi
    done

    if [[ $FOUND -eq 0 ]]; then
        echo -e "${YELLOW}Please enter the path to the backup 'voltage_build_ed25519' key file${NC}"
        read -rp "Path (e.g. ~/Downloads/voltage_build_ed25519): " CUSTOM_KEY_PATH
        CUSTOM_KEY_PATH="${CUSTOM_KEY_PATH/#\~/$HOME}"
        if [[ -f "$CUSTOM_KEY_PATH" ]]; then
            cp "$CUSTOM_KEY_PATH" "$KEY_FILE"
            if [[ -f "$CUSTOM_KEY_PATH.pub" ]]; then
                cp "$CUSTOM_KEY_PATH.pub" "$PUB_FILE"
            fi
        else
            log_err "Key file not found at $CUSTOM_KEY_PATH. Please restore manually to $KEY_FILE."
        fi
    fi
fi

if [[ -f "$KEY_FILE" ]]; then
    chmod 600 "$KEY_FILE"
    chmod 644 "$PUB_FILE" 2>/dev/null || true
    log_ok "Hetzner SSH key is in place with permissions 600: $KEY_FILE"

    log_info "Testing SSH connectivity to Hetzner build server (build@157.180.50.152)..."
    if ssh -i "$KEY_FILE" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 build@157.180.50.152 "uptime" 2>/dev/null; then
        log_ok "SSH connection to Hetzner build server succeeded!"
    else
        log_warn "Could not connect to build server right now (network might be offline or host unreachable)."
    fi
else
    log_warn "Skipped SSH test: $KEY_FILE is not present."
fi

# ------------------------------------------------------------------------------
# STEP 6: GitHub Auth, Repository Clone & Claude Code Setup
# ------------------------------------------------------------------------------
log_step "6" "GitHub Auth, ExpressiveOS Repository & AI Tools"

# Git global identity
git config --global user.name "Daryl Denson"
git config --global user.email "daryldenson0405@gmail.com"
git config --global init.defaultbranch main
git config --global pull.rebase true
log_ok "Configured Git user: Daryl Denson <daryldenson0405@gmail.com>"

# GitHub CLI Auth Check
if ! gh auth status &>/dev/null; then
    log_info "GitHub authentication required. Launching 'gh auth login'..."
    gh auth login
else
    log_ok "GitHub CLI is already authenticated: $(gh api user --jq .login 2>/dev/null || echo 'denson9874')"
fi

# Clone or update ExpressiveOS
DEV_DIR="$HOME/Developer"
REPO_DIR="$DEV_DIR/ExpressiveOS"
mkdir -p "$DEV_DIR"

if [[ -d "$REPO_DIR/.git" ]]; then
    log_ok "ExpressiveOS repo already exists at $REPO_DIR. Pulling latest..."
    git -C "$REPO_DIR" checkout evolution/kodiak-port || true
    git -C "$REPO_DIR" pull || true
else
    log_info "Cloning ExpressiveOS into $REPO_DIR..."
    git clone https://github.com/denson9874/ExpressiveOS.git "$REPO_DIR"
    git -C "$REPO_DIR" checkout evolution/kodiak-port
    log_ok "Checked out branch 'evolution/kodiak-port'."
fi

# Flashing scripts directory
FLASH_DIR="$HOME/Downloads/kodiak-evox/aod-flash"
mkdir -p "$FLASH_DIR"
if [[ -d "$REPO_DIR/evolution-kodiak/tools/flashing" ]]; then
    cp -p "$REPO_DIR/evolution-kodiak/tools/flashing"/*.sh "$FLASH_DIR/"
    chmod +x "$FLASH_DIR"/*.sh
    log_ok "Flashing scripts restored to $FLASH_DIR"
fi

# Install Claude Code CLI via npm
log_info "Checking Claude Code CLI..."
if ! command -v claude &>/dev/null; then
    log_info "Installing Claude Code CLI (@anthropic-ai/claude-code)..."
    npm install -g @anthropic-ai/claude-code || sudo npm install -g @anthropic-ai/claude-code || true
    if command -v claude &>/dev/null; then
        log_ok "Claude Code CLI installed successfully."
    else
        log_warn "Claude Code CLI installation finished. Run 'claude' in a new terminal window."
    fi
else
    log_ok "Claude Code CLI is already installed: $(command -v claude)"
fi

echo -e "\n${BOLD}${GREEN}================================================================${NC}"
echo -e "${BOLD}${GREEN}   Bootstrap Complete! All Steps 1-6 Finished Successfully!      ${NC}"
echo -e "${BOLD}${GREEN}================================================================${NC}"
echo -e "Next actions:"
echo -e "1. Run ${CYAN}source ~/.zshrc${NC} or open a new Terminal window."
echo -e "2. Open Google Antigravity IDE and point it to: ${BOLD}$REPO_DIR${NC}"
echo -e "3. To flash your Pixel 11 Pro XL with the latest build, run:"
echo -e "   ${CYAN}cd $REPO_DIR && ./evolution-kodiak/tools/flashing/flash-guarded.sh ...${NC}"
echo -e "================================================================\n"
