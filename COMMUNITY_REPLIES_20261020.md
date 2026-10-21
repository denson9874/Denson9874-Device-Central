# Community Replies Draft (2026-10-20)

Review and approve these response drafts before posting to Telegram or XDA.

---

## Telegram Replies (`@ExpressiveLauncherFeedback`)

### In reply to Igor:

```markdown
> Igor: "Interesting, that doesn't work for me either, turning the whole thing off does tho Received edited a..."

**[ISS-20261019-05] Acknowledged**
Thanks for the report! Could you capture a logcat of the issue on kodiak so we can inspect the root cause?
`su -c "logcat -b all -d > /sdcard/log_ISS-20261019-05.txt"`
Then send the file here. Thank you!
```

### In reply to Igor:

```markdown
> Igor: "Just for some reason I keep getting system ui restarts sometimes after unlocking phone, probably har..."

**[ISS-20261020-01] SystemUI Restart Tracked**
Thanks for isolating the repro steps, Igor! Unlock + immediate QS pull or screen off + instant FOD unlock helps narrow down the SystemUI race condition. When possible, please grab `adb logcat -b crash -d` and `adb logcat -b all -d` after reproducing so we can inspect the crash trace.
Tracked under `ISS-20261020-01`.
```

### In reply to Igor:

```markdown
> Igor: "Ok seems to be consistently happen when I unlock phone, and instantly try to open qs And when turnin..."

**[GENERAL] Acknowledged**
Thanks for the update on kodiak, Igor! Looking into this for the next update.
```

### In reply to Ashray V K:

```markdown
> Ashray V K: "I noticed this too, happens right after unlocking the screen sometimes you go back to the lockacreen..."

**[ISS-20261020-01] SystemUI Restart Tracked**
Thanks for isolating the repro steps, Ashray V K! Unlock + immediate QS pull or screen off + instant FOD unlock helps narrow down the SystemUI race condition. When possible, please grab `adb logcat -b crash -d` and `adb logcat -b all -d` after reproducing so we can inspect the crash trace.
Tracked under `ISS-20261020-01`.
```

### In reply to Loic:

```markdown
> Loic: "New builds for the Pixel 11 Pro XL (kodiak), Pixel 11 Pro (grizzly), Pixel 11 (cubs) and Pixel 11 Pr..."

**[ISS-20261020-02] Chrome & Now Playing Noted**
Merci Loic! Now Playing is fixed in tree for the next build. For the Chrome crash on the 10-15 update with KSU/SuSFS/LSPosed: please grab `adb logcat -b crash -d` after reproducing, and test if disabling LSPosed modules for Chrome isolates the crash.
Tracked under `ISS-20261020-02`.
```

### In reply to Pratik:

```markdown
> Pratik: "Hi @denson9874 thanks for the launcher update. It's smooth!  Few feedback: 1. The app drawer top sea..."

**[ISS-20261020-03] Expressive Launcher Feedback Noted**
Thanks for the detailed breakdown, Pratik!
1. **App drawer search bar overlap**: Noted, looking into status bar inset calculations.
2. **Work profile badge in Hide Apps**: Valid catch, we will pass UserHandle profile badging into the hide apps adapter.
3. **Custom folder icon vs preview cover**: Logged as a feature request for the folder drawable logic.
4. & 5. **Icon scaling disparity**: Inspecting DeviceProfile grid scaling and folder icon normalization.
Tracked under `ISS-20261020-03`.
```

## XDA Replies

### In reply to LoganDeveloper (Post #90783707):

```bbcode
[QUOTE="LoganDeveloper, post: 90783707"]
I installed October 18 update on my grizzly.
It works great, except I can't limit charging up to 80%, it turns off by itself.

Also, I can't find the ...
[/QUOTE]

[B][ICODE]ISS-20261020-04[/ICODE] Acknowledged:[/B]
Thanks for reporting this on grizzly!
1. Regarding the 80% charge limit turning off: we are investigating why the sysfs charging node / node toggle resets on grizzly after being enabled. Tracked under [ICODE]ISS-20261020-04[/ICODE] for the upcoming Sunday release.
2. Regarding charging to 100% right before unplugging: that is Google's Adaptive Charging feature (Settings > Battery > Adaptive Charging / Battery Health), which learns your routine and holds at 80% overnight until shortly before your alarm.
```

### In reply to xerel89 (Post #90783719):

```bbcode
[QUOTE="xerel89, post: 90783719"]
Search in the settings for that, this feature is also in stock available
[/QUOTE]

[B][ICODE]GENERAL[/ICODE] Acknowledged:[/B]
Thank you for the feedback on kodiak! This has been triaged for the upcoming release cycle.
```

### In reply to DoubtTM (Post #90783876):

```bbcode
[QUOTE="DoubtTM, post: 90783876"]
Not the first error, but the thing u talked about in edit2
[/QUOTE]

[B][ICODE]ISS-20261019-02[/ICODE] Acknowledged:[/B]
Thank you for the feedback on kodiak! This has been triaged for the upcoming release cycle.
```

### In reply to bs3pro (Post #90784537):

```bbcode
[QUOTE="bs3pro, post: 90784537"]
I'm assuming rcs is broken in the US with this rom? And any custom room for that matter?
[/QUOTE]

[B][ICODE]ISS-20261020-05[/ICODE] Clarified:[/B]
RCS is not broken by the ROM in the US. However, Google Messages enforces Play Integrity checks (specifically MEETS_DEVICE_INTEGRITY) server-side for RCS registration.
As long as your setup passes device integrity and your carrier provisions IMS/RCS properly, RCS functions normally on Evolution X. If Google Play Integrity fails or carrier provisioning drops, Google Messages will fall back to SMS/MMS.
```
