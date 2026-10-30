# vendor/extra/launcher (ExpressiveOS, every phone)

`expressiveos-cheetah/launcher/apply-launcher.sh` stages this folder from the ExpressiveOS repo. Don't
edit it here, because the next run puts the kit's copy back. Only the ExpressiveOS tree has it, never the
Evolution X tree (`~/evolution`) or DerpFest's (`~/derpfest`).

## What ships

| Installed as | From | Licence |
|---|---|---|
| `/system_ext/priv-app/ExpressiveLauncher/ExpressiveLauncher.apk` | Expressive Launcher, the unmodified release APK pinned in the kit's `launcher/launcher.conf` (`dev.launcher.expressive.l3`, signed with Expressive's release key) | Apache-2.0 (`LICENSE`), with GPL-3.0-or-later Lawnchair files, an MIT calculator (`NOTICE.calculator`) and the OFL-1.1 Google Sans Flex font (`NOTICE.font`) |
| `/system_ext/etc/permissions/privapp-permissions-dev.launcher.expressive.l3.xml` | ExpressiveOS: grants the privileged permissions it asks for | |
| `/system_ext/etc/sysconfig/hiddenapi-dev.launcher.expressive.l3.xml` | ExpressiveOS: no hidden-API restrictions for the app | |
| `/system_ext/etc/sysconfig/preinstalled-packages-dev.launcher.expressive.l3.xml` | ExpressiveOS: installs it for the phone's own users, not work profiles, clones or the private space | |
| `/system_ext/overlay/ExpressiveLauncherFrameworkOverlay.apk` | ExpressiveOS: the framework config that names it in Pixel Launcher's place (`overlay/framework`) | |
| `/system_ext/overlay/ExpressiveLauncherSetupWizardOverlay.apk` | ExpressiveOS: Pixel's setup wizard ends on its "All set" page (`overlay/setupwizard`) | |

It replaces Pixel Launcher (`NexusLauncherRelease`), AOSP's `Launcher3QuickStep` and Pixel Launcher's
two overlays through `overrides` in `Android.bp`. `launcher.mk` adds it to every ExpressiveOS phone's
`lineage_<device>` product.

## Sources

- https://github.com/denson9874/ExpressiveLauncher, at the release's source revision (`EL_COMMIT` in
  `launcher.conf`). The release asset, its sha256 and its signing certificate are pinned in the same
  file.
- `NOTICE.calculator` is `lawnchair/src/app/lawnchair/search/algorithms/data/calculator/LICENSE` at that
  revision. `NOTICE.font` is Google Sans Flex's `OFL.txt` from
  https://github.com/googlefonts/googlesans-flex at the revision the launcher's
  `docs/THIRD_PARTY_NOTICES.md` names.
- ExpressiveOS hosts the exact source of the launcher next to each release.

## Credits

- Expressive Launcher: Daryl (denson9874), built on AOSP Launcher3 (The Android Open Source Project)
  and Lawnchair (Lawnchair Launcher).
- Calculator component: Keelar (MIT). Google Sans Flex: The Google Sans Flex Project Authors (OFL-1.1).
