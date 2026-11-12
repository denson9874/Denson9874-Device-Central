# vendor/extra/viper4android (ExpressiveOS: cheetah, husky and the Pixel 11s)

Staged by `expressiveos-cheetah/viper4android/apply-v4a.sh` from the ExpressiveOS repo; don't edit
it here, the next run puts the kit's copy back. Only the ExpressiveOS tree has it.

## What ships

| Installed as | From | Licence |
|---|---|---|
| `/system_ext/priv-app/ViPER4Android/ViPER4Android.apk` | ViPER4Android 2.1.1, the unmodified release APK (`com.llsl.viper4android`, signed by upstream) | GPL-3.0 (`LICENSE.app`) |
| `/system_ext/etc/permissions/privapp-permissions-com.llsl.viper4android.xml` | ExpressiveOS: grants `MODIFY_AUDIO_ROUTING` only | |
| `/system_ext/etc/sysconfig/hiddenapi-com.llsl.viper4android.xml` | ExpressiveOS: no hidden-API restrictions for the app | |
| `/vendor/lib64/soundfx/libv4a_re.so` (cheetah) | `common/files/libv4a_re_arm64-v8a.so` from the non-AIDL ViPERFX_RE v2.1.1 module zip, unmodified and unstripped | zip `LICENSE` GPL-2.0 (`LICENSE.driver`); the DSP inside is ViPERDSP, All Rights Reserved, personal and non-commercial use only (`NOTICE.viperdsp`); PFFFT/FFTPACK (`NOTICE.pffft`) |
| `/vendor/lib64/soundfx/libv4a_aidl.so` (husky) | `common/files/libv4a_aidl_arm64-v8a.so` from the AIDL ViPERFX_RE v2.1.1 module zip, unmodified and unstripped | the zip has no `LICENSE`; ViPERDSP (`NOTICE.viperdsp`); PFFFT/FFTPACK (`NOTICE.pffft`) |
| `/vendor/etc/audio_effects_config.xml` (husky) | `common/audio_effects_config.xml` from the same AIDL zip, unmodified | as above |
| `/product/vendor_overlay/0/lib64/soundfx/libv4a_aidl.so` and `/product/vendor_overlay/0/etc/audio_effects_config.xml` (the Pixel 11s) | The same two AIDL files (`Android.mk`), laid over `/vendor/lib64/soundfx` and `/vendor/etc` at boot by `/product/etc/init/init.viper4android.rc` | as above |

On cheetah, Evolution X's libeffects loads `/vendor/lib64/soundfx/libv4a_re.so` by itself, so
`audio_effects.xml` stays stock. On husky, Google's audio HAL loads the libraries that
`/vendor/etc/audio_effects_config.xml` names; husky's vendor has none of its own, so the AIDL zip's
config is it. On kodiak, whose vendor is Google's read-only image, the same two files sit in
`/product/vendor_overlay/0`, and `init.viper4android.rc` lays them over the two vendor folders at
boot (read-only overlayfs, with an off switch: `persist.eos.v4a.off`). `viper4android.te`,
`file_contexts`, `service_contexts` and `property_contexts` here are kodiak's product policy for it.

## Sources

- App: https://github.com/likelikeslike/ViPER4Android, tag `2.1.1`
  (`dfcbda7bceb01b7f3a77e092083311181768278c`). Release asset
  https://github.com/likelikeslike/ViPER4Android/releases/download/2.1.1/ViPER4Android-2.1.1.apk,
  sha256 `b60a8e38c4abf00b5e3f0d4802732bf1dc8679047cc9471fb36bf74a9c572cba`.
- Driver: https://github.com/likelikeslike/ViPERFX_RE, tag `v2.1.1`
  (`32587b138eb915d6252ccbebd8a86d05af778957`), with its ViPERDSP submodule
  https://github.com/likelikeslike/ViPERDSP at `6fc1f1b8b2123c8cc49f3b3c7c7d5fbbf8a60933`. Release
  asset https://github.com/likelikeslike/ViPERFX_RE/releases/download/v2.1.1/ViPER4Android-RE-v2.1.1.zip,
  sha256 `c8f769f9d9f470e47f8278d69615c899d54af3916d10291d853fbd299ee847a2`; the library's sha256 is
  `79d058309902ec3a7ac96e225cf052aefe950d8a904a7f405e633916284cd31b`.
- AIDL driver: the same release, asset
  https://github.com/likelikeslike/ViPERFX_RE/releases/download/v2.1.1/ViPER4Android-RE-AIDL-v2.1.1.zip,
  sha256 `536f981610fe378b2ae5703b1c8a1ea5c87a8dce7ac34f904d641c0c701e2f1d`; the library's sha256 is
  `8c258a3e28d37cc4ed198bb2f00b831b07704c99e0506dcb183c81aa7aa7dfbd`. ViPERFX_RE publishes no source
  for the AIDL driver itself (its DSP is the ViPERDSP above).
- ExpressiveOS hosts the exact sources it has (the app, ViPERFX_RE and ViPERDSP) next to each release.

`NOTICE.viperdsp` is ViPERDSP's `README.md` lines 5-10 and `NOTICE.pffft` is the licence comment at
the top of ViPERDSP's `viper/utils/pffft.c` (lines 1-53), both verbatim.

## Credits

- ViPER4Android app: likelikeslike.
- ViPER4Android RE driver (ViPERFX_RE, authors as its module.prop lists them): pittvandewitt,
  MrWhite214, Zackptg5, Martmists, Iscle and llsl.
- Original ViPER4Android and its DSP: Zhuhang and ViPER520.
- PFFFT: Julien Pommier; FFTPACK: Paul Swarztrauber (NCAR).
