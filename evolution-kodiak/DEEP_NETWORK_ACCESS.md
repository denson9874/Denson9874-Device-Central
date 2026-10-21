# Apps with no network until the user enables it: deep dive (2026-10-19)

Labels follow GEMINI.md: **Evidence** (read from source, a log, a report or upstream), **Inference**
(deduced from evidence), **Unknown** (needs a phone or a log). Source is the server tree
`~/evolution` (read only). Unless a path starts with another repository, it is relative to
`frameworks/base`. "NPMS" means `services/core/java/com/android/server/net/NetworkPolicyManagerService.java`.
No phone was available, and **no log we hold shows the block happening**. So the ranked causes
below are supported by code and by user reports, not observed on a device.

## 0. Bottom line

1. **What users see is Lineage's `POLICY_REJECT_ALL`** (Evidence, section 1). App info > Mobile data &
   Wi-Fi shows "Allow network access" off, with "Wi-Fi data" and "Mobile data" off and greyed out.
   That matches the reports' wording ("most apps don't have wifi/mobile data access"). Two things
   confirm the policy store: the users' workaround, Reset app preferences, deletes every uid policy
   for the user (section 4), and so does Lineage's per-app toggle.
2. **Most likely trigger: Play's archived ("pre-archived") restore installs.** Evidence, code: an
   archived install sends `ACTION_PACKAGE_ADDED` while the package isn't installed. `INTERNET` then
   reads as denied, so the unpatched receiver blocks the app every time, with no race involved
   (section 3). Evidence, log: Play on our build runs with
   `Archiver: Flag ENABLE_PRE_ARCHIVING_FOR_RESTORES is true`.
   - Inference: the uid survives when the real APK arrives, so the block outlives it.
   - This fits the field pattern: "most apps", after a clean flash, on users who restore. Ashray, who
     clean-flashed, was not affected; whether he skipped restore is Unknown.
   - Unknown: no log shows an `archival: true` install yet.
3. **The race claimed by Gerrit 505011 is not supported by our source.** For a normal install or
   update, PackageManager grants permissions during commit, before the broadcast (section 3).
4. **Patch 0007 is right for new installs, needs one correction (section 6), and heals nothing that is
   already blocked.** Healing options are in section 7.
5. **Unsupported claims in our own drafted replies:**
   - `community/replies/COMMUNITY_REPLIES_20261017.md` says the default "is being addressed in system
     overlays for Sunday's release".
   - `COMMUNITY_REPLIES_20261019.md:120` says "until Sunday's overlay update resolves the clean-flash
     default permissions".
   - No overlay controls this. It is framework code, and the fix is a framework patch.
   - Daryl's Telegram answer ("not an issue, it's a feature … to aid in battery saving") is not
     backed by anything in source either: no code blocks new apps by default for battery reasons.

### Ranked causes

| # | Cause | Fits the reports? | Strength |
|---|---|---|---|
| 1 | Archived install `PACKAGE_ADDED` (Play pre-archiving on restore) → `REJECT_ALL`, kept after unarchive | Yes: many apps, clean flash with restore, toggle shows off, Reset fixes it | Code: Evidence. On device: Unknown |
| 2 | By design: an app first installed without `INTERNET`, later updated to request it, stays blocked | Yes for single apps | Evidence: Lineage's own test note in change 491269 expects exactly this |
| 3 | Dirty flash over stock or a ROM whose `netpolicy.xml` has no Lineage version → `migrateToPolicyRejectAll` blocks every non-system app | Yes, but only for dirty flashes; the reporters clean-flashed | Code: Evidence (`NPMS:2908-2955`, `:3299-3304`) |
| 4 | Package state changes again (uninstall, archive) before NPMS's handler processes `PACKAGE_ADDED` | Rare | Inference |
| 5 | Install/update permission race (505011) | No mechanism found | Not supported |

## 1. How the block works and what the user sees (Evidence)

- `lineage-sdk/packages/LineageSettingsProvider/.../LineageDatabaseHelper.java:518` sets
  `Settings.Global.RESTRICTED_NETWORKING_MODE=1` by default. NPMS reads it at `:1155-1162`.
- `FIREWALL_CHAIN_RESTRICTED` is an allowlist. NPMS gives a uid ALLOW unless its policy has
  `POLICY_REJECT_ALL` (`NPMS:5229-5312`: `updateRestrictedModeForUidUL`,
  `updateBlockedReasonsForRestrictedModeUL`, `isUidBlockedOnAllNetworks`).
