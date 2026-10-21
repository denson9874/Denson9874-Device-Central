# Kernel Review & Technical Note for Espada Kernel (Kevtrejo37)

**Target Repository:** [atrejokm301/espada-kernel](https://github.com/atrejokm301/espada-kernel)  
**Authors:** Daryl Denson & Evolution X Kodiak Bringup Team  
**Date:** October 14, 2026  
**Subject:** Simple LMK & Android 14–17 Userspace `lmkd` Boot Abort Analysis, Root Cause, and Mitigation Strategies  

---

## 1. Executive Summary

During our integration of the **Espada kernel v3** (Linux 6.12.92 with CASS scheduler and Simple LMK) into Evolution X 17 for the Pixel 11 series (`kodiak`, `grizzly`, `cubs`), we investigated a reproducible userspace abort where Android's low memory killer daemon (`lmkd`) crashed with `SIGABRT` exactly once at boot completion (`sys.boot_completed=1`).

The issue stems from an upstream design flaw in AOSP `system/memory/lmkd/lmkd.cpp` when interacting with the `-EOPNOTSUPP` guard in Espada's `kernel/sched/psi.c`.

This review explains:
1. The exact mechanism and root cause in AOSP userspace.
2. The ROM-side fix applied in Evolution X.
3. A kernel-side enhancement that allows Espada kernel to run seamlessly on **stock Pixel OS and any unpatched AOSP ROM** without triggering the `lmkd` boot abort.

---

## 2. Background: The Kernel PSI Guard

In `kernel/sched/psi.c`, Espada kernel introduces a targeted guard in `psi_trigger_create`:

```c
/*
 * Simple LMK owns low-memory kills. Android's lmkd only defers to the
 * in-kernel killer (lowmemorykiller.minfree) when its PSI setup fails,
 * so refuse system-level memory triggers - the equivalent of the !PSI
 * requirement in Sultan Alsawaf's original Kconfig, without giving up
 * PSI accounting or cgroup triggers.
 */
if (IS_ENABLED(CONFIG_ANDROID_SIMPLE_LMK) && res == PSI_MEM &&
    group == &psi_system)
	return ERR_PTR(-EOPNOTSUPP);
```

### Intent
The intent is sound: Sultan Alsawaf's Simple LMK operates entirely in kernel space (`[simple_lmkd]` and `[simple_lmkd_reaper]`). To prevent dual-killing (where both kernel Simple LMK and userspace `lmkd` monitor memory pressure and kill processes concurrently), system-level memory PSI triggers are rejected with `EOPNOTSUPP`.

---

## 3. The Userspace Failure Mechanism in AOSP `lmkd`

On Android 14, 15, 16, and 17, `lmkd` behaves as follows:

### Phase 1: Early Init (`main()` in `lmkd.cpp`)
At startup, `lmkd` checks for the legacy in-kernel LMK parameter:
```cpp
has_inkernel_module = !access(INKERNEL_MINFREE_PATH, W_OK); // /sys/module/lowmemorykiller/parameters/minfree
use_inkernel_interface = has_inkernel_module;

if (use_inkernel_interface) {
    ALOGI("Using in-kernel low memory killer interface");
    // skips init_monitors()
} else {
    if (!delay_monitors_until_boot || property_get_bool("sys.boot_completed", false)) {
        if (!init_monitors()) return -1;
    }
}
```
Because Espada's `drivers/android/simple_lmk.c` exports `lowmemorykiller.minfree`, `use_inkernel_interface` is correctly set to `true`. `init_monitors()` is skipped, and `monitors_initialized` remains `false`.

### Phase 2: Boot Completed IPC (`LMK_START_MONITORING`)
Once Android finishes booting, `ActivityManagerService` / `ProcessList` in `system_server` sends an IPC command `LMK_START_MONITORING` across the `/dev/socket/lmkd` socket.

In AOSP `lmkd.cpp`:
```cpp
case LMK_START_MONITORING:
    if (nargs != 0)
        goto wronglen;
    // Registration is needed only if it was skipped earlier.
    if (monitors_initialized)
        return;
    if (!property_get_bool("sys.boot_completed", false)) {
        ALOGE("LMK_START_MONITORING cannot be handled before boot completed");
        return;
    }
    if (!init_monitors()) {
        ALOGE("Failed to initialize memory pressure monitors");
        return;
    }
    break;
```

**The Bug in AOSP:**
AOSP developers assumed that if `monitors_initialized` was `false`, it was solely because `delay_monitors_until_boot` was enabled. **`LMK_START_MONITORING` failed to check `use_inkernel_interface`.**

Consequently:
1. `init_monitors()` is called.
2. `init_psi_monitors()` attempts to register triggers on `/proc/pressure/memory`.
3. `kernel/sched/psi.c` returns `-EOPNOTSUPP`.
4. `init_monitors()` fails.
5. `lmkd` logs:
   ```
   lmkd: Failed to register psi monitor for <level> memory pressure: Operation not supported
   lmkd: Failed to initialize memory pressure monitors
   lmkd: Closing connection to system_server due to error: Operation not supported
   ```
6. `lmkd` calls `exit(1)`.

### Phase 3: The `SIGABRT` Tombstone
Calling `exit(1)` runs static C++ destructors, including `Reaper::~Reaper()`.
In `system/memory/lmkd/reaper.cpp`, `Reaper` spawns active worker threads (`mReaperThread`) during early init. Because `Reaper` lacked an explicit destructor to join or detach its running threads, `std::thread::~thread()` invokes `std::terminate()`, generating a fatal `SIGABRT` crash:
```
Abort message: terminating with uncaught exception of type std::__1::system_error: mutex lock failed: Invalid argument
```
Android's `init` restarts `lmkd`, but `system_server` drops its socket connection and must re-establish it.

---

## 4. The ROM-Side Solution

In Evolution X, we resolved this cleanly with a patch to `system/memory/lmkd`:

```diff
--- a/lmkd.cpp
+++ b/lmkd.cpp
@@ -1625,7 +1625,7 @@ static void ctrl_command_handler(int data) {
     case LMK_START_MONITORING:
         if (nargs != 0)
             goto wronglen;
         // Registration is needed only if it was skipped earlier.
-        if (monitors_initialized)
+        if (use_inkernel_interface || monitors_initialized)
             return;
         if (!property_get_bool("sys.boot_completed", false)) {
```
and added an explicit `~Reaper()` destructor that safely detaches active worker threads on exit.

---

## 5. Kernel-Side Improvement Options for Espada Kernel

While ROM developers can patch `lmkd`, users flashing Espada kernel on **stock Pixel firmware** or unpatched custom ROMs will still experience the `lmkd` boot abort on every boot.

To make Espada kernel 100% plug-and-play across all ROM bases, we recommend considering either of the following approaches:

### Option A: Dormant/Silent PSI Trigger (Recommended)
Instead of returning `-EOPNOTSUPP` on system memory triggers, allow `psi_trigger_create` to allocate and return a valid `psi_trigger`, but **do not add it to `group->rtpoll_triggers` or `group->avg_triggers`**.

```c
/*
 * In kernel/sched/psi.c:
 * For system memory pressure under Simple LMK, return a dormant trigger
 * that satisfies userspace registration without generating events.
 */
if (IS_ENABLED(CONFIG_ANDROID_SIMPLE_LMK) && res == PSI_MEM &&
    group == &psi_system) {
    t = kmalloc(sizeof(*t), GFP_KERNEL);
    if (!t)
        return ERR_PTR(-ENOMEM);
    t->group = group;
    t->state = state;
    t->threshold = threshold_us * NSEC_PER_USEC;
    t->win.size = window_us * NSEC_PER_USEC;
    t->event = 0;
    t->last_event_time = 0;
    t->of = of;
    if (!of)
        init_waitqueue_head(&t->event_wait);
    t->pending_event = false;
    t->aggregator = PSI_POLL;
    /* Do NOT add to group->rtpoll_triggers list */
    return t;
}
```

**Benefits of Option A:**
- `write()` to `/proc/pressure/memory` returns success.
- `lmkd` puts the descriptor into `epoll`.
- Because the trigger is not in the active poll list, the descriptor never wakes up.
- `lmkd` never attempts userspace kills, leaving Simple LMK in complete control.
- `lmkd` never aborts, never drops the `system_server` connection, and never generates crash tombstones on any ROM.

### Option B: Documentation / ROM Advisory
If keeping `-EOPNOTSUPP` is strictly preferred, we recommend adding a note in the Espada README/XDA thread advising ROM maintainers that Android 14–17 `system/memory/lmkd` requires the 1-line check `if (use_inkernel_interface || monitors_initialized) return;` under `case LMK_START_MONITORING:` to prevent the boot-time abort.

---

## 6. Closing Note

Espada kernel v3 is performing exceptionally well on the Pixel 11 Pro XL (`kodiak`): thermals, memory management under Simple LMK, and battery drain under the CASS scheduler are noticeably improved compared to stock GKI.

Thank you for your fantastic work on Tensor G6 development!
