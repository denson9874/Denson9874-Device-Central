# Husky: stability, fluidity and charging plan (2026-10-20)

Scope: Evolution X 17 (`cnb`, 20261016 build) on the Pixel 8 Pro. Inputs: Daryl's 19 s screen recording
(shade pull, QS expand, app drawer; battery 14 %, charging), the husky trees and vendor blobs in
`~/evolution` on the build server, and the kodiak work that husky does not have yet.

## 1. What the recording shows

Frame-timing analysis of `screen-20261020-173400.mp4` (775 frames; each frame diffed against its neighbours
so that idle gaps, where the recorder emits nothing, are not counted as jank):

| Measure | Value |
|---|---|
| Steady-state cadence | p50 9.6 ms (120 Hz holds once an animation is running) |
| Frames in motion | 545 |
| Mid-motion hitches (>34 ms gap while the screen is changing) | **14** |
| Worst hitches | 1009 ms at 9.4 s (app drawer open), 687 ms at 6.2 s, 327 ms at 1.7 s (shade pull), 226 ms at 5.0 s, 100 ms at 11.4 s |
| Short drops | 35–56 ms runs at 0.3–0.5 s and 6.4–6.5 s (shade expansion), i.e. 3–6 missed 120 Hz frames |

Pattern: almost all the long stalls are at the **first frame of a gesture**, and animations are smooth once
they are running. That points to work done when the gesture starts (cold code paths, view inflation,
CPU still at low frequency), not to a GPU that cannot keep up. Caveat: the screen recorder competes
for CPU and the encoder, so `husky-audit.sh fluidity` re-measures without it.

## 2. Findings from the trees

| # | Finding | Evidence | Impact |
|---|---|---|---|
| F1 | **App odex is built into `system_other`** (`BOARD_USES_SYSTEM_OTHER_ODEX := true` from `BoardConfigMainlineCommon.mk`). Only factory images write that partition; zip and OTA installs never do. | `out/target/product/husky/system_other/system_ext/priv-app/{SystemUIGoogle,SettingsGoogle,LineageParts,...}/oat`; 183 MB in all | SystemUI, Settings and Parts start every update with no AOT code until background dexopt runs (idle and charging). This matches the gesture-start stalls. **Kodiak has the same layout.** |
| F2 | The Extreme Charging controller and tile are in husky builds (`frameworks/base` `4a9ecbf939`, shared tree) but stay dormant: husky's `powerhint.json` has no `BODEGA` hint, so `isModeSupported("BODEGA")` is false. | `PowerExt::isModeSupported` → `HintManager::IsHintSupported` | No way to relax charge throttling while using the phone |
| F3 | Wired charge current is throttled by a PID loop on `VIRTUAL-SKIN-CHARGE-WIRED` (weighted skin, SoC, charge and USB thermistors) acting on `chg_mdis`: limited from **38 °C**, PID ceiling 25/26. Stock tuning, but screen-on load (the jank above included) is what heats `soc_therm`. | `thermal_info_config_charge.json` | Slow charging whenever the screen is on. Screen-off charging should be near stock |
| F4 | The kernel charging stack is complete (`pca9468` direct charger, `google-charger`, `google-battery`, `max77779-*`, `p9221` WLC, all in the module load lists), and `google_battery`, `wireless_charger` and `health-service.zuma` are present | `shusky-kernels/6.1/*.modules.load`, `vendor/bin/hw` | A missing driver is not the cause; PPS negotiation still needs confirming on device |
| F5 | Lineage ChargingControl (`deadline`/`limit`) is built in but defaults off | `ChargingControlController.java` | Rule out with `settings get system charging_control_enabled` |
| F6 | husky builds as **`userdebug`**, kodiak as `user` | `~/husky-build.sh` vs `~/kodiak-build.sh` | `ro.debuggable=1`, extra debugging services, adb root. Release builds should match kodiak; A/B it in the trace |
| F7 | Render/SF props are stock (Graphite opt-in, 80 ms idle timer, ADPF `SYSTEM_UI` profile present, blur supported) | `device/google/zuma/*.prop`, `powerhint.json` | No prop "tweak" is justified without a trace |

## 2a. On-device results (2026-10-20, 20261016 build, uptime 1 h 22 min)

- **F1 is not the cause of the stutter on a settled phone.** `dumpsys package dexopt`: SystemUIGoogle `speed`
  (`first-boot`); SettingsGoogle and NexusLauncher `speed-profile` (`bg-dexopt`). ART compiles SystemUI on first
  boot, so the `system_other` change only matters until then (153 packages were still `verify`/`first-boot`).
- **F6 overstated.** The 20261016 zip was built `userdebug`, but Evolution already ships it with `ro.debuggable=0`
  and reports `user`. Moving to `user` is hygiene, not a speed-up.
- **Scripted shade/QS/drawer run** (adb swipes, no screen recorder, 25 s Perfetto trace):

  | Process | Frames | Janky | p50 | p90 | p99 |
  |---|---|---|---|---|---|
  | SystemUI | 854 | 6.3 % | 12 ms | 20 ms | 46 ms |
  | NexusLauncher | 603 | 1.2 % | 5 ms | 7 ms | 21 ms |

  SystemUI main thread: `traversal` 731× (avg 6.4 ms), `NSSL#updateChildren` 671× (avg 4.7 ms, every frame of
  shade motion), `NotificationShadeWindowView#onMeasure` up to 41 ms, one 104 ms `windowResized`. It ran on big
  (2.3 s) and mid (1.9 s) cores; `INTERACTION` boosts and the SYSTEM_UI ADPF sessions fire. **The remaining jank
  is SystemUI's notification-stack work per frame**, not scheduling, dexopt or props. Next: diff NSSL/shade code
  against AOSP for Evolution additions that run in `updateChildren` (blur/QS styling), and A/B
  `persist.sysui.disableBlur=1`.
