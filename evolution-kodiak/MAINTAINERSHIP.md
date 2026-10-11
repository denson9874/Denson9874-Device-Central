# Evolution X maintainership for kodiak (Pixel 11 Pro XL)

Reviewed 2026-10-11 against:
- https://wiki.evolution-x.org/apply-for-maintainership
- https://wiki.evolution-x.org/code-of-conduct (the CoC)
- https://github.com/Evolution-X/onboarding

## Progress (2026-10-11)

| Blocker | State |
|---|---|
| 1. Public trees | **Device tree public:** https://github.com/denson9874/device_google_kodiak (branch `cnb`, one clean initial commit, noreply author e-mail). The vendor blobs (46 MB) and `kodiak-images` (1.5 GB of whole stock images, two files over GitHub's 100 MB limit) are **not** published. Ask the team how they want a prebuilt-vendor Pixel handled |
| 2. ROM source patch | **Upstream PR opened:** https://github.com/Evolution-X/build/pull/5. It fixes a regression from their #4 (`5b95f1f`), tested with a minimal target-files zip. Once merged, drop `patches/` and `apply-patches.sh` from the tree |
| 3. Proprietary apps | **Trimmed** (`9480969`): AI stubs, Hotword, Now Playing, PixelCameraServices and SatelliteGateway removed. 14 hardware-support APKs remain, to raise as an exception |
| 4. Stability | Fresh build from the trimmed tree in progress. Then flash, the 3× reboot test and a call test |

## How applying works

- **Where:** in Evolution X's Discord (https://discord.gg/3qbSZHx). Send `/apply` in any channel, and a bot runs
  the application. Rejections arrive as a bot DM.
- **Who:** it has to come from Daryl's own Discord account. It includes personal statements
  (age 18+, English, git knowledge), so nobody can file it for him.
- **Onboarding comes after acceptance.** That covers repos in the devices org, signing with the project's private
  keys, SourceForge uploads, the XDA thread, and an OTA pull request.

**kodiak is free:** no device on the A17 `cnb` branch of `Evolution-X/OTA` is a Pixel. The only official devices
are marble, raphael, tissot and venus. So CoC Clause 0, Act 2 (an existing official maintainer) doesn't block an application.

## Eligibility (apply page)

| Requirement | Status |
|---|---|
| Owns the device | ✅ serial 66020DLDV0049F |
| Medium knowledge of git | Daryl to confirm |
| English with users and team | Daryl to confirm |
| Initial unofficial build, stable for daily use | ⚠️ mostly. See "Stability" below |
| **Device tree public** | ❌ private (ExpressiveOS repo). See blocker 1 |
| Not a placeholder for a removed maintainer | ✅ |
| No unofficial builds published if the device has an active maintainer | ✅ no maintainer |
| 18 or older | Daryl to confirm |

## Code of Conduct blockers

**1. Public trees in the official org (Clause 4, Acts 1 and 2).**
- Device, vendor **and kernel** trees must be public and hosted in `Evolution-X-Devices`.
  Private repositories are prohibited.
- Our dependencies:
  - `device/google/kodiak`: the tree itself, no blobs; it can go public.
  - `vendor/google/kodiak`: extract-utils blobs, mostly telephony.
  - `vendor/google/kodiak-images`: **whole stock images**: vendor, vendor_dlkm, system_dlkm, boot/GKI kernel,
    dtbo and firmware.
- This contradicts the port's rule so far ("never push device trees; the vendor tree never goes public"). **Daryl's call.**
- Publishing whole Google images is also a different thing from the usual Lineage-style blob repos.
- Clause 4, Act 6 forbids copyright-infringing blobs in device trees. Ask the team how they want a
  prebuilt-vendor Pixel handled.

**2. No ROM source changes; builds run on the Project's CI (Clause 2 Act 1, Clause 3 Act 6.1).**
- Our build needs `patches/build_make/0001-releasetools-tolerate-prebuilt-partitions-without-a-.patch`, applied to
  `build/make` by `apply-patches.sh`. Evolution's CI builds unmodified source, so the zip step would fail there.