- The Lineage receiver (`NPMS:1519-1551`) is the only automatic writer of `REJECT_ALL` besides the
  one-time migration (`:2908-2955`). Nothing removes `REJECT_ALL` except:
  - the user's toggle (`Settings/.../datausage/AppDataUsage.java:414, 428-435`);
  - `ACTION_UID_REMOVED` (`NPMS:1587-1602`), sent only when the app id itself is removed
    (`pm/RemovePackageHelper.java:412`). An uninstall that keeps data, or an archive, keeps the uid
    and its block;
  - Reset app preferences (section 4).
- UI: `AppDataUsage.java:334-356`. "Allow network access" (`cm_strings.xml:120`) is unchecked when
  `REJECT_ALL` is set, and "Wi-Fi data" and "Mobile data" are then unchecked and disabled.

## 2. Every per-app network block in our source

Writers were found by grepping frameworks/base, Settings, lineage-sdk, the Connectivity and
Permission modules and `vendor/evolution*` for `addUidPolicy`, `setUidPolicy`, `removeUidPolicy` and
`POLICY_REJECT_*`.

| Mechanism | Automatic writer | Matches "off until turned on by hand"? | How to see it |
|---|---|---|---|
| `POLICY_REJECT_ALL` (Lineage receiver) | NPMS on `PACKAGE_ADDED` | **Yes** | `dumpsys netpolicy`: `UID=<uid> policy=262144 (REJECT_ALL)`; logcat `NetworkPolicy: ACTION_PACKAGE_ADDED for uid=…, no INTERNET` |
| `migrateToPolicyRejectAll` | Once, on an Android 12+ policy file without a Lineage version | Yes, every non-system app at once | Same |
| Backup restore of uid policies (`NPMS:3229-3243`, `readUidAttribute`) | Keyed by package; skipped if the package isn't installed at restore time (`UserHandle.isApp(-1)` fails) | Only restores choices made on the old phone | Same |
| `POLICY_REJECT_WIFI/CELLULAR/VPN`, `POLICY_LOCKDOWN_VPN` (`NPMS:1315-1328`) | None found (Settings toggles only) | Per transport only | Same, `REJECT_WIFI` etc. |
| `POLICY_REJECT_METERED_BACKGROUND`, Data Saver | None found (`DynamicDenylistManager` has no caller) | No: background on metered networks only | `Restrict background:` in `dumpsys netpolicy` |
| Android 17 `Settings/.../wifi/repository/DataUsageRepository.kt:150-172`, used by `AppDataUsageScreenApi.kt:90,129` (app-functions API screen) | `setUidPolicy` with a whole value | Opposite effect: **wipes** Lineage bits, including a user's `REJECT_ALL`. Separate bug | n/a |
| `FIREWALL_CHAIN_BACKGROUND` (`NPMS:1197`), standby/restricted bucket, Doze, Low Power Standby | AOSP power management | No: background only, and the toggle doesn't touch them | `blocked_state` in `dumpsys netpolicy` |
| Socket destroys (141 `InetDiagMessage: Destroyed live tcp sockets for uids=…` lines in the 10-18 log) | `Connectivity/.../ConnectivityService.java` `destroyPendingSockets` (`:4486-4498`) and `closeSocketsForFirewallChainLocked` (`:16937-16950`) | No: stock behaviour when apps go to the background or are frozen | n/a |
| BPF `INTERNET` gate (`Connectivity/bpf/progs/netd.c:1171-1198`, PermissionMonitor `:1225-1240`) | Recomputed on every `PACKAGE_ADDED` | No: it heals itself on the next broadcast, and the toggle doesn't affect it | `sUidPermissionMap` in `dumpsys connectivity trafficcontroller` |
| Android 17 local-network protection (`netd.c:301-315, 380-400`; `ACCESS_LOCAL_NETWORK` is dangerous and feature-flagged, `core/res/AndroidManifest.xml:2687`) | Runtime permission | No: blocks LAN destinations only | `sLocalNetNoteOpsEnabledBpfBoolean` etc. in trafficcontroller |
| Stale fw_standby DROP (2022 Lineage report) | n/a | No: a standby DENY isn't cleared by the network-access toggle (`setUidPolicyUncheckedUL`, `NPMS:3740-3753`, only refreshes the restricted and metered rules), so it wouldn't match "toggle fixes it". The 2022 report itself was not located | `sUidOwnerMap` `STANDBY_MATCH` |
| Evolution additions | None in `vendor/evolution-priv` or Evolution's Settings changes | n/a | n/a |

## 3. When `checkUidPermission(INTERNET)` is false at `ACTION_PACKAGE_ADDED`

Evidence, the check:
- `services/permission/.../permission/PermissionService.kt:564-620` returns DENIED when
  `getPackage(uid)` is null.
