# ExpressiveOS: Source Trees, Patches, & Build Kits for Unofficial Android 17

<div align="center">
  <img src="docs/assets/screenshots/logo.png" alt="ExpressiveOS Logo" width="128" />
  <h1>ExpressiveOS</h1>
  <p><strong>Central source repository for device trees, patches, build kits, and release tooling for unofficial Android 17 builds (Evolution X 12.3 & DerpFest v17) for the Pixel 11 series, Pixel 8 Pro, and Pixel 7 Pro.</strong></p>

  <p>
    <a href="#overview">Overview</a> •
    <a href="#repository-structure">Repository Structure</a> •
    <a href="#building-from-source">Building from Source</a> •
    <a href="#major-features">Features</a> •
    <a href="#downloads">Downloads</a> •
    <a href="#installation">Installation</a> •
    <a href="#updating">Updating</a> •
    <a href="#reporting-bugs">Reporting Bugs</a>
  </p>
</div>

---

## Overview

Central source repository for device trees, patches, build kits, and release tooling for unofficial Android 17 Evolution X 12.3 and DerpFest v17 builds for the Pixel 11 series (kodiak, grizzly, cubs, yogi), Pixel 8 Pro (husky), and Pixel 7 Pro (cheetah).

These are unofficial builds maintained by Daryl Denson (@daryldenson). They aren't official Evolution X or DerpFest builds, so report bugs in this project's threads, not to those teams.

* **Evolution X 12.3** (`cnb`, based on LineageOS 24.0) for the Pixel 11 Pro XL, Pixel 11 Pro, Pixel 11, Pixel 11 Pro Fold, Pixel 8 Pro and Pixel 7 Pro.
* **DerpFest v17** (based on LineageOS 24.0) for the Pixel 8 Pro.

This repository holds the device trees, patches and release tools the builds are made from.

---

## Repository Structure

```
ExpressiveOS/
├── evolution-kodiak/          # Evolution X kit for the Pixel 11 series (kodiak, grizzly, cubs, yogi), plus shared release tools
├── evolution-husky/           # Evolution X kit for the Pixel 8 Pro (husky)
├── evolution-cheetah/         # Evolution X kit for the Pixel 7 Pro (cheetah)
├── derpfest-husky/            # DerpFest kit for the Pixel 8 Pro (husky)
├── tools/
│   ├── community_monitor/     # Daily XDA/Telegram triage
│   └── ota_mirror/            # R2 mirror for the Updaters' OTA packages
├── research_notes/            # Source research behind the kits
├── archive/                   # Posted XDA/Telegram announcements and old reply drafts
└── docs/assets/screenshots/   # Logo
```

---

## Building from Source

Builds run on the build server from the per-ROM kits below. Each kit's README covers its trees, patches, build and release steps:

* **Evolution X, Pixel 11 series** (kodiak, grizzly, cubs, yogi): [`evolution-kodiak/`](evolution-kodiak/README.md)
* **Evolution X, Pixel 8 Pro** (husky): [`evolution-husky/`](evolution-husky/README.md)
* **Evolution X, Pixel 7 Pro** (cheetah): [`evolution-cheetah/`](evolution-cheetah/README.md)
* **DerpFest, Pixel 8 Pro** (husky): [`derpfest-husky/`](derpfest-husky/README.md)

### Tooling & Research
* **Community Monitor**: [`tools/community_monitor/`](tools/community_monitor/) for daily XDA/Telegram triage.
* **OTA Mirror**: [`tools/ota_mirror/`](tools/ota_mirror/) for Updaters' OTA package mirroring.
* **Research Notes**: [`research_notes/`](research_notes/) for source research behind the kits.

---

## Major Features

### 📱 Builds

