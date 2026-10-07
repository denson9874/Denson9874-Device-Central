# ExpressiveOS — Android 17 for Pixel 11 Pro / XL

<div align="center">
  <img src="docs/assets/screenshots/logo.png" alt="ExpressiveOS Logo" width="128" />
  <h1>ExpressiveOS</h1>
  <p><strong>A customized, production-grade Android 17 operating system for Google Pixel 11 Pro and Pixel 11 Pro XL, infused with Material 3 Expressive design.</strong></p>

  <p>
    <a href="#major-features">Features</a> •
    <a href="#screenshots--gallery">Screenshots</a> •
    <a href="#installation-instructions">Installation</a> •
    <a href="#bootloader-locking--security">AVB 2.0 Locking</a> •
    <a href="#building-from-source">Building</a> •
    <a href="#release-channels">OTA Updates</a>
  </p>
</div>

---

## Overview

**ExpressiveOS** combines the clean stability, Tensor hardware optimization, and camera fidelity of Google's flagship Pixel firmware with the fluid design philosophy, system-level folder widgets, and rich personalization features pioneered by **Expressive Launcher**.

Rather than running as a third-party application with restricted privileges, **Expressive Launcher** is integrated directly into the AOSP platform as the primary, privileged **Recents, Taskbar, and Home provider** (`system_ext/priv-app/ExpressiveLauncherQuickstep`). This unlocks zero-latency gesture navigation, native overview actions, fluid app-to-home physics, and seamless system-wide customization.

---

## Screenshots & Gallery

*All screenshots below are actual, unedited captures taken directly from the Android 17 build running on the Pixel emulator.*

<div align="center">
  <table>
    <tr>
      <td width="50%" align="center">
        <h4>1. Expressive Desktop &amp; Folder Widget</h4>
        <img src="docs/assets/screenshots/01-home-screen.png" alt="Expressive Desktop" width="340" /><br />
        <em>Material 3 Expressive Home with in-process Folder Widget, At a Glance daily quote ("Make today a good story"), Clock widget, and Google dock search pill.</em>
      </td>
      <td width="50%" align="center">
        <h4>2. Floating Bottom Sheet App Drawer</h4>
        <img src="docs/assets/screenshots/04-app-drawer.png" alt="App Drawer" width="340" /><br />
        <em>Fluid bottom sheet app drawer with top pill handle, prediction row, search bar, and live wallpaper background blur.</em>
      </td>
    </tr>
    <tr>
      <td width="50%" align="center">
        <h4>3. Material 3 Expressive Quick Settings</h4>
        <img src="docs/assets/screenshots/03-quicksettings-blur.png" alt="Quick Settings & Blur" width="340" /><br />
        <em>Android 17 Quick Settings with 2x4 pill tiles, brightness slider, and real-time frosted glass wallpaper blur scrim.</em>
      </td>
      <td width="50%" align="center">
        <h4>4. Home &amp; System Customization Settings</h4>
        <img src="docs/assets/screenshots/02-customization-settings.png" alt="Customization Settings" width="340" /><br />
        <em>Comprehensive customization hub for icons, shapes, widgets, At a Glance, and gesture navigation.</em>
      </td>
    </tr>
    <tr>
      <td colspan="2" align="center">
        <h4>5. Deep Typography &amp; Appearance Controls</h4>
        <img src="docs/assets/screenshots/05-icons-appearance.png" alt="Icons and Appearance Settings" width="340" /><br />
        <em>System font engine featuring Google Sans Flex Variable typography, custom icon shapes, and dynamic Material You color themes.</em>
      </td>
    </tr>
  </table>
</div>

---

## Major Features