- Act 1.1 allows source changes only with explicit authorization, for device compatibility.
- **Fix:** remove the need for the patch in the device tree, or get it upstreamed or approved before applying.

**3. No proprietary apps in device trees (Clause 4, Act 5).** `proprietary-files.txt` ships these Google APKs:
- **Telephony:** grilservice, ril-extension, PixelModemService, PixelImsMediaService, PixelQualifiedNetworksService,
  CarrierSettings/CarrierSetup, EuiccSupportPixel* and the satellite services.
  - These are needed for calls; Act 5.1/5.2 allow exceptions with Project approval. **Ask.**
- **AI and extras from `2c120d1`:** AICorePrebuilt, PixelAIPrebuilt, PixelSensePrebuilt, CreativeAssistant,
  AmbientStreaming, NowPlayingPrebuilt, Hotword, PixelCameraServices, SatelliteGateway.
  - Not needed to boot or call, and the AI ones can't work on an unlocked device anyway.
  - **Remove from the official tree** (they can stay in personal builds).
- PixelDisplayService and PersistentBackgroundCameraServices: needed for display and camera features, so they
  need an exception too.

**4. No root in official builds (Clause 2, Act 5).**
- Fine: Magisk is only in test zips (`~/.kodiak-root`), and the release OTA doesn't go through `kodiak-imgzip.sh`.
- Set `~/.kodiak-root` to `none`, or remove it, on any machine that builds official releases.

**5. Official build type (Clause 4, Act 4).** `EVO_BUILD_TYPE := OFFICIAL` is needed in the Makefile and
`export EVO_BUILD_TYPE=OFFICIAL` in build scripts. Today's scripts use `Unofficial`. Change it on acceptance.

**6. Signing (Clause 3, Act 6).** Official builds are signed with the Project's keys on its CI. Our
`vendor/evolution-priv/keys` are our own, so this is fine for unofficial builds.

## Stability ("deemed stable for daily usage")

**Working:**
- calls, with two-way VoLTE audio; data; IMS
- Wi-Fi and Bluetooth
- camera, fingerprint, face unlock
- Play Integrity STRONG, Google Wallet tap-to-pay
- hardware key attestation (RKP) since `4df22cd`

**Still to do before applying:**
- The 3× reboot test and a call on the newest build (HANDOFF 2e, open issue 1).
- A fresh build and zip from current `evolution/kodiak-port`. There's no zip right now; the old ones were
  deleted (HANDOFF 2e cleanup).
- The bootloader `--flags 3` (verification off) is still a bring-up setting. Ask whether the team expects
  verification on for official builds.
- Known limit, the same on any custom ROM with an unlocked bootloader: Gemini Nano and Magic Cue don't work.

## Draft application text (fill the blanks; post from Daryl's own Discord account via `/apply`)

The bot's exact questions aren't public. These answers cover what the wiki and onboarding ask for.

- **Device:** Google Pixel 11 Pro XL (`kodiak`), Tensor G6 (`malibu`), MediaTek T900 modem
- **Android / Evolution X version:** Evolution X 17 (`cnb`), Android 17
- **Device ownership:** yes, it's my daily driver
- **GitHub username:** denson9874
- **SourceForge username:** ____
- **Device tree:** https://github.com/denson9874/device_google_kodiak
- **Vendor tree:** generated from the stock factory image with `extract-files.py` / `extract-images.sh` (not published yet; see blocker 1)
- **Kernel:** stock prebuilt GKI 6.12 from the CD1A.261005.003 factory image (no kernel source tree yet)
- **Unofficial build:** ____ (link to a test build: Drive or similar)
- **What works:** calls (VoLTE), data, IMS, Wi-Fi, Bluetooth, camera, fingerprint, face unlock,
  Play Integrity STRONG, Google Wallet, hardware key attestation
- **Known issues:** Gemini Nano / Magic Cue (unlocked-bootloader attestation, the same for any custom ROM); ____
- **Experience:** ____ (honestly: how the port was built, git experience, other devices)
- **Initial installation images from stock:** boot, dtbo, vendor_kernel_boot, vendor_boot, init_boot
  (confirm against the kodiak install steps before posting)
- **Age 18+ / English:** ____