| Device | ROM | Kernel | Updates |
| :--- | :--- | :--- | :--- |
| Pixel 11 Pro XL (`kodiak`) | Evolution X 12.3 | Espada v3.5 (Linux 6.12.96) | System updates in Settings |
| Pixel 11 Pro (`grizzly`) | Evolution X 12.3 | Espada v3.5 (Linux 6.12.96) | System updates in Settings |
| Pixel 11 (`cubs`) | Evolution X 12.3 | Espada v3.5 (Linux 6.12.96) | System updates in Settings |
| Pixel 11 Pro Fold (`yogi`) | Evolution X 12.3 | Espada v3.5 (Linux 6.12.96) | System updates in Settings |
| Pixel 8 Pro (`husky`) | Evolution X 12.3 | Linux 6.1 (Google's GKI, LineageOS's device modules) | System updates in Settings (from the 2026-10-24 build) |
| Pixel 7 Pro (`cheetah`) | Evolution X 12.3 | Linux 6.1 (Google's GKI, LineageOS's device modules) | System updates in Settings |
| Pixel 8 Pro (`husky`) | DerpFest v17 | Linux 6.1 (GKI android14-6.1, LineageOS's gs-6.1 sources) | DerpFest's Updater |

All builds are unofficial Android 17 builds: user builds signed with private release keys, Google apps included, not rooted. Evolution X and DerpFest are separate ROMs with their own keys, so moving between them takes a clean install.

### 🔄 Over-the-Air Updates
* **Our own update server**: the built-in Updater reads [`denson9874/evolution_ota`](https://github.com/denson9874/evolution_ota) (Evolution X) or [`denson9874/derpfest_ota`](https://github.com/denson9874/derpfest_ota) (DerpFest), not the official servers.
* **A/B updates in the background**: the update installs to the inactive slot, then you restart. Rooted users install Magisk to the inactive slot before restarting.
* **Precompiled apps survive updates**: app odex ships with the apps instead of on `system_other`, which updates never write, so preinstalled apps don't run slowly after every update.

### 🧩 Stock Pixel Parity
* **Stock settings values** (Evolution X): overlay values taken from each phone's stock firmware instead of AOSP defaults.
* **Google's system services as on stock**: Private Compute Services isn't cut off from the apps that use it, and on Evolution X, Adaptive Connectivity (SCONE) has its system permissions.
* **NFC on after a clean install**, with the Contactless payments page that Google Wallet opens.
* **No double PIN after a reboot**: Play services can't prepare Google's stock OTAs, which armed resume-on-reboot.
* **Checked against stock before release**: every Evolution X build is compared with stock firmware for leftover apps and for association rules that differ from stock.

### ✨ Per-Device Extras
* **Pixel 11 series**: VoLTE, 5G SA and visual voicemail (tested on T-Mobile US); Now Playing; HiLight light bar settings for Gemini and calls from starred contacts (kodiak, grizzly, yogi); fold postures on yogi.
* **Evolution X on the Pixel 8 Pro and Pixel 7 Pro**: October 2026 vendor firmware (vendor security patch 2026-10-05); stock screenshot Markup editor, Quick Share copy, Files button and Google Photos in the photo picker; Google Fi (Tycho); Restart SystemUI in husky's advanced reboot menu.
* **DerpFest on the Pixel 8 Pro**: DerpFest Parts, themes, clocks, Game Space and freeform windows; Basic Call Recorder (BCR) built in, off until you turn it on.

### ⚠️ Known Limitations
* **Gemini Nano** features don't work: Google serves its on-device models only to phones with a locked bootloader.
* **Extreme Charging**: the tile has no effect on husky yet and isn't available on cheetah.
* **DerpFest face unlock** is camera-based, not the Pixel's secure face unlock: use the fingerprint sensor for payments and app sign-in.

---

## Downloads

Every download folder has the SHA-256 checksums: check the zip before you flash it.

| Device | Download | XDA thread |
| :--- | :--- | :--- |
| Pixel 11 Pro XL (`kodiak`) | [SourceForge: kodiak/17](https://sourceforge.net/projects/denson9874-s-user-builds/files/kodiak/17/) | [kodiak / grizzly](https://xdaforums.com/t/4804712/) |
| Pixel 11 Pro (`grizzly`) | [SourceForge: grizzly/17](https://sourceforge.net/projects/denson9874-s-user-builds/files/grizzly/17/) | [kodiak / grizzly](https://xdaforums.com/t/4804712/) |
| Pixel 11 (`cubs`) | [SourceForge: cubs/17](https://sourceforge.net/projects/denson9874-s-user-builds/files/cubs/17/) | [cubs](https://xdaforums.com/t/4804723/) |
| Pixel 11 Pro Fold (`yogi`) | [SourceForge: yogi/17](https://sourceforge.net/projects/denson9874-s-user-builds/files/yogi/17/) | [yogi](https://xdaforums.com/t/4804826/) |
| Pixel 8 Pro (`husky`), Evolution X | [SourceForge: husky/17](https://sourceforge.net/projects/denson9874-s-user-builds/files/husky/17/) | [husky](https://xdaforums.com/t/4805239/) |
| Pixel 7 Pro (`cheetah`) | [SourceForge: cheetah/17](https://sourceforge.net/projects/denson9874-s-user-builds/files/cheetah/17/) | [cheetah](https://xdaforums.com/t/4806248/) |
| Pixel 8 Pro (`husky`), DerpFest | [SourceForge: derpfest/husky](https://sourceforge.net/projects/denson9874-s-user-builds/files/derpfest/husky/) | [husky DerpFest](https://xdaforums.com/t/4805240/) |

---

## Installation

### 1. Requirements
1. **Unlock the bootloader**: unlocking wipes the phone.
2. **Install the latest platform-tools** (`adb` and `fastboot`).
3. **Put the phone on the right stock firmware** with the [Android Flash Tool](https://flash.android.com/):

| Device | Stock firmware | Notes |
| :--- | :--- | :--- |
| Pixel 11 series | CD1A.261005.003 (October 2026) | The zip doesn't flash a bootloader or radio, so the phone must already be on this release |
| Pixel 7 Pro | CP3A.261005.002.A1 (October 2026) or newer | The zip doesn't flash a bootloader or radio; later OTAs include them |
| Pixel 8 Pro | CP3A.261005.005 (October 2026) | The zip includes this firmware, but the phone should already be on it |

4. **Coming from any other ROM, a clean install is required**, including between Evolution X and DerpFest. Each build is signed with its own keys, so updates from one won't install over another.

### Pixel 11 series and Pixel 7 Pro (fastboot zip)
Use the zip whose name ends in `-fastboot.zip` (the other zip is the OTA package). If a folder has several for the same date, the highest `-rN` is the newest.
```sh
adb reboot bootloader
fastboot -w update EvolutionX-17.0-<date>-<device>-12.3-Unofficial-fastboot.zip
```
`-w` wipes all your data. fastboot switches to fastbootd partway through; leave the phone plugged in until it reboots by itself. The first boot takes a few minutes.

### Pixel 8 Pro (recovery sideload, Evolution X or DerpFest)
Download the ROM zip and the matching `boot-<date>.img` and `vendor_boot-<date>.img` from the same folder, then:
```sh
adb reboot bootloader
fastboot flash boot boot-<date>.img
fastboot flash vendor_boot vendor_boot-<date>.img
fastboot reboot recovery
```
In recovery, choose **Factory reset > Format data/factory reset > Format data** (this wipes all your data), then **Apply update > Apply from ADB**, and sideload the zip:
```sh
adb sideload <ROM zip>
```
The sideload stops at about 47% with `Total xfer: 1.00x`; that's normal. Choose **Reboot system now**.

### Keep the bootloader unlocked
These builds don't support a locked bootloader. Locking it with a custom ROM installed can leave the phone unable to boot.

---

## Updating

* **Evolution X:** Settings > System > System updates. **DerpFest:** Settings > System > Updater. The update installs in the background to the inactive slot; restart when it's done. Updates keep your data.
* **Pixel 8 Pro on an Evolution X build older than 2026-10-24:** sideload the newest build once (recovery > Apply update > Apply from ADB); updates arrive in Settings after that.
* **Rooted:** before restarting, open Magisk > Install > *Install to inactive slot (after OTA)*, or root is gone. With KernelSU-Next / SuSFS on Espada (kodiak, grizzly, cubs), flash Espada's KSU zip again after the update.

---

## Reporting Bugs

* **No logs, no report.** Reports without a logcat are flagged for deletion. Capture one right after the problem happens, and post it with your build date and the steps to reproduce:
```sh
adb logcat -b all -d > log.txt
```
* **Custom setups get limited to no support.** That covers root modules, Xposed/LSPosed, kernels other than the build's own or Espada, and apps from APKMirror and similar sites that don't match the build (Google system apps especially). Reproduce the problem on a clean install without them first.
* Post in your device's XDA thread (see [Downloads](#downloads)).

---

## License
