# ExpressiveOS / Evolution X — Community Issues & Requests Backlog

This backlog tracks bug reports, regressions, hardware findings, and feature requests reported across Telegram (`@ExpressiveLauncherFeedback`, `@ExpressiveGroup`) and XDA threads (`kodiak`/`grizzly`, `cubs`, `yogi`, `husky`).

It is updated daily at **09:00 AM ET** by the automated Community Monitor and reviewed during the week for Sunday releases.

---

## Active Community Backlog

| Issue ID | Date Logged | Source & Reporter | Device | Category | Severity | Status | Summary & Technical Details | Target Release |
|:---|:---|:---|:---|:---|:---|:---|:---|:---|
| `ISS-20261012-01` | 2026-10-12 | TG: Ashray V K | `kodiak` | Bug | Medium | `RELEASED` | Screen timeout to AOD flashes ~121 nits before dimming to 0.5 nits | 2026-10-13 |
| `ISS-20261012-02` | 2026-10-12 | TG: Ashray V K | `kodiak` | Support | Low | `RESOLVED` | PIN prompt appears twice after reboot; diagnosed as Play Services update arming "resume on reboot" | 2026-10-18 |
| `ISS-20261012-03` | 2026-10-12 | TG: Ashray V K | `kodiak` | Feature | Low | `TRIAGED` | HiLight settings and animation triggers for Gemini, calls, contacts | Backlog |
| `ISS-20261013-01` | 2026-10-13 | TG: Ashray V K | `kodiak` | Bug / Mod | Low | `RESOLVED` | Morphe patcher fails with ENOENT looking for `/system/framework/org.lineageos.platform-res.apk` due to SuSFS hiding | Documented workaround / ROM tolerance |
| `ISS-20261015-01` | 2026-10-15 | TG: Ashray V K | `kodiak` | Feature | High | `RELEASED` | Extreme Charging Mode ("Bodega") with Quick Settings tile for 30W+ fast charging | 2026-10-16 |
| `ISS-20261015-02` | 2026-10-15 | XDA: Paddybecks87 (Post #21) | `kodiak` | Bug | Low | `TRIAGED` | App previews of locked apps visible in Launcher3 Quickstep Recents overview | Upstream EvoX / Launcher3 |
| `ISS-20261015-03` | 2026-10-15 | XDA: xerel89 (Post #22) | `kodiak` | Support | Medium | `RESOLVED` | Flashing stuck on `< waiting for any device >` due to missing fastboot driver / USB-C hub | Reply posted |
| `ISS-20261015-04` | 2026-10-15 | XDA: stevecaboose (Post #2) | `yogi` | Testing | Medium | `IN_PROGRESS` | Yogi (Fold) test coverage: fold/unfold transitions, hinge angle, and telephony audio | 2026-10-18 |
| `ISS-20261016-01` | 2026-10-16 | Community Report | All P11 | Bug | Critical | `RELEASED` | "Use device MAC" option unavailable for MAC-filtered Wi-Fi networks | 2026-10-16 (-r2) |
| `ISS-20261017-01` | 2026-10-17 | TG: Lubomir | `kodiak` | Bug | Medium | `NEEDS_LOGS` | Finaly, flashed todays release and its booting, but strange issue i found also in previous, why some apps cant access... | Next Sunday |
| `ISS-20261017-02` | 2026-10-17 | TG: DevAB | `kodiak` | Feature | Medium | `TRIAGED` | Hi, does anyone know which face unlock the ROM is using? Google’s or AOSP’s? Thanks for the reply. Google’s face unlo... | Next Sunday |
| `ISS-20261017-03` | 2026-10-17 | XDA: mcflyrk01 (Post #90779478) | `kodiak` | Bug | Critical | `TRIAGED` | Turns out this is only in the setup wizard, WiFi does connect fine once I skip through all of that. Tried rooting wit... | Next Sunday |
| `ISS-20261017-04` | 2026-10-17 | XDA: anthonnyb98 (Post #90779690) | `kodiak` | Feature | Medium | `TRIAGED` | Greetings @denson9874, and thanks for the great work. I was wondering whether the facial unlock feature implemented i... | Next Sunday |
| `ISS-20261017-05` | 2026-10-17 | XDA: wreq5 (Post #90779551) | `cubs` | Bug | High | `NEEDS_LOGS` | Alright alright alriiiight, flashed EvoX onto my Pixel 11 cubs and it was smooth as butter, Everything seems to check... | Next Sunday |

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
