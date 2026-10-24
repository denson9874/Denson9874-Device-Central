🛠 **Evolution X 12.3 (Android 17): October 24 update for every device**

New builds for the **Pixel 11 Pro XL (kodiak)**, **Pixel 11 Pro (grizzly)**, **Pixel 11 (cubs)**, **Pixel 11 Pro Fold (yogi)** and **Pixel 8 Pro (husky)**, and the first public build for the **Pixel 7 Pro (cheetah)**. All six get later updates through Settings > System > System updates (Pixel 8 Pro after one sideload of this build; Pixel 7 Pro after a clean install).

**Every device**
• **Smoother after updates** (Pixel 11 series and Pixel 7 Pro; Pixel 8 Pro since 10-21): preinstalled apps (Settings and the rest) keep their precompiled code when you install an update, instead of running slowly until the phone recompiled them overnight
• **Battery:** an open floating window no longer keeps the modem in its screen-on mode while the phone sleeps

**Pixel 11 series:** this build adds the two fixes above to this morning's update (face unlock setup, App Lock in Recents, Dynamic Bar stutter, NFC payments page, USB IDs, yogi fold posture); nothing else changed.

**Pixel 8 Pro (husky) and Pixel 7 Pro (cheetah)**
• **NFC payments:** the Contactless payments settings page that apps such as Google Wallet open loads again (it pointed at a page that no longer exists)
• **October vendor update:** vendor security patch 2026-10-05 (was August on husky, July on cheetah), matching the October firmware
• **Updates in Settings:** husky asked Evolution X's own servers, which have no husky builds, so it never found an update. This build points at our update server. **Sideload this one once**; later builds arrive in System updates
• **Adaptive Connectivity (SCONE)** no longer crashes in the background (it was missing its system permissions)
• **PIN asked twice** after a reboot: Play services no longer prepares Google's OTAs, which armed resume-on-reboot (the same change as on the Pixel 11 builds)
• **Private Compute Services** isn't cut off from the apps that use it anymore (a leftover LineageOS restriction that stock dropped)
• Stock Pixel settings that were missing: the screenshot Edit button opens Markup, Quick Share copy, the Files button, Google Photos in the photo picker, faster camera launch, stock Wi-Fi switching thresholds on 5 GHz, Google Home in device controls
• NFC is on after a clean install, as on stock; Restart SystemUI is in husky's advanced reboot menu
• Known issue (husky): the Extreme Charging tile shows but has no effect yet

🔄 **How to update**
• **Pixel 11 phones:** System updates has it; it installs in the background, then restart
• **Pixel 8 Pro:** this one by sideload (recovery > Apply update > Apply from ADB, `adb sideload EvolutionX-17.0-20261024-husky-12.3-Unofficial.zip`), keeps your data; then System updates from the next build on
• **Pixel 7 Pro:** first public build, clean install: `fastboot -w update EvolutionX-17.0-20261024-cheetah-12.3-Unofficial-fastboot.zip` on the newest stock Android 17 firmware (CP3A.261005.002.A1)
• Rooted, updating through System updates (Pixel 11 now, Pixel 8 Pro and Pixel 7 Pro from the next build)? Before restarting, Magisk > Install > *Install to inactive slot (after OTA)*, or root is gone. Pixel 8 Pro sideload: patch the new boot image with Magisk again afterwards. KernelSU-Next / SuSFS on kodiak, grizzly and cubs: flash Espada's KSU zip (v3.5) again afterwards

Tested before release: Pixel 8 Pro (sideloaded over 10-23, data kept): boots, PIN unlock, fingerprints kept, T-Mobile in service on 5G SA with Wi-Fi calling, Wi-Fi, Adaptive Connectivity no longer crashing, Private Compute Services, precompiled Settings, stock settings values, NFC on, update server. Pixel 7 Pro (OTA from 10-22): boots, T-Mobile eSIM in service on 5G SA, Wi-Fi, Adaptive Connectivity, precompiled apps, stock settings values, update server. No crashes on either. The Pixel 11 builds pass the build and OTA checks; they weren't booted before release.

Kernel: **Espada v3.5** (Linux 6.12.96) on kodiak, grizzly and cubs; stock GKI on yogi; Linux 6.1 (Google's GKI with LineageOS's device modules) on husky and cheetah.

📋 **Support policy:** custom setups (root modules, Xposed/LSPosed, kernels other than Espada, mismatched APKMirror apps) get limited to no support, and bug reports without a logcat are flagged for deletion:
`adb logcat -b all -d > log.txt` (or rooted: `su -c "logcat -b all -d > /sdcard/log.txt"`)

📱 **Pixel 11 Pro XL (kodiak):** `EvolutionX-17.0-20261024-kodiak-12.3-Unofficial-r2-fastboot.zip`
SHA-256: `361ae0d47d714470511b236b5190f67cb8cde290d74a575861257b952318214d`
📱 **Pixel 11 Pro (grizzly):** `EvolutionX-17.0-20261024-grizzly-12.3-Unofficial-r3-fastboot.zip`
SHA-256: `566a32da0d27ca861f136a6abecae6c71eab2e20d0a15495085c774b4f8c1509`
📱 **Pixel 11 (cubs):** `EvolutionX-17.0-20261024-cubs-12.3-Unofficial-r3-fastboot.zip`
SHA-256: `923e02bc28db877b15010ac537f4b5480839770be0c54a716930fff74865da70`
📱 **Pixel 11 Pro Fold (yogi):** `EvolutionX-17.0-20261024-yogi-12.3-Unofficial-r3-fastboot.zip`
SHA-256: `d3fec1a2527f2d90daf1e5423509d64ba47a9d56e5a7a9dcfd7c0e196c402583`
📱 **Pixel 8 Pro (husky):** `EvolutionX-17.0-20261024-husky-12.3-Unofficial.zip`
SHA-256: `c8e796077b4ea05ff14fb0d7f6f640c219c0cdf6a5e20ed499eff7691e990018` · recovery images `boot-20261024.img`, `vendor_boot-20261024.img`
📱 **Pixel 7 Pro (cheetah):** `EvolutionX-17.0-20261024-cheetah-12.3-Unofficial-fastboot.zip`
SHA-256: `50876b295841954b9f0e22ba617f1f4c9b78169949ab0e74fe62a293de7f6eaf`

⬇️ SourceForge: https://sourceforge.net/projects/denson9874-s-user-builds/files/
💬 XDA: kodiak/grizzly https://xdaforums.com/t/4804712/ · cubs https://xdaforums.com/t/4804723/ · yogi https://xdaforums.com/t/4804826/ · husky https://xdaforums.com/t/4805239/ · cheetah https://xdaforums.com/t/4806248/
