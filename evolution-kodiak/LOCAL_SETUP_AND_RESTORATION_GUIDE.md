# ExpressiveOS / Evolution X: Fresh Mac Rebuild & Restoration Guide

This document provides complete instructions for restoring your development environment on a newly wiped Mac so you can pick back up immediately on ExpressiveOS and Evolution X for Pixel 11 Pro XL (`kodiak`) with both Claude Code and Google Antigravity.

---

## 1. Critical Pre-Erase Checklist (MUST DO BEFORE WIPING)

Before you erase your Mac, verify the following:

1. **Hetzner Build Server SSH Private Key (CRITICAL):**
   - Location: `~/.ssh/voltage_build_ed25519` and `~/.ssh/voltage_build_ed25519.pub`.
   - **Warning:** This key provides access to `build@157.180.50.152`. If you lose it, SSH access is broken until recovered via Hetzner Robot rescue console.
   - It is backed up to Google Drive under `My Drive/ExpressiveOS_Handoff_Backup/SSH_KEYS_BACKUP/`.
2. **Uncommitted Work in Other Projects:**
   - Check `/Users/daryldenson/Developer/ExpressiveLauncher`: Branch `codex/pixel-parity` has uncommitted modifications to taskbar, preferences, and wmshell files.
   - Check `/Users/daryldenson/Documents/Sermon Presenter`.
3. **Google Drive Sync:**
   - Verify that Google Drive (`daryldenson0405@gmail.com`) is finished syncing `ExpressiveOS_Handoff_Backup/`.

---

## 2. Infrastructure & Device Inventory

| Resource | Value / Path | Notes |
|---|---|---|
| **Build Server** | `157.180.50.152` | Hetzner Ryzen 7 7700 (16T, 64 GB RAM) |
| **Server User** | `build` | Account has no passwordless sudo |
| **Server Source** | `/home/build/evolution` | Android 17 (branch `cnb`) Evolution X source |
| **Server Device Tree** | `/home/build/android-dt/trees/device_google_kodiak` | Maintained in git |
| **GitHub Repo** | `https://github.com/denson9874/ExpressiveOS.git` | Private repository |
| **Key Branches** | `evolution/kodiak-port`, `claude/wizardly-hopper-gnqtlx` | Synced with local work |
| **Test Device** | Google Pixel 11 Pro XL (`kodiak`) | Serial `66020DLDV0049F`, bootloader unlocked, slot `b` |
| **Firmware Target** | `CD1A.261005.003` | Bootloader `spacecraft-17.4-16262255` |
| **Active ROM Build** | EvolutionX-17.0 (Android 17, `cnb`, v12.3) | Built with signed release-keys & Magisk v30.7 root |

---

## 3. Fresh Mac Installation Steps

### Step 1: Install Apple Command Line Tools
```bash
xcode-select --install
```