### 🌟 Privileged System Launcher (`ExpressiveLauncherQuickstep`)
* **Deep Quickstep Integration**: Expressive Launcher owns `TouchInteractionService` directly (`config_recentsComponentName`), delivering zero-latency full-screen gestural navigation.
* **Privileged Platform Permissions**: Whitelisted for `MANAGE_ACTIVITY_TASKS`, `STATUS_BAR_SERVICE`, `STOP_APP_SWITCHES`, and `READ_FRAME_BUFFER`.
* **Native Overview Screen**: Seamless Recents task carousel with instant action pills: **Screenshot**, **Select Text**, and **Split Screen**.
* **In-Process Folder Widgets**: Hank's model folder widgets with continuous edge drag-resizing, adaptive columns (2–6), custom corner radii, and geometry-aware open/close animations.
* **Presentation Modes**: Instant switching between edge-to-edge full-screen drawer and classic Pixel floating bottom sheet with top drag handle.

### 🎨 Material 3 Expressive SystemUI & Frameworks
* **Fluid QS Pill Tiles**: 28dp pill geometry with dynamic touch ripple morphing.
* **Real-Time Wallpaper Blur Scrim**: Compositor-level frosted glass backdrop blur in the notification shade, volume panel, and recents overview.
* **Expressive Hub**: A dedicated personalization suite built right into Android Settings (`Personalize > Expressive Hub`) backed by `Settings.Secure` for live, restart-free updates.
* **Lock Screen Typography**: Expressive clock styles including bundled Google Sans Flex variable typeface, Ink Display, and retro monospace.
* **Hybrid At a Glance Engine**: Bridges Google's official Pixel smart cards (weather, timer, flight, doorbell) with Expressive daily quotes and holiday greetings across Home, Lock Screen, and Always-On Display.

### 📱 100% Pixel 11 Pro / XL Hardware Parity
* **Tensor SoC Optimization**: Full hardware HAL integration for next-gen Tensor NPU, TPU, and GPU drivers.
* **120Hz LTPO Smooth Display**: Dynamic variable refresh rate scaling (1Hz–120Hz) with High Brightness Mode (HBM).
* **Pixel Camera Suite**: Bundled Google Camera with full HDR+, Night Sight, Cinematic Video, Macro Focus, and Ultra HDR capture.
* **Google Flagship Services**: Now Playing ambient music recognition, Pixel Recorder with on-device transcription, and Google Play Services out-of-the-box.

### 🔒 Enterprise Security & Play Integrity
* **SELinux Enforcing**: Zero permissive compromises; fully audited SELinux policy rules (`device/google/pixel11/sepolicy/`).
* **Android Verified Boot (AVB 2.0)**: Hardware-backed custom key enrollment support for Google's Titan M security chip.
* **Google Play Integrity**: Pre-configured to pass `MEETS_DEVICE_INTEGRITY`, guaranteeing that Google Wallet, PayPal, banking apps, and RCS work cleanly out-of-the-box.

---

## Installation Instructions

### Prerequisites
1. A **Google Pixel 11 Pro** or **Pixel 11 Pro XL**.
2. A computer with **Android SDK Platform-Tools (v35+)** installed (`adb` and `fastboot`).
3. High-speed USB-C to USB-C cable.
4. **OEM Unlocking** enabled in *Settings > System > Developer Options*.

---

### Method 1: WebUSB Fastboot Web Flasher (Recommended)

1. Open `tools/web_flasher/index.html` in **Google Chrome** or any WebUSB-compatible browser.
2. Reboot your Pixel 11 Pro / XL into **Bootloader Mode**:
   ```sh
   adb reboot bootloader
   ```
   *(Or power off, then hold **Power + Volume Down** until the fastboot screen appears).*
3. Click **Connect Device** and select your Pixel device in the browser prompt.
4. Click **Flash ExpressiveOS** to automatically flash all system partitions and reboot.

---

### Method 2: Fastboot Command Line Flashing

1. Download the latest ExpressiveOS Factory Image bundle (`image-expressive_pixel11-*.zip`).
2. Reboot into bootloader:
   ```sh
   adb reboot bootloader
   ```
3. Run the automated flash script:
   * **macOS / Linux**:
     ```sh
     chmod +x tools/flash_all/flash-all.sh
     ./tools/flash_all/flash-all.sh
     ```
   * **Windows**:
     ```cmd
     tools\flash_all\flash-all.bat
     ```
