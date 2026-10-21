# Community Replies Draft (2026-10-19)

Review and approve these response drafts before posting to Telegram or XDA.

---

## Telegram Replies (`@ExpressiveLauncherFeedback`)

### In reply to Masterdex:

```markdown
> Masterdex: "I just have a question. Since the certification works well on EvolutionX, is it possible to implemen..."

**[ISS-20261019-03] Clarified**
DerpFest will not support MEETS_STRONG_INTEGRITY. Attempting to force the required attestation mechanisms on DerpFest caused boot failures and unbootable states during testing on Tensor G6. To keep DerpFest stable, it will remain without Strong Integrity. For Strong Integrity tap-to-pay, use our Evolution X builds which support it natively.
```

### In reply to Igor:

```markdown
> Igor: "atlernatively its possible to just go to reset option and reset app preferences, which makes most ap..."

**[ISS-20261017-01] Acknowledged**
Thanks for isolating this on kodiak, Igor! The background/mobile data restriction default on clean flash is being addressed in system overlays for Sunday's release.
Tracked under `ISS-20261017-01`.
```

### In reply to Ashray V K:

```markdown
> Ashray V K: "So now playing works, just need to install the apks and give the right perms.  @denson9874 😁 Receive..."

**[ISS-20261019-01] Update**
Thanks for following up on Now Playing, Ashray! The association block between ASI and PCS is tracked under `ISS-20261019-01` and patched in tree for the next build.
```

### In reply to Christoph 🇮🇱:

```markdown
> Christoph 🇮🇱: "why i dont can flash a anykernel3 wild 6.12.92 on evox? ist Always bootlooping DerpFest builds will ..."

**[ISS-20261019-04] Support / Notice**
Evolution X for Pixel 11 is built strictly around Kevtrejo37's Espada kernel v3 (Linux 6.12.92) with custom CASS scheduler, simple LMK, and tuned DTBO/init configurations. Third-party AnyKernel3 zips (such as WildKernel) do not match the expected ramdisk or module symbol exports and will bootloop. We only support the integrated Espada kernel.
```

### In reply to Christoph 🇮🇱:

```markdown
> Christoph 🇮🇱: "Which launcher works derpfest? And who's the differences? I know, I know—it’s just that I personally..."

**Support / Clarification**
DerpFest ships with its own customized launcher (DerpLauncher) styled after Pixel Launcher with extended customization options. Evolution X uses Evolution Launcher (based on Launcher3).
```

### In reply to Christoph 🇮🇱:

```markdown
> Christoph 🇮🇱: "On the previously version I can disable live display"

**[ISS-20261019-05] Acknowledged**
Thanks for isolating this, Christoph 🇮🇱! We reproduced the issue where granular At a Glance sub-settings don't disable from widget settings (while master Home settings toggle works). Investigating the preference bindings in Launcher3/Smartspace for Sunday's update.
Tracked under `ISS-20261019-05`.
```

### In reply to Igor:

```markdown
> Igor: "Are you on Derp?⁩ The one he shows is from when u long press the widget or go 1 step further into at..."

**[ISS-20261019-05] Acknowledged**
Thanks for isolating this, Igor! We reproduced the issue where granular At a Glance sub-settings don't disable from widget settings (while master Home settings toggle works). Investigating the preference bindings in Launcher3/Smartspace for Sunday's update.
Tracked under `ISS-20261019-05`.
```

## XDA Replies

### In reply to mcflyrk01 (Post #90782887):

```bbcode
[QUOTE="mcflyrk01, post: 90782887"]
Just installed the 10/18 build - SIM settings are no longer greyed out but won't do anything when I try to open them.  From the "Let's get you started...
[/QUOTE]

[B][ICODE]ISS-20261019-02[/ICODE] Follow-up Received:[/B]
Thank you for the detailed logcat and reproduction steps! The Google Fi T120 error and SIM settings failure point to the EuiccGoogle / carrier setup privilege binding and Keystore authentication during initial profile provisioning.
Tracking this actively under [ICODE]ISS-20261019-02[/ICODE] for resolution.
```

### In reply to xerel89 (Post #90782948):

```bbcode
[QUOTE="xerel89, post: 90782948"]
can not fully disable the live display on homescreen, on the new realse what you are today posted, i am not sure how i can create boout that a logcat
[/QUOTE]

[B][ICODE]ISS-20261019-05[/ICODE] Acknowledged:[/B]
Thanks for reporting this! We reproduced the behavior: toggling off At a Glance entirely from Home settings works, but the granular sub-setting toggles inside the widget settings don't persist/disable individual items in Launcher3/Smartspace.
Investigating the preference binding for the upcoming Sunday release. Tracked under [ICODE]ISS-20261019-05[/ICODE].
```

### In reply to Paddybecks87 (Post #90782990):

```bbcode
[QUOTE="Paddybecks87, post: 90782990"]
@denson9874 Thanks a bunch for the update! Is the app-content of apps locked via sandbox now obfuscated in the recents overview or is this still being...
[/QUOTE]

[B][ICODE]ISS-20261015-02[/ICODE] Status Update:[/B]
This is still being worked on upstream in Evolution X Launcher3 / Quickstep. The obfuscation layer for sandboxed/locked app task snapshots in Recents requires upstream framework integration before it lands in our builds. Still tracked under [ICODE]ISS-20261015-02[/ICODE].
```

### In reply to DoubtTM (Post #90783284):

```bbcode
[QUOTE="DoubtTM, post: 90783284"]
thats cuz for some reason most apps dont have wifi/mobile data access by default, either set it for each app manually or go to system settings - reset...
[/QUOTE]

[B][ICODE]ISS-20261017-01[/ICODE] Workaround Noted:[/B]
Thanks for sharing this workaround on the thread! Resetting app preferences resets the restricted default network state until Sunday's overlay update resolves the clean-flash default permissions. Tracked under [ICODE]ISS-20261017-01[/ICODE].
```

### In reply to kingpeppermint (Post #90783314):

```bbcode
[QUOTE="kingpeppermint, post: 90783314"]
Does this rom also has the sideload lockout / beg Google on your knees to have in enabled after 24hrs "feature"  as it based on stock?
[/QUOTE]

[B][ICODE]ISS-20261019-06[/ICODE] Clarified:[/B]
No. Evolution X is built on open AOSP/LineageOS foundations and does not enforce stock Pixel firmware restrictions like the 24-hour sideloading lockout or Google Play Protect forced delays. You have full standard Android sideloading freedom out of the box.
```
