# cheetah: heat under mild use (2026-10-21)

Daryl's Pixel 7 Pro (`28231FDH3005GR`), build 20261019 (personal, Magisk 30.7), 52 h uptime, data from
`dumpsys batterystats` (4 h 21 m on battery since the last charge), `/proc`, sysfs and `dumpsys` over adb with root.

## Where the energy goes

| Component | mAh since charge | Note |
|---|---|---|
| **CPU** | **1131 of 1192** | only 234 of it with the screen on: ~900 mAh of CPU work with the screen off or in AOD |
| GPU | 278 | SystemUI rendering (below) |
| Mobile radio | 225 | |
| Wi-Fi | 208 | |
| AOD (ambient display) | 126 | AOD averaged ~270 mA, screen on ~945 mA |

| UID | mAh | What |
|---|---|---|
| **u0a108 `com.dergoogler.mmrl`** | **593 (all background)** | MMRL (Magisk module manager, user-installed): permanent foreground `RepositoryService`; 1 h 40 m CPU in 4 h 21 m, mostly at the mid cluster's top frequency, ~38 min of it screen off |
| 1000 (system) | 433 | |
| u0a425 `com.android.systemui` | 171 | 4 h 37 m CPU over 52 h; main thread 2 h 10 m, RenderThread 1 h 37 m; idle in AOD (1 % of a core) |
| 0 (root) | 103 | |

## Findings

1. **MMRL is the largest heat source, and it isn't the ROM.** Half the battery drain and a CPU pinned at high
   frequency in bursts, screen on and off. Fix on the phone: turn off MMRL's background repository updates,
   restrict its battery use, or uninstall it (Magisk's own app manages modules).
2. **SystemUI rendering is expensive** (high main-thread and RenderThread time, GPU 278 mAh). Same SystemUI code
   and the same cost traced on husky: `NSSL#updateChildren` and full traversals on every shade frame
   (`evolution-husky/HUSKY_PERF_CHARGING_PLAN.md` 2a). The 2026-10-21 upstream sync adds two SystemUI efficiency
   fixes (lockscreen widgets no longer poll in the background; event-driven Wi-Fi icon); the next cheetah build
   includes them.
3. **The phone rarely sleeps.** Screen off, it was awake 49.5 % of the time (2 h 9 m of 3 h 17 m); 1129 of 4184
   suspend attempts failed since boot. Causes: suspend aborted by pending Wi-Fi wakeup sources (1 h 18 m, 53×),
   `alarmtimer` EBUSY (46×), and the backoff after each failure (`SuspendControl.*Delay`, 1 h 46 m). Wi-Fi traffic
   itself is normal (865 data wakeups in 2 days, 90 % unicast). Recheck after MMRL is dealt with: its work and
   network use drive much of this.
4. **Leaked ADB multicast lock:** `AdbMulticastLock-comm` (uid 1000) is held although wireless debugging is off
   (`adb_wifi_enabled=0`), so APF passes multicast (`mcast: ALLOW`). Minor (81 multicast wakes in 2 days); check
   whether it's tied to the USB ADB connection.
5. **Ruled out:** power HAL/kernel mismatch (all 72 nodes `powerhint.json` writes exist on the source-built
   6.1.157 kernel), thermal throttling (status 0, no cooling device active at rest), `wpa_supplicant -dd` (AOSP's
   standard rc; the framework sets the log level).

## Next

- Deal with MMRL, run the phone for a day, and compare `dumpsys batterystats` (awake % screen off, CPU mAh, temps
  under the same light use) with these numbers.
- Flash the 2026-10-21 build (upstream SystemUI fixes) and repeat.
- SystemUI shade cost: shared fix with husky.