- Charging could not be measured: the phone was on the Mac's USB port (CDP, `dc-mains` offline).

## 3. Workstreams

### A. Charging (P0)

1. **Measure** (`tools/husky-audit.sh charge 30`) with the same 30 W PPS charger at ~15–40 %:
   screen off for 10 min, then screen on (scrolling) for 10 min, then screen on with Extreme Charging on.
   Columns: SoC, current, voltage, battery temperature, USB type (PD vs PD_PPS), `dc-mains` online
   (direct charger engaged), `chg_mdis` state, thermal status, BODEGA profile.
2. **Decide by hypothesis:**
   - `chg_mdis` > 0 with the screen on and `dc-mains` online → thermal (F3). Fix: B-workstream load
     reduction plus Extreme Charging (scaffolded).
   - `usb_type` not `PD_PPS`, or `dc-mains` offline at < 50 % on a PPS charger → negotiation problem.
     Fix: inspect `android.hardware.usb-service` and tcpm logs (`/dev/logbuffer_tcpm`), and compare with
     stock on the same charger.
   - Current capped at a fixed low value with cool temperatures → Battery Defender, adaptive charging or
     charging policy. Check `bd_state`, `charge_deadline`, `charging_policy` and `dumpsys
     android.hardware.health`.
3. **Scaffolded fix:** `patches/vendor_google_husky/0002` adds the `BODEGA` hint and a conservative
   `bodega` charge profile (PID ceiling 25 → 8 below 45 °C; the WIRED state-1 limit moves from 38 °C
   to 45 °C; the 47/55 °C cut-offs, USB-port throttling, the 60 °C battery trip and the kernel's JEITA
   limits are unchanged). The existing controller then sets `bodega_supported=1` and shows the tile;
   it only engages at ≤ 50 % while plugged in. Tune the ceiling (8) from the charge CSV: aim for
   battery ≤ 42 °C.

### B. Fluidity (P0)

1. **Baseline** (`husky-audit.sh baseline`): dexopt status of SystemUI, launcher and Settings right after
   flashing and again after a night on the charger. `verify`/`run-from-apk` on day 0 confirms F1.
2. **Trace** (`husky-audit.sh fluidity 20`, not screen-recording): repeat the video's gestures. In
   Perfetto, check the first frame of each gesture: SystemUI main-thread slices (inflate,
   `NotificationStackScrollLayout`, QS media/artwork), JIT/`verify` activity, CPU frequency at touch-down
   (did the `INTERACTION` hint and the `SYSTEM_UI` ADPF session fire?), and binder waits on system_server.
3. **Scaffolded fix:** `patches/device_google_shusky/0003` turns off `BOARD_USES_SYSTEM_OTHER_ODEX`
   for husky so preopted priv-apps keep their AOT code after zip/OTA installs.
   - Verify: after flashing, `adb shell dumpsys package dexopt com.android.systemui` should show
     `speed-profile`/`speed` from `/system_ext/.../oat`, before any background dexopt.
   - If confirmed, port the same change to kodiak, grizzly, cubs and yogi.
4. **Release variant:** build husky as `user` like kodiak (change `lunch` in `~/husky-build.sh`), keeping
   userdebug for personal test builds. A/B with the trace before announcing anything as a speed-up.
5. **Only if the trace points there:** shade blur cost (`persist.sysui.disableBlur=1` A/B), notification
   inflation, or LMK pressure (`am_kill` during the gesture). Nothing in the trees justifies changing these
   blind.

### C. Stability (P1)

- `baseline` captures dropbox crashes, ANRs, `am_kill`, SELinux denials and power HAL state.
- Husky inherits every shared `frameworks/base` patch made for the Pixel 11 (AOD dimming, Dreamliner
  battery data, Typeface, NetworkPolicy, Extreme Charging) without being tested on husky. Check
  ISS-20261020-01 (SystemUI restart after unlock on kodiak) on husky too.
- Add husky to the device gate after every shared-tree change, not just at husky releases.

## 4. Release gate for the next husky build

| Check | Target |
|---|---|
| SystemUI dexopt right after flashing | `speed-profile` or better (F1 fixed) |
| `gfxinfo` SystemUI, shade + QS + drawer scenario | janky frames < 5 %, 99th percentile < 33 ms, no frame > 100 ms |
| Charging 15 → 50 %, screen off, 30 W PPS | within 10 % of stock Pixel OS on the same charger |
| Charging, screen on, Extreme Charging on | measurably faster than off; battery ≤ 42 °C |
| Extreme Charging tile | shown on husky, auto-off on unplug or at 100 % |
| Device gate | 10/10, zero new denials |

## 5. Files

| Path | Purpose |
|---|---|
| `tools/husky-audit.sh` | `baseline`, `fluidity`, `charge` capture over adb |
| `tools/husky-fluidity.pbtxt` | Perfetto config (sched, freq, gfx, frame timeline, power rails, thermal) |
| `patches/vendor_google_husky/0002-...BODEGA...patch` | Extreme Charging hint + `bodega` charge profile (dry-run applied to `~/evolution`) |
| `patches/device_google_shusky/0003-...system_other...patch` | Keep app odex on /system (dry-run applied) |
