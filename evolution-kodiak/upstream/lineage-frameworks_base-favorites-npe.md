# LineageOS: NotificationAttentionHelper null dereference with favorites call lights

**Status (2026-10-13): submitted** as https://review.lineageos.org/c/LineageOS/android_frameworks_base/+/507761
(`lineage-24.0`, change `I0685ba9be6d8127d37d950140c5cbad603d1382b`). Gerrit account `denson9874` (Daryl signed the
Individual Contributor Agreement); the commit author is the account's Gmail address, as Gerrit requires (Daryl
approved that for this change only). Pushed from the build server with `~/.ssh/lineage_gerrit_ed25519`. To amend it,
keep the Change-Id and push to `refs/for/lineage-24.0` again. When it merges and reaches Evolution X, drop
`patches/frameworks_base/0002-…` from the trees.

- **Bug:** in `lineage-24.0`, `NotificationAttentionHelper`'s constructor creates `LineageNotificationLights`, whose
  constructor runs the `LedUpdater` callback straight away. `updateLightsLocked()` then runs before
  `mLineageNotificationLights` is assigned, and the `favoritesIncomingCallLights()` block calls
  `mLineageNotificationLights.showLightsScreenOn()` without a null check. With the AOSP flag
  `com.android.server.notification.favorites_incoming_call_lights` enabled, system_server crashes in
  `NotificationManagerService.onStart` on every boot. Official builds keep the flag off (AOSP enables it only in
  trunk_staging), which is why nobody has hit it.
- **Found:** enabling the flag for HiLight on the Pixel 11 Pro XL (HANDOFF 2r).
- **Patch:** `lineage-frameworks_base-0001-NotificationAttentionHelper-favorites-npe.patch`, rebased on
  LineageOS/android_frameworks_base `lineage-24.0` (`6cdc375a2`), applies cleanly, noreply author, Change-Id included.

