# Community Replies Draft (2026-10-21)

Review and approve these response drafts before posting to Telegram or XDA.

---

## Telegram Replies (`@ExpressiveLauncherFeedback`)

### In reply to Ashray V K:

```markdown
> Ashray V K: "I thought it does. In the manager, it says SuSFS version Supported v2.3.0 (GKI)"

**[ISS-20261021-01] Confirmed**
Confirmed, Ashray! Espada kernel v3 includes native KernelSU with SuSFS v2.3.0 support on GKI Linux 6.12.92.
```

### In reply to Ashray V K:

```markdown
> Ashray V K: "Also - im unable to togglle the "Use Now Playing" option, could it be due to my previous installation of now playing? I tried clearing data and cache, but still unable to proceed. Perhaps somebody else can test this out too"

**[ISS-20261019-01] Update**
Thanks for the follow-up and video clip, Ashray! The association block between ASI and PCS is tracked under `ISS-20261019-01` and already patched in tree (`device_google_kodiak` 0f60690, `vendor/gms` 1d69071) for the next build.
```

### In reply to Ashray V K:

```markdown
> Ashray V K: (At a Glance logcats: At_a_glance.log, At_a_glance_failure_2.log)

**[ISS-20261019-05] Logs received, root cause found**
Thanks for the logs, Ashray! Every toggle attempt fails with `association not allowed between packages com.google.android.as and com.google.android.as.oss`: the 10-18 build's `nowplaying.xml` sysconfig cuts Android System Intelligence off from Private Compute Services, so ASI can't save the At a Glance setting and the switch reverts. It's the same cause as your Now Playing toggle (`ISS-20261019-01`), already fixed in tree (`device_google_kodiak` 0f60690, `vendor/gms` 1d69071) for the next build. Until then the master At a Glance toggle in Home settings works. (Side note: your logs show Vector/LSPosed hooking ASI with a PCS module. It isn't the cause, but if anything still misbehaves after the update, retest with it off.)
```

### In reply to Christoph 🇮🇱:

```markdown
> Christoph 🇮🇱: "I know, I know—it’s just that I personally prefer *kowsu* or *bakasu*. It’s a personal thing. And the ota is only for update and not clean? Or I can come from stock?"

**Support / Clarification**
OTA packages (`Apply update` / Settings > System > System updates) are strictly for incremental updates from an earlier build of the ROM. When coming from stock Pixel firmware or another custom ROM, a clean flash is required via fastboot (`fastboot flash boot`, `fastboot flash vendor_boot`, wipe/format data in recovery, and sideload the ROM zip).
```

### In reply to Christoph 🇮🇱:

```markdown
> Christoph 🇮🇱: "On the previously version I can disable live display... That I can not disable in the new realse"

**[ISS-20261019-05] Root cause found, fixed in next build**
Thanks for the screen recording, Christoph! The logs show this isn't the launcher: At a Glance saves those sub-settings (Live Display included) through Private Compute Services, and the 10-18 build blocks Android System Intelligence from talking to PCS ("association not allowed"), so the save fails and the switch flips back. Same cause as the Now Playing bug (`ISS-20261019-01`); the fix is in tree (`device_google_kodiak` 0f60690, `vendor/gms` 1d69071) and ships with the next build. Until then, turning At a Glance off entirely from Home settings still works.
```

### In reply to Igor:

```markdown
> Igor: "For some reason only disabling at a glance from home screen setting works, but not the more specific options"

**[ISS-20261019-05] Root cause found, fixed in next build**
Thanks for confirming, Igor! Ashray's logs pinned it down: the 10-18 build cuts Android System Intelligence off from Private Compute Services (`association not allowed`), so ASI can't save the At a Glance sub-settings and the switch reverts. Same cause as Now Playing (`ISS-20261019-01`), fixed in tree for the next build. The master At a Glance toggle in Home settings works until then.
```

### In reply to Igor:

