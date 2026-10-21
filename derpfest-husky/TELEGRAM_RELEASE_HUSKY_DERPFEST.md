📱 **DerpFest v17 (Android 17) for Pixel 8 Pro (husky): first build, 2026-10-21**

Unofficial build. husky's official DerpFest maintainer is Adrian Szymański (@Adi20_01), whose latest official build is v16.2. This brings Android 17 until an official v17 build is out. Please report bugs here, not to the DerpFest team.

**What's in it**
• DerpFest v17 on LineageOS 24.0, security patch 2026-10-01, user build signed with private keys, Google apps included
• Kernel 6.1.157 (LineageOS gs-6.1) and October firmware (CP3A.261005.005) included
• Built-in call recorder: BCR 3.11 by chenxiaolong. It's off until you turn it on, and it plays no beep, so the other party isn't told. Recording laws differ by country, so follow the rules where you and the other party are.
• OTA updates through the built-in Updater

**Known issues**
• Face unlock is DerpFest's camera-based one, not the Pixel's secure face unlock: use the fingerprint sensor for payments and app sign-in.
• Gemini Nano features that need Google's on-device models may not work (Google serves them only to phones with a locked bootloader).
• This is the first DerpFest build for husky: if something doesn't work, send a logcat (`adb logcat -b all -d > log.txt`) and your carrier.

**Download**
• `DerpFest-v17-20261021-husky-Unofficial-Stable.zip` (2.87 GB)
• SHA-256: `c2df9952802f89fb42e316d8126c51fb741083910de3227fd5d1699125ba635c`
• Recovery images: `boot-20261021.img`, `vendor_boot-20261021.img` (checksums in `recovery-20261021.sha256`)
• https://sourceforge.net/projects/denson9874-s-user-builds/files/derpfest/husky/

**Install (clean flash: DerpFest is its own ROM, so coming from any other ROM needs a clean install):** flash `boot-20261021.img` and `vendor_boot-20261021.img`, boot recovery, format data, then `adb sideload DerpFest-v17-20261021-husky-Unofficial-Stable.zip`. Full steps are in the XDA thread.
