📱 **Evolution X 12.3 (Android 17) for Pixel 8 Pro (husky): 2026-10-23 update**

A fix release on top of the 2026-10-21 build.

**Fixed**
• **Scrolling stutter:** apps no longer stutter while the Dynamic Bar island is showing (timers, media, calls, screen recording). The island blurred everything behind it, which forced every frame of the app below through the GPU. It now uses a solid background, and scrolling stays smooth.
• **Locked apps in Recents:** apps you lock with App Lock now show only their icon in Recents instead of their last screen.
• **Kernel:** updated to 6.1.162 from the LineageOS husky kernel.

**Known issues**
• Gemini Nano features don't work (Google serves them only to phones with a locked bootloader).

📋 **Support policy, please read before reporting**
• **Custom setups get limited to no support.** That means root modules, Xposed/LSPosed, custom kernels, or apps from APKMirror and similar sites that don't match this build (Google system apps especially). Before you report, reproduce the problem on a clean install without them.
• **No logs, no report.** Bug reports without a logcat are flagged for deletion. Capture one right after the problem happens:
`adb logcat -b all -d > log.txt`
Then post it with your build date and steps to reproduce.

**Download**
• `EvolutionX-17.0-20261023-husky-12.3-Unofficial.zip`
• SHA-256: `4e4da0cb9fe0d1adfd2334578b4bbbf160719f0210b8359f75a65746f6253c73`
• Recovery images for clean installs: `boot-20261023.img`, `vendor_boot-20261023.img` (checksums in `recovery-20261023.sha256`)
• https://sourceforge.net/projects/denson9874-s-user-builds/files/husky/17/

**Updating from an earlier build (keeps data):** reboot to recovery > Apply update > Apply from ADB, then `adb sideload EvolutionX-17.0-20261023-husky-12.3-Unofficial.zip`, then reboot.
**Clean install:** flash `boot-20261023.img` and `vendor_boot-20261023.img`, boot recovery, format data, sideload the zip. Full steps are in the XDA thread.

Tested on a Pixel 8 Pro (October CP3A firmware) as an update from the 10-21 build: verified boot green, SELinux enforcing, Wi-Fi, Bluetooth, NFC, mobile data, both cameras, face and fingerprint, 56 sensors, 120/60 Hz; scrolling with the island showing stays on the display hardware (0 GPU-composited frames).
