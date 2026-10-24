📱 **Evolution X 12.3 (Android 17) for Pixel 8 Pro (husky): 2026-10-21 update**

Unofficial build, synced with upstream Evolution X `cnb` and LineageOS on 2026-10-21.

**What's new**
• **Extreme Charging on husky:** the Quick Settings tile now works on the Pixel 8 Pro. Below 50% on a wired charger it relaxes the charge-temperature throttling so the phone keeps charging faster while you use it. It switches itself off when you unplug or reach 100%. The battery's own temperature protections are unchanged; expect the phone to run warmer while it's on.
• **Pixel face unlock:** face unlock now uses the Pixel 8 Pro's own face unlock (LineageOS device tree update). **If you used face unlock before, set it up again** in Settings > Security & privacy > Device unlock.
• **Faster first boot after updates:** SystemUI and Settings now ship precompiled, so they're fully optimized from the first boot instead of recompiling.
• **User build:** this is now a `user` build, like the Pixel 11 releases.
• **Upstream Evolution X:** SystemUI stops polling lockscreen widgets in the background and the Wi-Fi icon updates on events instead of polling; DynamicBar redesign; torch fixes for long-press power; App Lock, Settings and Evolver updates; latest LineageOS changes.

**Known issues**
• Notification shade animations can still drop frames on husky. I traced it to SystemUI's notification list layout and I'm working on it.
• Gemini Nano features don't work (Google serves them only to phones with a locked bootloader).

**Download**
• `EvolutionX-17.0-20261021-husky-12.3-Unofficial.zip`
• SHA-256: `3fcd713310bb9b1d1947fec588bef98931676f9edfc8e9fe6e746c85faa8f69b`
• Recovery images for clean installs: `boot-20261021.img`, `vendor_boot-20261021.img` (checksums in `recovery-20261021.sha256`)
• https://sourceforge.net/projects/denson9874-s-user-builds/files/husky/17/

**Updating from an earlier build (keeps data):** reboot to recovery > Apply update > Apply from ADB, then `adb sideload EvolutionX-17.0-20261021-husky-12.3-Unofficial.zip`, then reboot.
**Clean install:** flash `boot-20261021.img` and `vendor_boot-20261021.img`, boot recovery, format data, sideload the zip. Full steps are in the XDA thread.

Tested on my Pixel 8 Pro (October CP3A firmware) as an update from the 10-16 build: verified boot green, SELinux enforcing, Wi-Fi, Bluetooth, NFC, mobile data, both cameras, fingerprint, 43 sensors, 120/60 Hz.
