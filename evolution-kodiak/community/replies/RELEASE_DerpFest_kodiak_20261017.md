# DerpFest KODIAK Release Announcement (20261017)

## XDA BBCode
```bbcode
[CENTER][SIZE=5][B]New Update: DerpFest v17 for Google Pixel 11 Pro XL (kodiak)[/B][/SIZE]
[B]Build Date:[/B] 2026-10-17 | [B]Android Version:[/B] 17 (Vanilla Ice Cream / DP)
[B]Security Patch Level:[/B] 2026-10-05 | [B]SELinux:[/B] Enforcing[/CENTER]

[HR][/HR]

[SIZE=4][B]Package Downloads & Checksums:[/B][/SIZE]
[LIST]
[*] [B]Fastboot Factory Zip (Recommended Clean Flash):[/B]
[ICODE]DerpFest-v17-20261017-kodiak-Unofficial-fastboot.zip[/ICODE] (4614.9 MB)
[B]SHA-256:[/B] [ICODE]6c4f2258013f188aebc2928aa0fb4394a7d454e1a9d8cf92f002c8dc13606f47[/ICODE]

[*] [B]Recovery A/B OTA Package (Dirty Flash / Sideload):[/B]
[ICODE]DerpFest-v17-20261017-kodiak-Unofficial-Stable.zip[/ICODE] (3275.4 MB)
[B]SHA-256:[/B] [ICODE]9504873b77a40a3633ee5474c79db62c6b91a11ad073c39e38d96426d86ed13e[/ICODE]
[/LIST]

[SIZE=3][B]Direct Drive Folder:[/B] Available under Google Drive [ICODE]DerpFest/kodiak/[/ICODE][/SIZE]

[HR][/HR]

[SIZE=4][B]Community Fixes & Reporter Credits:[/B][/SIZE]
[LIST]
[*] [B][ICODE]ISS-20261012-01[/ICODE][/B] [Bug] Screen timeout to AOD flashes ~121 nits before dimming to 0.5 nits (Reported by: [I]TG: Ashray V K[/I])
[*] [B][ICODE]ISS-20261012-02[/ICODE][/B] [Support] PIN prompt appears twice after reboot; diagnosed as Play Services update arming "resume on reboot" (Reported by: [I]TG: Ashray V K[/I])
[*] [B][ICODE]ISS-20261013-01[/ICODE][/B] [Bug / Mod] Morphe patcher fails with ENOENT looking for `/system/framework/org.lineageos.platform-res.apk` due to SuSFS hiding (Reported by: [I]TG: Ashray V K[/I])
[*] [B][ICODE]ISS-20261015-01[/ICODE][/B] [Feature] Extreme Charging Mode ("Bodega") with Quick Settings tile for 30W+ fast charging (Reported by: [I]TG: Ashray V K[/I])
[*] [B][ICODE]ISS-20261015-03[/ICODE][/B] [Support] Flashing stuck on `< waiting for any device >` due to missing fastboot driver / USB-C hub (Reported by: [I]XDA: xerel89 (Post #22)[/I])
[/LIST]

[SIZE=4][B]Highlights & Changelog:[/B][/SIZE]
[LIST]
[*] Android 17 stable source rebase with complete Pixel hardware integration
[*] Clean SEPolicy compilation passing 100% against stock vendor policy
[*] Espada Kernel v3 integration with CASS scheduler and Simple LMK
[*] Full VoLTE/VoNR telephony and MediaTek T900 modem stabilization

[/LIST]

[HR][/HR]

[SIZE=4][B]Flashing Instructions (Fastboot Update):[/B][/SIZE]
[CODE]
# 1. Reboot device to bootloader
adb reboot bootloader

# 2. Verify connection
fastboot devices

# 3. Flash update (use -w for clean install)
fastboot update DerpFest-v17-20261017-kodiak-Unofficial-fastboot.zip
[/CODE]

[HR][/HR]

[SIZE=3][B]Special Thanks & Credits:[/B][/SIZE]
[LIST]
[*] [B]Kevtrejo37[/B] for the Espada Kernel ([URL="https://xdaforums.com/t/4799975/"]XDA Thread[/URL] | [URL="https://t.me/+DJmYe5_dfmwyODUx"]Telegram[/URL] | [URL="https://github.com/atrejokm301/espada-kernel"]GitHub[/URL])
[*] [B]Sultan Alsawaf[/B] for CASS and Simple LMK optimizations
[*] [B]The GrapheneOS Project[/B] for zram and memory management upstream patches
[*] The [B]DerpFest[/B] team and our community testers on Telegram & XDA
[/LIST]
```

## Telegram Markdown
```markdown
🚀 **New Update Released: DerpFest v17**
📱 **Device:** Google Pixel 11 Pro XL (`kodiak`)
📅 **Date:** 2026-10-17 | **Android 17** | **SELinux Enforcing**

---

📦 **Downloads & Hashes:**
• **Fastboot Zip:** `DerpFest-v17-20261017-kodiak-Unofficial-fastboot.zip` (4614.9 MB)
  `SHA-256: 6c4f2258013f188aebc2928aa0fb4394a7d454e1a9d8cf92f002c8dc13606f47`
• **OTA Sideload Zip:** `DerpFest-v17-20261017-kodiak-Unofficial-Stable.zip` (3275.4 MB)
  `SHA-256: 9504873b77a40a3633ee5474c79db62c6b91a11ad073c39e38d96426d86ed13e`

💾 *Synced directly to Google Drive folder:* `DerpFest/kodiak/`

---

**Community Fixes & Acknowledgments:**
• `ISS-20261012-01` Screen timeout to AOD flashes ~121 nits before dimming to 0.5 nits (thanks TG: Ashray V K)
• `ISS-20261012-02` PIN prompt appears twice after reboot; diagnosed as Play Services update arming "resume on reboot" (thanks TG: Ashray V K)
• `ISS-20261013-01` Morphe patcher fails with ENOENT looking for `/system/framework/org.lineageos.platform-res.apk` due to SuSFS hiding (thanks TG: Ashray V K)
• `ISS-20261015-01` Extreme Charging Mode ("Bodega") with Quick Settings tile for 30W+ fast charging (thanks TG: Ashray V K)
• `ISS-20261015-03` Flashing stuck on `< waiting for any device >` due to missing fastboot driver / USB-C hub (thanks XDA: xerel89 (Post #22))

✨ **Highlights:**
• Rebased on Android 17 with full Pixel 11 hardware features
• Zero SEPolicy denials against stock vendor
• Espada Kernel v3 (CASS scheduler & Simple LMK)
• High-speed charging & VoLTE/VoNR fully stabilized


---

⚡ **Fastboot Flashing:**
```bash
adb reboot bootloader
fastboot devices
fastboot update `DerpFest-v17-20261017-kodiak-Unofficial-fastboot.zip`
```

🙏 **Credits:**
• **Kevtrejo37** for the Espada Kernel ([XDA Thread](https://xdaforums.com/t/4799975/) | [Telegram](https://t.me/+DJmYe5_dfmwyODUx))
• **Sultan Alsawaf** & **The GrapheneOS Project**
• All our community testers in `@ExpressiveLauncherFeedback`!
```