4. The device will automatically reboot into ExpressiveOS.

---

## Bootloader Locking & Security (AVB 2.0)

ExpressiveOS fully supports re-locking your bootloader with cryptographic Verified Boot active using custom AVB keys:

1. Connect your Pixel 11 Pro / XL in Bootloader mode.
2. Enroll the ExpressiveOS custom signing key into the Titan M security chip:
   ```sh
   ./tools/avb/enroll_avb_key.sh
   ```
   *(Internally runs `fastboot flashing set-custom-key vendor/expressive/keys/avb_custom_key.img`)*.
3. When prompted, select **Lock Bootloader** (`fastboot flashing lock`) and confirm on the phone's physical display.
4. The device will reboot with green/yellow verified boot state active, passing Google Play Integrity checks with a secure locked bootloader!

---

## Release Channels & OTA Updates

ExpressiveOS features seamless A/B background system updates with dual release tracks:

| Channel | Frequency | Stability | Update Feed |
| :--- | :--- | :--- | :--- |
| **QA / Beta** | Daily (03:00 ET) | Latest enhancements & experimental UI | `updates:qa-v2/latest.json` |
| **Stable** | Weekly (Saturdays) | Fully verified & weekly release gate passed | `updates:stable/latest.json` |

Updates download and install automatically in the background via Android's native `update_engine`. Switch channels anytime in **Settings > System > System Updates**.

---

## Building from Source

### 1. Initialize the Source Tree
```sh
mkdir ~/expressive_os && cd ~/expressive_os
repo init -u https://github.com/denson9874/ExpressiveOS.git -b main
repo sync -c -j$(nproc) --force-sync --no-clone-bundle --no-tags
```

### 2. Set Up the Build Environment
```sh
source build/envsetup_expressive.sh
lunch_pixel11        # For production signed release
# or
lunch_pixel11_debug  # For development userdebug build
```

### 3. Compile Platform Target Files
```sh
make_expressive
```

### 4. Run the Automated Release Pipeline
```sh
python3 build/release_pipeline.py --product pixel11 --channel qa
```
This generates:
* Fastboot factory bundle: `out/release/image-expressive_pixel11-1.0.0-qa.zip`
* Seamless A/B OTA package: `out/release/expressive_pixel11-ota-1.0.0-qa.zip`
* JSON Updater feed: `out/release/update_qa.json`

---

## Repository Structure

```
ExpressiveOS/
├── manifests/                      # AOSP & device repo manifests (default.xml, pixel11.xml)
├── build/                          # Build orchestration & release pipeline
│   ├── envsetup_expressive.sh      # Environment setup & lunch target script
│   └── release_pipeline.py         # Factory image & OTA payload packager
├── packages/apps/
│   ├── ExpressiveLauncher/         # Privileged system launcher (Android.bp, privapp XML)
│   ├── ExpressiveHub/              # System Settings personalization suite
│   └── ExpressiveUpdater/          # Seamless A/B OTA background updater
├── frameworks/base/
│   ├── core/res/res/values/        # Design tokens, 28dp pill geometry, ink-indigo colors
│   └── packages/SystemUI/          # QS pill tiles, blur scrim, and lockscreen clock
├── device/google/pixel11/          # Device tree, product makefiles & BoardConfig.mk
├── tools/
│   ├── avb/                        # AVB 2.0 key generator & Titan M enrollment
│   ├── flash_all/                  # Fastboot flash-all scripts (Bash & Batch)
│   └── web_flasher/                # WebUSB Fastboot web installer (Google Chrome)
└── docs/assets/screenshots/        # Real emulator screenshots & visual documentation
```

---

## License

* **Android Open Source Project (AOSP)** components are licensed under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).
* **Expressive Launcher** components are licensed under the GNU General Public License v3.0 (GPL-3.0).
* Proprietary Google Pixel binaries and vendor blobs are property of Google LLC.