- `pm/ComputerEngine.java:1139-1146` and `:2361-2390`: `getPackage(uid)` only returns packages
  **installed for that user**.
- NPMS's `isSystemApp()` uses `getPackagesForUid(uid)[0]` (`NPMS:7364-7370`), so it is also false
  for a package that isn't installed.

| Case | Broadcast | Grant before broadcast? | Result |
|---|---|---|---|
| New install, update | `pm/InstallPackageHelper.java:3216-3273` → `pm/BroadcastHelper.java:567-700`, posted on PM's handler (`:1002`) | Yes, `InstallPackageHelper.java:2925` (`updateSettingsInternalLI`, during commit) | Granted |
| **Archived install** | Same, with `EXTRA_ARCHIVAL` (`BroadcastHelper.java:614-617`, `:824-826`) | No: `pm/PackageManagerService.java:1566-1590` sets `pkg=null` and `installed=false` for every user | **DENIED, every time** |
| Unarchive (real APK over the placeholder) | `PACKAGE_ADDED`, first time for the user | Yes | Granted, but the archived-step block stays |
| Archive of an installed app (`pm archive`, auto-archive) | `PACKAGE_REMOVED` with `EXTRA_ARCHIVAL` (`BroadcastHelper.java:1073-1105`); no `PACKAGE_ADDED`, no `UID_REMOVED` | n/a | No new block; existing blocks persist |
| Existing package for another user (work profile, private space) | `InstallPackageHelper.java:830` | Yes, `:818` (`onPackageInstalled(..., userId)`) runs first | Granted |
| Unhide | `PackageManagerService.java:6384` | Still installed | Granted (Inference) |
| System app update removed | `BroadcastHelper.java:1037` | n/a | Skipped (`isSystemApp`) |
| Adoptable storage not mounted | Deferred in `PermissionService.kt:2471-2493` | Possibly not | Pixels have no SD card. Related unmerged Lineage fix 486883 |
| Shared UID | `ComputerEngine.java:2366-2382` | Per appId | Granted if any member is installed |
| State changed before NPMS's handler runs | any | n/a | DENIED (Inference, rare) |

Archived installs are only allowed for a package that doesn't exist yet
(`pm/PackageInstallerSession.java:2617-2622`), i.e. a fresh restore placeholder. Inference: the uid
is kept when the real APK arrives, because the `PackageSetting` and data are kept
(`InstallPackageHelper.java:669` handles an old setting with `pkg == null`). The reproduction test in
section 8 confirms or refutes this.

## 4. Field evidence

- Evidence, reports:
  - `community/daily_raw/raw_20261017.json`: Lubomir, after a clean flash: "some apps cant access
    mobile/wifi data", also on earlier builds. Ashray, also a clean flash, had data access by default.
    He had never needed to enable it, and dirty-flashed in between.
  - `raw_20261019.json`: Igor: Reset app preferences "makes most apps have data access again".
    DoubtTM on XDA: "most apps dont have wifi/mobile data access by default".
- Evidence, why Reset works:
  - Settings' `ResetAppsHelper.resetApps()` calls `IPackageManager.resetApplicationPreferences`.
  - That lands in `pm/PreferredActivityHelper.java:612-638`, which calls
    `NetworkPolicyManagerInternal.resetUserState`.
  - `NPMS.resetUserState` → `removeUserStateUL` deletes **every uid policy of the user**, then
    `updateRulesForGlobalChangeAL(true)` refreshes the restricted allowlist (`NPMS:5648-5658`).
  - Side effects: it also clears deliberate blocks, runtime permissions, default apps and app ops.
  - Inference: it doesn't re-send allowed transports (`sendUidsAllowedTransportsUL` runs only at init,
    `:1277`), so cleared Wi-Fi-only or mobile-only blocks may linger in Connectivity until reboot.
- Evidence, user log `~/Downloads/logcat.txt` (10-18 build, clean-flash setup, ends at 21:06:44):
  - Play logs `ENABLE_PRE_ARCHIVING_FOR_RESTORES is true` and
    `ENABLE_SIMPLIFIED_PRE_ARCHIVING_RESTORE_FLOW is true` (21:06:14.672 and 21:06:16.426).
  - All 16 `PACKAGE_ADDED` in the log (`AS.AudioService` lines) have `archival: false`. They are
    `restore_vpa` preloads.
  - There are no `NetworkPolicy` lines at all. The log ends before personal apps restore, so it
    neither confirms nor rules out cause 1.

## 5. Upstream

