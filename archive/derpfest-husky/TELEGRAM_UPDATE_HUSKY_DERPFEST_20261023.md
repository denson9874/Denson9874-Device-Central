📱 **DerpFest v17 (Android 17) for Pixel 8 Pro (husky): 2026-10-23 update**

Unofficial build, separate from DerpFest's official husky builds. Please report bugs here, not to the DerpFest team.

🔄 **Already on the 2026-10-21 build?** The built-in Updater has this one (Settings > System > Updater). Rooted? Install Magisk (or KernelSU) to the inactive slot before rebooting, or root is gone.

**What's new**
• **Network access after restoring a backup:** apps restored from your Google backup during setup keep their Wi-Fi and mobile data. Some of them had their Network access setting turned off. If an app on the 10-21 build still has no connection, turn Network access back on in App info.
• **App Lock:** the Recents Screenshot and Lens buttons and split screen no longer show a locked app's last screen.
• **USB debugging is off by default again** and asks for authorization on your computer, as it should on a user build. The first build had it on without asking. If you use ADB, turn it on in Developer options and accept the prompt.
• **Play Integrity:** the experimental integrity spoofing layer from the first build is gone; DerpFest's own attestation handling is back. If an app that checks Play Integrity behaves differently, report it with a logcat.
• **Kernel 6.1.162** (LineageOS gs-6.1, android14-6.1-2026-03), built from source with the ROM.

**Known issues**
• Face unlock is DerpFest's camera-based one, not the Pixel's secure face unlock: use the fingerprint sensor for payments and app sign-in.
• Gemini Nano features that need Google's on-device models may not work (Google serves them only to phones with a locked bootloader).

📋 **Support policy, please read before reporting**
• **Custom setups get limited to no support.** That means root modules, Xposed/LSPosed, custom kernels, or apps from APKMirror and similar sites that don't match this build (Google system apps especially). Before you report, reproduce the problem on a clean install without them.
• **No logs, no report.** Bug reports without a logcat are flagged for deletion. Capture one right after the problem happens:
`adb logcat -b all -d > log.txt`
Then post it with your build date and steps to reproduce.

**Download**
• `DerpFest-v17-20261023-husky-Unofficial-Stable.zip` (2.87 GB)
• SHA-256: `ba6de368a3acfabc10890fb472212edf0c16af17424e13fdde5ffc395f448459`
• Recovery images: `boot-20261023.img`, `vendor_boot-20261023.img` (checksums in `recovery-20261023.sha256`)
• https://sourceforge.net/projects/denson9874-s-user-builds/files/derpfest/husky/

**Install (clean flash: DerpFest is its own ROM, so coming from any other ROM needs a clean install):** flash `boot-20261023.img` and `vendor_boot-20261023.img`, boot recovery, format data, then `adb sideload DerpFest-v17-20261023-husky-Unofficial-Stable.zip`. Full steps are in the XDA thread.
