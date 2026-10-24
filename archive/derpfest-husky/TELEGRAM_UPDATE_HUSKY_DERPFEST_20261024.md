📱 **DerpFest v17 (Android 17) for Pixel 8 Pro (husky): 2026-10-24 update**

Unofficial build, separate from DerpFest's official husky builds. Please report bugs here, not to the DerpFest team.

🔄 **Already on an earlier build?** The built-in Updater has this one (Settings > System > Updater). Rooted? Install Magisk (or KernelSU) to the inactive slot before rebooting, or root is gone.

**What's new**
• **Smoother after updates:** preinstalled apps (SystemUI, Settings and the rest) now keep their precompiled code when you install an update, instead of running slowly until the phone recompiled them overnight
• **NFC payments:** the Contactless payments settings page that apps such as Google Wallet open loads again (it pointed at a page that no longer exists). In Settings it's under Connected devices > Connection preferences > NFC
• **PIN asked twice after a reboot** (reported on Evolution X): Play services' resume-on-reboot service is now off here too, the same change as Evolution X. If you still get asked twice, report it with a logcat
• **Private Compute Services** isn't cut off from the apps that use it anymore (a leftover LineageOS restriction that stock dropped)
• NFC is on after a clean install, as on stock; SystemUI is kept in memory (it pointed at a file that doesn't exist)

**Known issues**
• Face unlock is DerpFest's camera-based one, not the Pixel's secure face unlock: use the fingerprint sensor for payments and app sign-in.
• Gemini Nano features that need Google's on-device models may not work (Google serves them only to phones with a locked bootloader).

📋 **Support policy, please read before reporting**
• **Custom setups get limited to no support.** That means root modules, Xposed/LSPosed, custom kernels, or apps from APKMirror and similar sites that don't match this build (Google system apps especially). Before you report, reproduce the problem on a clean install without them.
• **No logs, no report.** Bug reports without a logcat are flagged for deletion. Capture one right after the problem happens:
`adb logcat -b all -d > log.txt`
Then post it with your build date and steps to reproduce.

**Download**
• `DerpFest-v17-20261024-husky-Unofficial-Stable.zip` (2.94 GB)
• SHA-256: `f5a59020f4b17bc56a55bf7792501885b71035b78dd0340e2b59735cf192eae1`
• Recovery images: `boot-20261024.img`, `vendor_boot-20261024.img` (checksums in `recovery-20261024.sha256`)
• https://sourceforge.net/projects/denson9874-s-user-builds/files/derpfest/husky/

**Install (clean flash: DerpFest is its own ROM, so coming from any other ROM needs a clean install):** flash `boot-20261024.img` and `vendor_boot-20261024.img`, boot recovery, format data, then `adb sideload DerpFest-v17-20261024-husky-Unofficial-Stable.zip`. Full steps are in the XDA thread.