- **Gerrit 505011** (lineage-23.2), "NetworkPolicy: Clear stale automatic network restrictions":
  - Status NEW, patch set 1, created and last updated 2026-09-27, owner Bruno Martins (bgcngm).
  - Reviewers Tommy Webb and Michael Bestas have **no votes**, there are **no comments**, and the
    commit says `Assisted-by: Codex:GPT-5`.
  - Its marker is an in-memory `SparseBooleanArray`, lost on reboot. It heals a uid only when a later
    `PACKAGE_ADDED` reports `INTERNET` in the same boot.
  - It would not heal the archived case after a reboot, and not at all if the unarchive happens in a
    later boot.
  - Its premise (a grant missing during install or update) is not shown by our source (section 3).
- **[LineageOS/issues#746](https://github.com/LineageOS/issues/issues/746)** (lineage-23.2,
  gts7lwifi, open):
  - Its only comment is bgcngm's "Very likely can be fixed with" 505011, which is not a confirmation.
  - The reporter says the block "always comes back after a reinstall". Inference: an uninstall that
    keeps data (the uninstall dialog's keep-data option) keeps the uid and its policy.
- **lineage-24.0** has the same Lineage firewall stack merged 2026-09-09: 491265-491271, including
  "Restrict apps without INTERNET permission" (491269). 491269's test note expects an app updated to
  a version with `INTERNET` to **stay** blocked, so that persistence is intended.
  - Open: 502353, a `fixup! Transport-based toggle` with bit checks. Our tree already has its content,
    via Evolution `3f7e1364a5`.
  - Open, lineage-22.2: 486883, adoptable-storage apps blocked at boot. Not relevant on Pixels.
- **Evolution X `cnb`** NPMS history (GitHub, 2026-10-19):
  - It is the Lineage stack plus `7c1d3637bd` (wtf → warning for a missing subscriberId) and
    `3f7e1364a5`.
  - Our tree's NPMS is exactly `cnb` plus 0007: 0007's base blob `6e507a8521` is `7c1d3637bd`'s result.
  - Neither Lineage nor Evolution has a fix for the receiver.

## 6. Review of patch 0007 (`de0bb43ace`)

What is right:
- The `EXTRA_ARCHIVAL` skip is correct, and it is the part that matters (cause 1).
  `mInternetPermissionMap.delete` and `updateRestrictionRulesForUidUL` still run.
- Deciding from requested permissions:
  - Shared uids: one requesting member suffices, matching per-appId grants.
  - Other users: `getPackageInfoAsUser(..., UserHandle.getUserId(uid))`.
  - Apps that truly lack `INTERNET` are still blocked, as Lineage intends. That includes an
    unarchived app that really lacks it.
- Lock ordering: the new calls run under `mUidRulesFirstLock`, like the existing `isSystemApp()` and
  `hasInternetPermissionUL()`. The only PackageManager-to-NPMS call is
  `PreferredActivityHelper.java:638` (`resetUserState`), which runs **after** PM has released
  `mPm.mLock` (`:620-630`). So 0007 creates no PM-lock/NPMS-lock cycle (Evidence).

What is wrong:
- **Bug:** `requestsInternetPermission` returns false when `getPackagesForUid(uid)` is null, i.e.
  when the package isn't installed for that user at handling time (cause 4). The patch then still
  blocks it, and if the app was archived in that window, the block outlives unarchiving.
- Minor: when the race path skips the block, nothing re-runs the per-uid power rules once `INTERNET`
  shows up. Process-state changes refresh them soon after (Inference). This does not affect access.
- Not addressed: existing blocks (section 7), and cause 3 (dirty flash from stock).

Corrected diff on top of 0007:

```diff
@@ private boolean requestsInternetPermission(int uid) {
             final PackageManager pm = mContext.getPackageManager();
             final String[] packageNames = pm.getPackagesForUid(uid);
-            if (packageNames == null) return false;
+            // Not installed for this user any more (removed, archived or changing): there is no
+            // evidence that the app lacks INTERNET, so don't restrict it.
+            if (packageNames == null) return true;
             for (String packageName : packageNames) {
@@
                         if (requestsInternetPermission(uid)) {
                             Slog.w(TAG, "ACTION_PACKAGE_ADDED for uid=" + uid
-                                    + ", INTERNET requested but not granted yet; not restricting");
+                                    + ", INTERNET requested or package unresolved; not restricting");
```

## 7. Healing apps that are already blocked (proposal, not implemented)

- **Prevent future stale blocks with a persisted marker.**
  - Write a Lineage attribute (e.g. `autoReject="true"`) on the uid entry in `netpolicy.xml`. The
    receiver sets it when it adds `REJECT_ALL`.
  - On `PACKAGE_ADDED`, and once after `readPolicyAL` at `systemReady`: if the marker is set and the
    uid now holds and requests `INTERNET`, remove `REJECT_ALL` and the marker.
  - Any binder `setUidPolicy`/`addUidPolicy`/`removeUidPolicy` (the user's toggle, Settings) clears the
    marker, so the user's choice wins.
  - Drop it in `onUidDeletedUL` and on restore (`forRestore`).
  - Unlike 505011 this survives reboots. Cost: a file-format addition, which a downgrade ignores
    harmlessly.
- **Existing blocks have no marker and can't be told apart from a user's choice.** Options:
  - (a) A one-time migration (bump `LINEAGE_VERSION_LATEST` to 3) that clears `REJECT_ALL` from every
    app that holds `INTERNET`. It heals everyone, but undoes deliberate blocks, so it needs a release
    note.
  - (b) The same, limited to apps whose install reason is device restore or setup. Cause 1 targets
    exactly those, and apps the user installed are untouched. Unknown: which install reason Play's
    pre-archived restores carry. Check with `dumpsys package` on an affected phone first.
  - (c) Leave them, and tell users to switch "Allow network access" on per app. **Not** Reset app
    preferences: it also wipes permissions, default apps and deliberate blocks.
  - Recommendation: (b) once one phone confirms the install reason, otherwise (c). The decision is
    Daryl's.

## 8. Diagnostic recipe (affected phone)

Get the app's uid:
```bash
adb shell cmd package list packages -U <pkg>
```

Expect `1`. With `0`, `REJECT_ALL` has no effect and the cause is elsewhere:
```bash
adb shell settings get global restricted_networking_mode
```

Look for the uid's line: `262144 (REJECT_ALL)` means blocked by policy (all networks).
`REJECT_WIFI`/`REJECT_CELLULAR` block one transport. `REJECT_METERED_BACKGROUND` blocks background
use only.
```bash
adb shell dumpsys netpolicy
```
In the same dump, the event log near the end has lines like `Policy for <uid> changed from 0 (NONE) to
262144 (REJECT_ALL)`, kept in memory since boot. It can't tell the receiver from the user's toggle; the
logcat below can.

Under `sUidOwnerMap`, the uid's line lacks `RESTRICTED_MATCH` when it is blocked by restricted mode.
This test is from Lineage change 491269. Under `sUidPermissionMap`, an entry without INTERNET means the
BPF socket gate, a different problem.
```bash
adb shell dumpsys connectivity trafficcontroller
```

Check per-user `installed=`, `installReason=`, `firstInstallTime`, and
`android.permission.INTERNET: granted=true`. An installed app that has INTERNET granted and still shows
`REJECT_ALL` was blocked automatically, or by the user.
```bash
adb shell dumpsys package <pkg>
```

Look for `NetworkPolicy: ACTION_PACKAGE_ADDED for uid=<uid>, no INTERNET`, and for the matching
`AS.AudioService: received android.intent.action.PACKAGE_ADDED … archival: true … uid <uid>`. Both are
there only if the log still covers the install. On a 0007 build, the Slog.w line marks the race.
```bash
adb logcat -b system -b main -d
```

Questions for the reporters (cheap discriminators): did you restore apps from a Google backup during
setup? Are the blocked apps exactly the restored ones? Ashray: did you skip restore?

**Reproduction test** (unpatched build, throwaway test app that requests INTERNET; uninstalling it
deletes its data). Not run. It follows CTS `PackageManagerTest.java:3140-3170`.

```bash
adb install -r -i com.android.vending test.apk
```
```bash
adb shell pm archive <pkg>
```
```bash
adb exec-out pm get-archived-package-metadata <pkg> > meta.hex
```
```bash
adb uninstall <pkg>
```
```bash
adb shell "pm install-archived -r -i com.android.vending -t -S $(wc -c < meta.hex | tr -d ' ')" < meta.hex
```
```bash
adb shell cmd package list packages -U <pkg>
```
Then run `dumpsys netpolicy`. Expected on an unpatched build: `REJECT_ALL` on the new uid. Then install
the real APK over the placeholder:
```bash
adb install -r -i com.android.vending test.apk
```
Confirm the uid is unchanged and `REJECT_ALL` is still there. On a 0007 build the archived step should
log nothing and leave the uid without a policy.

## 9. Still unknown

- Whether Play's pre-archiving restore runs on our phones, and with which install reason. Needs a
  logcat taken during a restore, or the reproduction test.
- Whether the uid really survives unarchiving (strong inference, not yet observed; the test answers it).
- The exact `dumpsys` text of `installReason` and of the `sUidPermissionMap` entries was not checked on
  a device.
