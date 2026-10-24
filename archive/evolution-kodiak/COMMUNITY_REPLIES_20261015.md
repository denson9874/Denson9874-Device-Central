# Community Replies & Feedback Drafts (October 15, 2026)

---

## 1. Telegram Reply to Ashray V K
**Target Group:** `https://t.me/ExpressiveGroup`  
**In reply to:** Ashray (13:54), *"I assume the extreme charging is part of the pixel 11 specific feature list which currently isn't available, yeah?"*

```markdown
It's actually implemented now! I just finished building and verifying Extreme Charging ("Bodega") mode for the Pixel 11 series on Evolution X 17, and it will be included in Sunday's (2026-10-18) build.

It adds an "Extreme Charging" Quick Settings tile backed by an in-ROM system controller that communicates directly with the Pixel Power HAL extension (`IPowerExt.setMode("BODEGA", on)`). When plugged into a 30 W+ USB-PD PPS charger below 50% battery, it unlocks relaxed thermal ceilings and enables priority charging (`priority_charging_enable`). It automatically disengages and returns to stock profiles when unplugged or when the battery reaches 100%.
```

---

## 2. XDA Kodiak / Grizzly Thread (`4804712`)

### Reply to Post #21 (Paddybecks87)
*Context: Locked apps visible in Recents overview; plans to try yogi.*

```bbcode
[QUOTE="Paddybecks87, post: 89751021"]
...
[/QUOTE]

Thanks for the report! The locked app content preview in the Recents carousel is an upstream Evolution X / Launcher3 Quickstep behavior that we are tracking for a clean fix. 

Great to hear you're planning to test the Pixel 11 Pro Fold (yogi) build as well! Keep in mind the Fold is still on the stock Google GKI kernel (the folded/unfolded dual-display drivers require stock vendor modules), whereas kodiak and grizzly now ship with the Espada kernel v3 out of the box. Let us know how the inner/outer display handover behaves!
```

### Reply to Post #22 (xerel89)
*Context: Stuck on "< waiting for any device >" during fastboot update.*

```bbcode
[QUOTE="xerel89, post: 89751022"]
< waiting for any device >
[/QUOTE]

If you're stuck on "< waiting for any device >", your computer isn't detecting the phone while in the bootloader. A few quick checks:

1. Make sure you are using the latest Android SDK Platform-Tools (r35+): [ICODE]fastboot --version[/ICODE].
2. Verify the device is enumerated in bootloader mode: run [ICODE]fastboot devices[/ICODE]. If it returns blank:
   - On Windows: check Device Manager for an "Android" entry with a yellow exclamation mark and update it with the official Google USB Driver (choose "Android Bootloader Interface").
   - On Linux: ensure udev rules ([ICODE]android-udev-rules[/ICODE]) are installed so non-root users have USB device access.
   - On Mac: avoid USB-C hubs; connect directly to a Thunderbolt/USB-C port on the Mac.
3. Once [ICODE]fastboot devices[/ICODE] prints your serial, re-run [ICODE]fastboot update <zip>[/ICODE].
```

---

## 3. XDA Yogi (Pixel 11 Pro Fold) Thread (`4804826`)

### Reply to Post #2 (stevecaboose)
*Context: Planning to test yogi build this week.*

```bbcode
[QUOTE="stevecaboose, post: 89752002"]
...
[/QUOTE]

Awesome, looking forward to your results! Since I don't own a physical Pixel 11 Pro Fold myself, your feedback will be invaluable. 

When you test, the key areas to pay attention to are:
1. [B]Fold/Unfold Transition:[/B] Display switching between the outer cover display and the inner folding panel, including rotation and AOD transitions.
2. [B]Hinge Angle Sensor:[/B] Flex mode / tabletop orientation in supported camera apps.
3. [B]Telephony & Media:[/B] VoLTE / Wi-Fi calling handover and microphone switching between folded and unfolded orientations.

Be sure to follow the instructions in the first post and keep a copy of stock CD1A.261005.003 handy with the Android Flash Tool just in case. Thank you for testing!
```
