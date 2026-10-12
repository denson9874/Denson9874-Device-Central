Replies to Ashray V K in Expressive Group Feedback (2026-10-12). All three are posted.

18:31, from Daryl's account, about the screen-timeout flash:

> Thanks for the log! It shows the cause. When the screen times out into AOD, the always-on display starts at a fixed
> brightness (about 121 nits) for a split second before the light sensor dims it, even though your screen had dimmed to
> about 0.5 nits. It isn't your kernel, root or modules. I'm working on a fix for the next build.

19:38, reply to his 18:37 message (PIN asked twice after a reboot):

> Thanks for the details! I tried this on my own Pixel 11 Pro XL with the stock kernel: after a reboot I unlocked with
> my PIN, locked the phone, and the fingerprint worked straight away. So it may be something in your setup, like the
> kernel or a module.
>
> Yes please, a log would help. With root it's easiest from a terminal app. Right after the second lock refuses your
> fingerprint, run:
>
> `su -c "logcat -b all -d > /sdcard/lock_log.txt; dumpsys activity service com.android.systemui/.SystemUIService KeyguardUpdateMonitor > /sdcard/keyguard.txt"`
>
> Then send both files. The second one shows why the lock screen wasn't accepting a fingerprint. If you can, also try
> once with your modules disabled.

19:39, reply to his 18:40 message (Pixel features):

> Now Playing and a few other Pixel extras are left out on purpose: Evolution X's rules for official builds don't
> allow proprietary Google apps in device trees, and I'd like kodiak to go official one day. They're technically
> doable, so I'll look at whether they can be offered as a separate optional add-on.
>
> HiLight is more promising than I expected: the light bar's driver and Android 17's own light-animation framework
> are already in the ROM. What's missing is Google's HiLight settings page and the triggers behind it (Gemini,
> favorite contacts, calls). I'm looking into building those into the ROM, no promises on timing yet. Sleep well!

HiLight notes (2026-10-12):
- Stock vendor `vendor.google.lights-service`, `android.hardware.light` V3, `dumpsys lights` lists ids 1-8
  (the 8 LEDs) plus id 0.
- AOSP A17: `LightsService` + `MultiLightEffect`/`ColorSequence` (flag `enable_light_animations`, enabled in cp2a),
  `NotificationAttentionHelper` favorite-call lights (`LIGHT_ID_PRIORITY_NOTIFICATIONS`,
  `Settings.Secure.LIGHT_ANIMATION_FAVORITE_CALLS_ENABLED`, flag `favorites_incoming_call_lights`, only enabled in
  trunk_staging).
- Stock UI: SettingsGoogle `LightAnimationsSettingsFragment` etc. (resources `light_animations_*`; settings keys
  `light_animation_feedback_enabled`, `light_animation_favorite_calls_enabled`). The Google app (Velvet) reads
  `light_animation_feedback_enabled`. Evolution's GMS already grants `CONTROL_DEVICE_LIGHTS` to Google (Velvet),
  GoogleCamera and Settings.
