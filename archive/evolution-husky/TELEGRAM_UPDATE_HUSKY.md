📱 **Evolution X 12.3 (Android 17) for Google Pixel 8 Pro (husky) — Unofficial Parity Update**

New unofficial build of **Evolution X 17 (Android 17)** for the **Google Pixel 8 Pro (`husky`)**, brought into full parity with the upstream Evolution X `cnb` build sources.

> ℹ️ **Maintainer Note:** Because there is an active official maintainer for Android 16 Evolution X (Giovanni / TechPanelGM), this build will remain an **Unofficial** community release. I (@daryldenson) am hosting and maintaining the Android 17 builds as the unofficial maintainer so Pixel 8 Pro users can experience Android 17 with the full Evolution X feature set.

---

### ✨ Highlights & Upstream `cnb` Parity
* **Evolution X 12.3 (Android 17):** Latest upstream source parity with `Evolution-X/manifest` (`cnb` branch).
* **Material 3 Expressive Personalization:** Full Evolver customization suite (Status bar, Quick Settings blur scrim, lock screen styles, animations, and gesture navigation).
* **Google Photos Tensor Chip Detection Fix:** Photo Unblur, Magic Eraser, and Ultra HDR processing correctly identified on Tensor G3.
* **Play Integrity & Security:** Hardened PIF integration for CTS/Integrity passing out of the box; locked QS tiles protected on secure lockscreen.
* **Pixel Parity & GMS:** Latest GMS system packages and Pixel-style system overlays integrated cleanly with artifact-path rules.
* **Firmware Baseline:** Shipped against and verified with **CP3A.261005.005** (October 2026 bootloader `ripcurrent-17.0-15681527` and modem `g5300i-260604-260807-B-16036236`).

---

### 🔍 Hardware Verification Status (Tested Live on Physical Pixel 8 Pro)
* **Boot:** Boots cleanly on slot `_b`, green AVB verified boot status, Linux 6.1.157 kernel.
* **Display:** 120 Hz / 60 Hz LTPO dynamic switching, HDR10+, smooth touch response.
* **Biometrics:** Under-display optical fingerprint scanner and Face Unlock working seamlessly.
* **Cameras:** Dual camera pipelines fully functional; Google Camera / Pixel Camera with full HDR+ support.
* **Connectivity:** Wi-Fi, Bluetooth audio/LE, NFC payments, GPS / GNSS, and all 43 hardware sensors verified.
* **SELinux:** Enforcing build (`userdebug`).

---

### 📦 Download & Package Details
* **Build Target:** `EvolutionX-17.0-20261016-husky-12.3-Unofficial.zip`
* **File Size:** 2.89 GB (3,106,951,124 bytes)
* **SHA-256 Checksum:** `2f8b568b06d16bba312ce05b2b3471689bd3fae7ed608309491246ba712d6d78`
* **Download Directory:** https://sourceforge.net/projects/denson9874-s-user-builds/files/husky/17/

---

### 📲 Installation Instructions

#### Clean Install (Coming from Stock or Another ROM)
1. Ensure your device is on **CP3A.261005.005** (October 2026) firmware.
2. Reboot to bootloader:
   `adb reboot bootloader`
3. Flash the Evolution X recovery boot images:
   `fastboot flash boot boot.img`
   `fastboot flash vendor_boot vendor_boot.img`
4. Reboot into recovery:
   `fastboot reboot recovery`
5. In Recovery: select **Factory Reset** > **Format data/factory reset**.
6. Select **Apply update** > **Apply from ADB**:
   `adb sideload EvolutionX-17.0-20261016-husky-12.3-Unofficial.zip`
7. Once installation completes, select **Reboot system now**.

#### Dirty Flash / Update (Coming from Previous Unofficial Evo X 17 Build)
1. Reboot to recovery.
2. Select **Apply update** > **Apply from ADB**:
   `adb sideload EvolutionX-17.0-20261016-husky-12.3-Unofficial.zip`
3. (Optional) If rooted, re-flash your root solution (Magisk / KernelSU).
4. Reboot system. Your data and settings are preserved!

---

### 🙏 Credits & Acknowledgments
* **The Evolution X Team:** Joey Huab, RealAkito, and AnierinB for the ROM and platform trees.
* **Giovanni (TechPanelGM):** For his dedicated work on official A16 husky trees.
* **The LineageOS Project & TheMuppets:** For the solid A17 device tree foundation and vendor blobs.
* **ExpressiveOS Community:** For continuous testing and feedback.
