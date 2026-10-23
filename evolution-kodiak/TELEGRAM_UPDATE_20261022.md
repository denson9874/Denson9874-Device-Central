🛠 **Evolution X for the Pixel 11 series: October 22 update**

New builds for the **Pixel 11 Pro XL (kodiak)**, **Pixel 11 Pro (grizzly)**, **Pixel 11 (cubs)** and **Pixel 11 Pro Fold (yogi)**: a fix release on top of the October 18 build.

🔄 **Already on the October 18 build?** Settings > System > System updates has this one; it installs in the background, then restart. Rooted? Use Magisk > Install > *Install to inactive slot (after OTA)* instead of restarting, or root is gone.

Fixed:
• Now Playing can be turned on again (it was stuck at "Setting up Now Playing")
• At a Glance: the individual options (Live Display and the rest) can be switched off again from the widget settings
• kodiak: SystemUI no longer restarts and drops you to the lock screen when you open Quick Settings right after a fingerprint unlock
• Every build is now checked before release for leftover apps and for association rules that differ from stock firmware, the two problems behind these bugs

Kernel: **Espada v3.5** (Linux 6.12.96) by Kevtrejo37 on kodiak, grizzly and cubs: reworked Simple LMK (fixes an lmkd crash), CASS picks little/mid cores by measured power, per-app uname spoof, USB OTG in recovery. yogi stays on stock Google GKI.

Also from upstream: Evolver redesigned in Material 3 Expressive, Launcher3 layout fix for display size settings, App Lock focus ring, Markup (Canvas) strokes stay inside the image.

Unchanged: Extreme Charging, the charging screensaver, "Use device MAC" for MAC-filtered Wi-Fi, and stock CD1A.261005.003 firmware (security patch 2026-10-05).

📋 **Support policy, please read before reporting**
• **Custom setups get limited to no support.** That means root modules, Xposed/LSPosed, any kernel other than Espada, or apps from APKMirror and similar sites that don't match this build (Google system apps especially). Before you report, reproduce the problem on a clean install without them.
• **No logs, no report.** Bug reports without a logcat are flagged for deletion. Capture one right after the problem happens:
`adb logcat -b all -d > log.txt` (or rooted: `su -c "logcat -b all -d > /sdcard/log.txt"`)
Then post it with your device, build date and steps to reproduce.

📱 **Pixel 11 Pro XL (kodiak)**: `EvolutionX-17.0-20261022-kodiak-12.3-Unofficial-fastboot.zip`
SHA-256: `337aaa1445f86a87e30d1e9839df7b55495cb16380445022dc4cbef649066bb3`

📱 **Pixel 11 Pro (grizzly)**: `EvolutionX-17.0-20261022-grizzly-12.3-Unofficial-fastboot.zip`
SHA-256: `789924328f45fcac15a35cb0b7b39816ced4e4742f00d0828c4fc6c906809f4b`

📱 **Pixel 11 (cubs)**: `EvolutionX-17.0-20261022-cubs-12.3-Unofficial-fastboot.zip`
SHA-256: `6df6e7ee0b7ba262e7d753ce94525c8e3b31725550edd282ec496419adccba0a`

📱 **Pixel 11 Pro Fold (yogi)**: `EvolutionX-17.0-20261022-yogi-12.3-Unofficial-fastboot.zip`
SHA-256: `dd943c89cd21d5a60f0d2d0e5e9f13dc70cacaee7ad4a33880ad481da5a6a1b1`

⬇️ SourceForge: https://sourceforge.net/projects/denson9874-s-user-builds/files/
💬 XDA: kodiak/grizzly https://xdaforums.com/t/4804712/ · cubs https://xdaforums.com/t/4804723/ · yogi https://xdaforums.com/t/4804826/
