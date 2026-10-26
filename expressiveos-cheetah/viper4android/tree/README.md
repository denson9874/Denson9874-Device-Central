# vendor/extra/viper4android (ExpressiveOS, cheetah)

Staged by `expressiveos-cheetah/viper4android/apply-v4a.sh` from the ExpressiveOS repo; don't edit
it here, the next run puts the kit's copy back. Only the ExpressiveOS tree has it: never the
Evolution X tree (`~/evolution`).

## What ships

| Installed as | From | Licence |
|---|---|---|
| `/system_ext/priv-app/ViPER4Android/ViPER4Android.apk` | ViPER4Android 2.1.1, the unmodified release APK (`com.llsl.viper4android`, signed by upstream) | GPL-3.0 (`LICENSE.app`) |
| `/system_ext/etc/permissions/privapp-permissions-com.llsl.viper4android.xml` | ExpressiveOS: grants `MODIFY_AUDIO_ROUTING` only | |
| `/system_ext/etc/sysconfig/hiddenapi-com.llsl.viper4android.xml` | ExpressiveOS: no hidden-API restrictions for the app | |
| `/vendor/lib64/soundfx/libv4a_re.so` | `common/files/libv4a_re_arm64-v8a.so` from the non-AIDL ViPERFX_RE v2.1.1 module zip, unmodified and unstripped | zip `LICENSE` GPL-2.0 (`LICENSE.driver`); the DSP inside is ViPERDSP, All Rights Reserved, personal and non-commercial use only (`NOTICE.viperdsp`); PFFFT/FFTPACK (`NOTICE.pffft`) |

Evolution X's libeffects loads `/vendor/lib64/soundfx/libv4a_re.so` by itself, so
`audio_effects.xml` stays stock.

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
- ExpressiveOS hosts the exact sources of both next to each release.

`NOTICE.viperdsp` is ViPERDSP's `README.md` lines 5-10 and `NOTICE.pffft` is the licence comment at
the top of ViPERDSP's `viper/utils/pffft.c` (lines 1-53), both verbatim.

## Credits

- ViPER4Android app: likelikeslike.
- ViPER4Android RE driver (ViPERFX_RE, authors as its module.prop lists them): pittvandewitt,
  MrWhite214, Zackptg5, Martmists, Iscle and llsl.
- Original ViPER4Android and its DSP: Zhuhang and ViPER520.
- PFFFT: Julien Pommier; FFTPACK: Paul Swarztrauber (NCAR).
