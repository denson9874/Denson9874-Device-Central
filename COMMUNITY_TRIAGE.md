# Evolution X / DerpFest — Community Issues & Requests Backlog

This backlog tracks bug reports, regressions, hardware findings, and feature requests reported across Telegram (`@ExpressiveLauncherFeedback`, `@ExpressiveGroup`) and XDA threads (`kodiak`/`grizzly`, `cubs`, `yogi`, `husky`).

It is updated daily at **09:00 AM ET** by the automated Community Monitor and reviewed during the week for Sunday releases.

---

## Active Community Backlog

| Issue ID | Date Logged | Source & Reporter | Device | Category | Severity | Status | Summary & Technical Details | Target Release |
|:---|:---|:---|:---|:---|:---|:---|:---|:---|
| `ISS-20261012-01` | 2026-10-12 | TG: Ashray V K | `kodiak` | Bug | Medium | `RELEASED` | Screen timeout to AOD flashes ~121 nits before dimming to 0.5 nits | 2026-10-13 (0001) / 2026-10-16 (0003) |
| `ISS-20261012-02` | 2026-10-12 | TG: Ashray V K | `kodiak` | Support | Low | `RESOLVED` | PIN prompt appears twice after reboot; diagnosed as Play Services update arming "resume on reboot" | 2026-10-18 |
| `ISS-20261012-03` | 2026-10-12 | TG: Ashray V K | `kodiak` | Feature | Low | `RELEASED` | HiLight settings and animation triggers for Gemini, calls, contacts | 2026-10-13 |
| `ISS-20261013-01` | 2026-10-13 | TG: Ashray V K | `kodiak` | Bug | Low | `TRIAGED` | Morphe patcher fails with ENOENT for /system/framework/org.lineageos.platform-res.apk: Evolution/crDroid bionic custom_rom_hide hides /system/framework/org.lineageos.* from app-uid processes. ROM-side (upstream), low severity | Upstream EvoX |
| `ISS-20261015-01` | 2026-10-15 | TG: Ashray V K | `kodiak` | Feature | High | `RELEASED` | Extreme Charging Mode ("Bodega") with Quick Settings tile for 30W+ fast charging | 2026-10-16 |
| `ISS-20261015-02` | 2026-10-15 | XDA: Paddybecks87 (Post #21) | `kodiak` | Bug | Low | `RESOLVED` | App previews of locked apps visible in Launcher3 Quickstep Recents overview | Duplicate of ISS-20261022-05 |
| `ISS-20261015-03` | 2026-10-15 | XDA: xerel89 (Post #22) | All P11 | Bug | Medium | `RESOLVED` | Flashing stuck at `< waiting for any device >` after rebooting into fastbootd: recovery/fastbootd run from our vendor_boot and had no ro.recovery.usb.* IDs (stock sets 18D1/D001/4EE0 in vendor/build.prop). Added on all four phones. Also check the fastboot driver / USB hub | 2026-10-23 |
| `ISS-20261015-04` | 2026-10-15 | XDA: stevecaboose (Post #2) | `yogi` | Testing | Medium | `IN_PROGRESS` | Yogi (Fold) test coverage: fold/unfold transitions, hinge angle, and telephony audio | 2026-10-18 |
| `ISS-20261016-01` | 2026-10-16 | Community Report | All P11 | Bug | Critical | `RELEASED` | "Use device MAC" option unavailable for MAC-filtered Wi-Fi networks | 2026-10-16 (-r2) |
| `ISS-20261017-01` | 2026-10-17 | TG: Lubomir | `kodiak` | Bug | Medium | `RELEASED` | Finaly, flashed todays release and its booting, but strange issue i found also in previous, why some apps cant access... | 2026-10-22 |
| `ISS-20261017-02` | 2026-10-17 | TG: DevAB | `kodiak` | Feature | Medium | `TRIAGED` | Hi, does anyone know which face unlock the ROM is using? Google’s or AOSP’s? Thanks for the reply. Google’s face unlo... | Next Sunday |
| `ISS-20261017-03` | 2026-10-17 | XDA: mcflyrk01 (Post #90779478) | `kodiak` | Bug | Critical | `RESOLVED` | Setup Wizard Wi-Fi: networks drop from the scan list during setup; connects after skipping. Mainline supplicant overlays (Passpoint, scan offload) shipped 10-22; no recurrence reported | No reports since 10-18; reopen with a Setup Wizard logcat |
| `ISS-20261017-04` | 2026-10-17 | XDA: anthonnyb98 (Post #90779690) | `kodiak` | Feature | Medium | `TRIAGED` | Greetings @denson9874, and thanks for the great work. I was wondering whether the facial unlock feature implemented i... | Next Sunday |
| `ISS-20261017-05` | 2026-10-17 | XDA: wreq5 (Post #90779551) | `cubs` | Bug | High | `NEEDS_LOGS` | Alright alright alriiiight, flashed EvoX onto my Pixel 11 cubs and it was smooth as butter, Everything seems to check... | Next Sunday |
| `ISS-20261019-01` | 2026-10-19 | Community report (video, logcat) | All P11 | Bug | High | `RELEASED` | Now Playing stuck at "Setting up Now Playing" and can't be turned on: vendor/gms nowplaying.xml blocked ASI from PCS ("association not allowed"); fixed (kodiak 0f60690, vendor/gms fc94da7) | 2026-10-22 |
| `ISS-20261019-02` | 2026-10-19 | XDA: mcflyrk01 (Post #90782939, #90787193) | `kodiak` | Bug | High | `RELEASED` | Google Fi eSIM fails (T120 error, Keystore errors in logcat) & SIM settings won't launch; verified working on 2026-10-22 build by user | 2026-10-22 |
| `ISS-20261020-01` | 2026-10-20 | TG: Igor (+ Ashray V K) | `kodiak` | Bug | High | `RELEASED` | SystemUI crashed (back to lock screen) after FOD unlock / instant QS on the 10-18 kodiak build (`NoSuchMethodError IUdfpsRefreshRateRequestCallback.onRequestRate`): a stale AOSP SystemUI.apk in out/ shipped next to SystemUIGoogle. Removed; release-checks.sh now blocks stale apps | 2026-10-22 |
| `ISS-20261020-02` | 2026-10-20 | TG: Loic | `kodiak` | Bug / Mod | Low | `RESOLVED` | Chrome crash on launch isolated to user-enabled 'hide framework-res.apk' option in SuSFS/LSPosed; disabling option restored full functionality. Not a ROM defect | User config |
| `ISS-20261019-03` | 2026-10-19 | TG: Masterdex | `kodiak` | Support | Low | `RESOLVED` | MEETS_STRONG_INTEGRITY not supported on DerpFest due to Tensor G6 boot failure risks; use Evolution X | Documented / Support |
| `ISS-20261019-04` | 2026-10-19 | TG: Christoph 🇮🇱 | `kodiak` | Support / Mod | Low | `RESOLVED` | Third-party AnyKernel3 distributions (WildKernel) bootloop; Espada kernel v3 is the only supported kernel | Documented / Support |
| `ISS-20261019-05` | 2026-10-19 | XDA: xerel89 (Post #90782948) / TG: Christoph, Igor, Ashray V K (logs) | All P11 | Bug | Medium | `RELEASED` | At a Glance / Live Display sub-settings can't be disabled (master Home setting works). Ashray's logcat (2026-10-22) confirms same root cause as `ISS-20261019-01`: ASI's opt-in write to PCS (AstreaGrpcService) fails with "association not allowed" (vendor/gms nowplaying.xml); not a Launcher3 binding bug. fixed by kodiak 0f60690 / vendor/gms 1d69071 | 2026-10-22 |
| `ISS-20261019-06` | 2026-10-19 | XDA: kingpeppermint (Post #90783314) | `husky` | Support | Low | `RESOLVED` | Clarified that Evolution X Husky does not enforce stock Google 24-hour sideloading lockout restrictions | Reply posted |
| `ISS-20261020-03` | 2026-10-20 | TG: Pratik | n/a | Launcher | Medium | `TRIAGED` | Expressive Launcher: app drawer search bar overlaps top row, missing work profile badge in hide apps, folder icon customization request, icon sizing disparity across drawer and folders | Launcher 5.0.x |
| `ISS-20261020-04` | 2026-10-20 | XDA: LoganDeveloper (Post #90783707) | `grizzly` | Bug | Medium | `TRIAGED` | 80% charging limit toggle unexpectedly turns off / resets on grizzly; inquiry regarding adaptive charging | Next Sunday |
| `ISS-20261020-05` | 2026-10-20 | XDA: bs3pro (Post #90784537) / TG: Christoph 🇮🇱 | `kodiak` | Bug | Low | `NEEDS_LOGS` | RCS not working for some (Christoph, xerel89, bs3pro), working for others (Igor; LoganDeveloper after clearing Messages data). Likely per carrier or Play Integrity. Needs Messages > RCS chats status and a logcat | Next Sunday |
| `ISS-20261021-01` | 2026-10-21 | TG: Ashray V K | `kodiak` | Support / Mod | Low | `RESOLVED` | Confirmed KernelSU SuSFS v2.3.0 (GKI) support in Espada kernel v3 as displayed in KSU Manager | Documented / Support |
| `ISS-20261022-01` | 2026-10-22 | TG: Igor (video) | `kodiak` | Bug | Medium | `IN_PROGRESS` | Feed apps (Reddit, TikTok, X) jump back to earlier posts while scrolling; gone with the Dynamic Bar off (Igor video 10-23, Ashray saw it too). Candidate fix: frameworks_base 0010 (island without backdrop blur) in the next build; re-test requested, not confirmed. Replied to Igor on TG 2026-10-23 (to his "Haven't seen them after disabling dynamic bar"): asked him to turn the Dynamic Bar back on in the next P11 build and report; workaround until then: Dynamic Bar off | Next build |
| `ISS-20261022-02` | 2026-10-22 | TG: Ashray V K (logs), Igor | All P11 | Bug | High | `RESOLVED` | Face unlock setup crashed Settings: the face enroll hand-off target com.google.android.settings.future.biometrics.faceenroll was missing (ActivityNotFoundException). Stock SettingsGoogleFutureFaceEnroll (system_ext priv-app, platform re-signed) added on all four phones (kodiak 9f35e0c, grizzly 7aa3484, cubs 6828376, yogi 3dbf16e). Enrollment itself not yet confirmed on a Pixel 11 | 2026-10-23 |
| `ISS-20261022-03` | 2026-10-22 | TG: Ashray V K | `kodiak` | Bug / Mod | Low | `NEEDS_LOGS` | Updater offers the 10-22 build after installing it. Feed timestamp = build's ro.build.date.utc and the Updater drops equal/older builds, so suspect a root module spoofing ro.build.date.utc; asked for `getprop ro.build.date.utc` | Pending reply |
| `ISS-20261022-04` | 2026-10-22 | Daryl (cheetah), wife (husky) | All P11 | Bug | Medium | `RESOLVED` | Micro-stutter while the Dynamic Bar island shows: its backdrop blur put a blur region in the status bar window, so SurfaceFlinger GPU-composited every app frame. frameworks_base 0010 draws the island without backdrop blur (cheetah 0/1190, husky 0/937 frames client-composited). Shipped in Evolution husky 20261023 | 2026-10-23 |
| `ISS-20261022-05` | 2026-10-22 | Daryl, XDA: Ashray_Vk (Post #90787566) | All P11 | Bug | Medium | `RESOLVED` | Locked apps showed their content in Recents: Pixel Launcher doesn't know the sandbox App Lock and RecentTasks dropped isTopAppLocked's result. frameworks_base 0009 withholds snapshots of App-Locked apps, so Recents shows the lock placeholder (also while the app is unlocked). Shipped in Evolution husky 20261023. Replied to Ashray_Vk on XDA 2026-10-23 (post 90788959): fix explained, coming in the next P11 build | 2026-10-23 |
| `ISS-20261022-06` | 2026-10-22 | Daryl (husky test) | `husky` | Bug | Low | `TRIAGED` | Evolution husky: Play-updated SCONE (com.google.android.apps.scone p.2026.36) crashes after boot: SecurityException WRITE_SECURE_SETTINGS and carrier privilege for TelephonyRegistry.listen. Since its 10-16 update; husky likely lacks kodiak's SCONE privapp allowlist (kodiak-scone.xml) | Next husky build |
| `ISS-20261023-01` | 2026-10-23 | XDA: LoganDeveloper (Post #90788207, #90788979) | `grizzly` | Support | Low | `RESOLVED` | Now Playing song database download stuck on the 10-22 build, even after clearing Now Playing's data. Fixed on his phone by clearing Android System Intelligence's data (post 90788979); no ROM change. Not a stock-ROM AICore data point: he's rooted and forced the AICore model downloads with "Public Compute Services", a root tool | User fix (clear ASI data) |
| `ISS-20261023-02` | 2026-10-23 | Release review (critic) | All P11 | Bug | Medium | `RESOLVED` | Settings > Connected devices > NFC > Contactless payments (and Wallet's default-payment link) opened a broken page: PaymentSettingsActivity pointed at the removed nfc.PaymentSettings fragment. Evolution X Settings 8b2dded5b421 (ExtremeXT) carried as patches/packages_apps_Settings/0001 | 2026-10-23 |
| `ISS-20261023-03` | 2026-10-23 | Release review | `yogi` | Bug | Medium | `RESOLVED` | Fold posture: config_device_state_postures was missing (stock sets it in its product RRO), so apps and WindowManager saw no fold posture (Jetpack FoldingFeature, tabletop). Stock values added to FrameworkResOverlayYogi; not tested on a yogi | 2026-10-23 |

---

## Status Definitions

- **`NEW`**: Freshly ingested report from Telegram or XDA, awaiting initial developer review.
- **`TRIAGED`**: Validated and categorized. Technical root cause or subsystem identified.
- **`NEEDS_LOGS`**: Requires logcat, `KeyguardUpdateMonitor` dump, or reproduction steps from the user. Draft reply generated in daily replies.
- **`IN_PROGRESS`**: Active development in device trees (`device_google_*`), vendor blobs, kernel, or overlays.
- **`VERIFIED`**: Fix compiled, verified with `check-sepolicy.sh`, built and/or hardware-tested.
- **`RESOLVED`**: Closed. With a release date (`YYYY-MM-DD`) in Target Release and a category other than `Support`, it is a ROM change that ships like `VERIFIED`. Otherwise (support answers, documented workarounds) it is closed and never appears in release notes.
- **`RELEASED`**: Merged into an official Sunday release and published to SourceForge & OTA.
- **`UPSTREAM`**: Tracked for upstream Evolution X / LineageOS platform resolution.

---

## Release Pipeline Integration

Every Sunday during the parity routine (`p11-routine.sh`, Pixel 11 devices only):
1. Release items (`VERIFIED`, or `RESOLVED` with a release date as defined above) for the device are appended to its
   changelog `CHANGES-<date>.txt` by `evolution-kodiak/tools/community_release_notes.py`, which `p11-ota.sh` publishes
   with the OTA. The server reads `~/COMMUNITY_TRIAGE.md`, so copy this file there before the run.
2. The build is verified, the fastboot zip and signed A/B OTA package upload to SourceForge, and the OTA manifest
   updates in `denson9874/evolution_ota`.
3. After the published runs, on the Mac:
   `python3 evolution-kodiak/tools/community_release_notes.py <published devices...> --mark-released`
   moves the release items to `RELEASED`. A row for several devices (`All P11`, `All`) moves only when every one of
   its devices is in the list.
4. Announcement drafts (`evolution-kodiak/community/replies/RELEASE_<rom>_<device>_<date>.md`) come from
   `tools/community_monitor/release_publisher.py --dry-run`; nothing is posted without review.
