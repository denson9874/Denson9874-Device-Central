# Community Replies Draft (2026-10-17)

Review and approve these response drafts before posting to Telegram or XDA.

---

## Telegram Replies (`@ExpressiveLauncherFeedback`)

### In reply to Lubomir:

```markdown
> Lubomir: "Finaly,  flashed todays release and its booting, but strange issue i found also in previous, why som..."

**[ISS-20261017-01] Acknowledged**
Thanks for isolating this on kodiak, Lubomir! The background/mobile data restriction default on clean flash is being addressed in system overlays for Sunday's release.
Tracked under `ISS-20261017-01`.
```

### In reply to DevAB:

```markdown
> DevAB: "Hi, does anyone know which face unlock the ROM is using? Google’s or AOSP’s? Thanks for the reply. G..."

**[ISS-20261017-02] Acknowledged**
The ROM is using Google's Face Unlock HAL with Pixel biometric framework. We are evaluating Class 3 (Strong) BiometricPrompt elevation requirements for banking app authentication in upcoming builds.
Tracked under `ISS-20261017-02`.
```

## XDA Replies

### In reply to mcflyrk01 (Post #90779478):

```bbcode
[QUOTE="mcflyrk01, post: 90779478"]
Turns out this is only in the setup wizard, WiFi does connect fine once I skip through all of that.

Tried rooting with Apatch and I get stuck in a bo...
[/QUOTE]

[B][ICODE]ISS-20261017-03[/ICODE] Acknowledged:[/B]
Thanks for the update and for confirming KernelSU works cleanly with the Espada kernel! We are looking into the Setup Wizard Wi-Fi scan drop behavior for the next update cycle.
```

### In reply to anthonnyb98 (Post #90779690):

```bbcode
[QUOTE="anthonnyb98, post: 90779690"]
Greetings @denson9874, and thanks for the great work. I was wondering whether the facial unlock feature implemented is the one from Google or the AOSP...
[/QUOTE]

[B][ICODE]ISS-20261017-04[/ICODE] Acknowledged:[/B]
The ROM is currently using Google's Face Unlock HAL with Pixel's biometric framework. We are evaluating Class 3 (Strong) BiometricPrompt elevation requirements for banking app authentication support in upcoming builds.
Tracked under [ICODE]ISS-20261017-04[/ICODE].
```

### In reply to wreq5 (Post #90779551):

```bbcode
[QUOTE="wreq5, post: 90779551"]
Alright alright alriiiight, flashed EvoX onto my Pixel 11 cubs and it was smooth as butter, Everything seems to check out fine with one huge exception...
[/QUOTE]

[B][ICODE]ISS-20261017-05[/ICODE] Acknowledged:[/B]
Thanks for testing the new cubs build and reporting this! We are investigating the 5G NR SMS/IMS stack configuration for the cubs Tensor G6 baseline so SMS receives properly on 5G without needing to force LTE.
Tracked under [ICODE]ISS-20261017-05[/ICODE] for the upcoming Sunday release.
```
