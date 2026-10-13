# LineageOS: NotificationAttentionHelper null dereference with favorites call lights

**Status (2026-10-13):** ready to submit, not submitted. LineageOS takes changes only through Gerrit
(review.lineageos.org), which needs Daryl's own LineageOS account with an SSH key. This Mac has neither, and Claude
doesn't create accounts.

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

## Submitting (one time setup, then one push)

1. Sign in at https://review.lineageos.org and add an SSH public key under Settings > SSH keys.
2. In any Evolution X or LineageOS tree (the build server's works):

```bash
cd frameworks/base
git fetch https://github.com/LineageOS/android_frameworks_base lineage-24.0
git checkout FETCH_HEAD
git am <path>/lineage-frameworks_base-0001-NotificationAttentionHelper-favorites-npe.patch
git push ssh://<gerrit-username>@review.lineageos.org:29418/LineageOS/android_frameworks_base HEAD:refs/for/lineage-24.0
```