### Step 2: Install Homebrew
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv zsh)"
```

### Step 3: Install Core Command-Line Tools
```bash
brew install git gh rclone node python@3.14 openjdk@21 e2fsprogs sevenzip xz zstd
brew install --cask android-commandlinetools
```

### Step 4: Setup Android Platform-Tools (ADB & Fastboot)
1. Download official Google Android platform tools:
   ```bash
   mkdir -p ~/Library/Android/sdk
   curl -o /tmp/platform-tools.zip https://dl.google.com/android/repository/platform-tools-latest-darwin.zip
   unzip -q /tmp/platform-tools.zip -d ~/Library/Android/sdk/
   rm /tmp/platform-tools.zip
   ```
2. Configure shell environment in `~/.zshrc`:
   ```bash
   cat << 'EOF' >> ~/.zshrc
   # Homebrew environment
   eval "$(/opt/homebrew/bin/brew shellenv zsh)"

   # Android SDK command-line tools (ADB and Fastboot)
   export ANDROID_HOME="$HOME/Library/Android/sdk"
   export PATH="$ANDROID_HOME/platform-tools:$PATH"

   # Java / OpenJDK 21 (ARM64)
   export JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
   export PATH="/opt/homebrew/opt/openjdk@21/bin:$PATH"

   # Local user binaries & Python aliases
   export PATH="$HOME/.local/bin:$PATH"
   alias python="python3"
   EOF
   source ~/.zshrc
   ```
3. Test tool availability:
   ```bash
   adb --version
   fastboot --version
   ```

### Step 5: Restore SSH Key for Build Server
1. Download `voltage_build_ed25519` from Google Drive (`ExpressiveOS_Handoff_Backup/SSH_KEYS_BACKUP/`).
2. Move it to `~/.ssh/`:
   ```bash
   mkdir -p ~/.ssh && chmod 700 ~/.ssh
   # Copy voltage_build_ed25519 and voltage_build_ed25519.pub into ~/.ssh/
   chmod 600 ~/.ssh/voltage_build_ed25519
   chmod 644 ~/.ssh/voltage_build_ed25519.pub 2>/dev/null || true
   ```
3. Test connectivity to the Hetzner build server:
   ```bash
   ssh -i ~/.ssh/voltage_build_ed25519 -o StrictHostKeyChecking=accept-new build@157.180.50.152 "uname -a && uptime"
   ```

### Step 6: Authenticate GitHub & Git Configuration
```bash
gh auth login
git config --global user.name "Daryl Denson"
git config --global user.email "daryldenson0405@gmail.com"
git config --global init.defaultbranch main
git config --global pull.rebase true
```

### Step 7: Clone ExpressiveOS Repository
```bash
mkdir -p ~/Developer && cd ~/Developer
git clone https://github.com/denson9874/ExpressiveOS.git
cd ExpressiveOS
git checkout evolution/kodiak-port
```

### Step 8: Reinstall Claude Code CLI & Google Antigravity
1. **Claude Code CLI:**
   ```bash
   npm install -g @anthropic-ai/claude-code
   # Launch claude and authenticate
   claude
   ```
2. **Google Antigravity:**
   - Install the Google Antigravity IDE application on macOS.
   - Open workspace `/Users/daryldenson/Developer/ExpressiveOS`.

### Step 9: Setup Kodiak Flashing Directory & Scripts
```bash
mkdir -p ~/Downloads/kodiak-evox/aod-flash
cp ~/Developer/ExpressiveOS/evolution-kodiak/tools/flashing/*.sh ~/Downloads/kodiak-evox/aod-flash/
chmod +x ~/Downloads/kodiak-evox/aod-flash/*.sh
```

### Step 10: Fetch the Latest Kodiak ROM & Flash
The latest build with Extreme Charging Mode ("Bodega") and the SELinux fix is stored on the build server at `/tmp/kodiak-evox-img.zip`:
```bash
cd ~/Downloads/kodiak-evox
scp -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152:/tmp/kodiak-evox-img.zip EvolutionX-17.0-20261015-kodiak-12.3-Unofficial-personal-keep-initboot-bodega-sepolicy.zip
echo "71c192c34d21de3ca41519efcf46a11db029040a8461b8b0102cb455fee7bc63  EvolutionX-17.0-20261015-kodiak-12.3-Unofficial-personal-keep-initboot-bodega-sepolicy.zip" > EvolutionX-17.0-20261015-kodiak-12.3-Unofficial-personal-keep-initboot-bodega-sepolicy.zip.sha256
shasum -a 256 -c EvolutionX-17.0-20261015-kodiak-12.3-Unofficial-personal-keep-initboot-bodega-sepolicy.zip.sha256
```

To flash guarded (no-wipe, preserving user data):
```bash
cd ~/Downloads/kodiak-evox/aod-flash
fastboot update ../EvolutionX-17.0-20261015-kodiak-12.3-Unofficial-personal-keep-initboot-bodega-sepolicy.zip
```

---

## 4. Current State & Remaining Work Summary

1. **Kernel Review:** Submitted to Kevtrejo37 as Issue #1 on `atrejokm301/espada-kernel`.
2. **Release Notes:** Sunday 2026-10-18 release drafts (`TELEGRAM_UPDATE_20261018.md`, `XDA_UPDATE_20261018.bbcode`, `XDA_FIRSTPOST_EDITS_20261018.bbcode`) are complete and staged with Bodega details.
3. **Community Replies:** Pre-drafted in `evolution-kodiak/COMMUNITY_REPLIES_20261015.md` ready to post.
4. **Upstream Dreamliner PR:** Open at https://github.com/Evolution-X/vendor_gms/pull/2.
5. **Next Step Upon Return:** Connect `kodiak` via USB, flash the new image, verify Extreme Charging QS tile works with 0 AVC denials for `hal_power_default` on `sysfs_batteryinfo`.