```markdown
> Igor: "Just for some reason I keep getting system ui restarts sometimes after unlocking phone... Ok seems to be consistently happen when I unlock phone, and instantly try to open qs... File, Downloaded, Downloads.zip, 8.8 MB logs"

**[ISS-20261020-01] Crash Logs Received & Verified**
Thanks for capturing the crash dump and logcat, Igor!
The trace confirmed the exact failure:
`FATAL EXCEPTION: main` in `com.android.systemui`, `java.lang.NoSuchMethodError: No interface method onRequestRate(IF)V in class Landroid/hardware/fingerprint/IUdfpsRefreshRateRequestCallback;` at `UdfpsTouchOverlay.requestDisplayRateIfCurrent`.
Root cause is confirmed: a stale AOSP SystemUI.apk from `out/` staging was packaged alongside SystemUIGoogle, and the 10-18 framework dropped `onRequestRate`. The stale build artifact has been purged from staging and will be cleanly resolved in the next build. Tracked under `ISS-20261020-01`.
```

### In reply to Loic:

```markdown
> Loic: "Merci pour ta réponse. J'avais activé l'option hide framework-res.apk pour éviter d'avoir cette erreur dans Duck mais c'est ça qui bloquait. Maintenant Chrome a jour et fonctionne parfaitement, juste a trouvé comment hide"

**[ISS-20261020-02] Resolved (User Config)**
Merci Loic! Excellent isolation. Hiding `framework-res.apk` breaks resource resolution for Chrome during launch. Glad to hear disabling that option restored Chrome to 100% functionality. Closed as user configuration / module conflict.
```

### In reply to Pratik:

```markdown
> Pratik: "Hi @denson9874 thanks for the launcher update. It's smooth! Few feedback: 1. The app drawer top search bar covers the top icon bar 2. In app drawer hide apps, the work profile apps do not have a work profile badge... 3. Can you see if appsfolder can have a icon (not cover)?... 4. App icon size issue still persists... 5. Icons within the folder are also not same in size"

**[ISS-20261020-03] Expressive Launcher Feedback Noted**
Thanks for the detailed breakdown, Pratik!
1. **App drawer search bar overlap**: Noted, looking into status bar inset calculations.
2. **Work profile badge in Hide Apps**: Valid catch, passing UserHandle profile badging into the hide apps adapter.
3. **Custom folder icon vs preview cover**: Logged as a feature request for the folder drawable logic.
4. & 5. **Icon scaling disparity**: Inspecting DeviceProfile grid scaling and folder icon normalization.
Tracked under `ISS-20261020-03`.
```

### In reply to Christoph 🇮🇱:

```markdown
> Christoph 🇮🇱: "Rcs is not working"

**[ISS-20261020-05] Support / RCS Guidance**
RCS activation requires passing Play Integrity (`MEETS_DEVICE_INTEGRITY`) and carrier provisioning. If you recently updated:
1. Verify Play Integrity status in Play Store > Settings > About > Play Protect certification.
2. Clear storage & cache for Google Messages and Carrier Services.
3. Toggle Airplane mode, reopen Messages, and re-verify your phone number in RCS Chats settings.
Tracked under `ISS-20261020-05`.
```

---

## XDA Replies

### In reply to xerel89 (Post #90784662):

```bbcode
[QUOTE="xerel89, post: 90784662"]
I don't think that's was a rom issue, that's a play integrity issue. Contact the devopler, I didn't have this issue Whats your settings on pif, I get only an connecting issue
[/QUOTE]

[B]Support / Community Note:[/B]
Spot on, xerel89. RCS registration requires passing MEETS_DEVICE Play Integrity attestation. Appreciate you helping other users troubleshoot their PIF / Tricky Store setups.
```

### In reply to LoganDeveloper (Post #90784724 / #90784727):

```bbcode
[QUOTE="LoganDeveloper, post: 90784727"]
Where? I only have this setting (that keeps going off by itself)
[/QUOTE]

[B][ICODE]ISS-20261020-04[/ICODE] Acknowledged:[/B]
Thanks for reporting this on grizzly!
1. Regarding the 80% charge limit turning off: we are investigating why the sysfs charging node / node toggle resets on grizzly after being enabled. Tracked under [ICODE]ISS-20261020-04[/ICODE] for the upcoming Sunday release.
2. Regarding charging to 100% right before unplugging: that is Google's Adaptive Charging feature (Settings > Battery > Adaptive Charging / Battery Health), which learns your routine and holds at 80% overnight until shortly before your alarm.
3. Also thanks for sharing the RCS tip on clearing Google Messages cache!
```
