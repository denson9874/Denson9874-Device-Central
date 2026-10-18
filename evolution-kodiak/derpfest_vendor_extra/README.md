# DerpFest `vendor/extra` for kodiak

Backup of `~/derpfest/vendor/extra/` on the build server. DerpFest's `vendor/lineage/config/common.mk` inherits
`vendor/extra/product.mk` when it exists. The directory isn't in DerpFest's repo manifest, so `repo sync` leaves
it alone, and it exists only in `~/derpfest`: Evolution X (`~/evolution`) and the public device trees don't get it.
Plan and reasons: `evolution-kodiak/DERP_BCR_PLAN.md`.

## Contents

- `product.mk`: adds `BCR` to `PRODUCT_PACKAGES`.
- `bcr/`: Basic Call Recorder (https://github.com/chenxiaolong/BCR), installed as
  `/system_ext/priv-app/BCR/BCR.apk` with its allowlist in `/system_ext/etc/permissions/`.
  - `Android.bp`: `android_app_import` (presigned, preprocessed, privileged) and the allowlist's `prebuilt_etc`.
  - `privapp-permissions-com.chiller3.bcr.xml`: the same two permissions as BCR's own module
    (`CAPTURE_AUDIO_OUTPUT`, `CONTROL_INCALL_EXPERIENCE`).
  - `NOTICE`: license and source.
  - `VERSION`, `BCR.apk.sha256`: what ships, written by `tools/bcr-fetch.sh`.
  - `BCR.apk`, `LICENSE`: fetched by `tools/bcr-fetch.sh`, not committed here.

## Deploy (only while no other build runs on the server)

```bash
rsync -a --exclude .git -e "ssh -i ~/.ssh/voltage_build_ed25519" evolution-kodiak/derpfest_vendor_extra/ build@157.180.50.152:derpfest/vendor/extra/
```
```bash
ssh -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152 '~/bcr-fetch.sh ~/derpfest/vendor/extra/bcr'
```
Then commit in the server's local git (`~/derpfest/vendor/extra`, never pushed) and copy `bcr/VERSION` and
`bcr/BCR.apk.sha256` back here.

## Moving to a new BCR release

1. In `tools/bcr-fetch.sh`, update `BCR_VERSION`, `BCR_ZIP_SHA256` (the zip's sha256 on the release page) and, if
   the README changed it, `BCR_CERT_SHA256`. Update the tag in `bcr/NOTICE`.
2. Run `bcr-fetch.sh` on the server. If it stops with `privapp permissions changed upstream`, add the new
   permission to `bcr/privapp-permissions-com.chiller3.bcr.xml` deliberately, then run it again.
3. Rebuild (`~/derp-build.sh --no-upload`), check, and commit `VERSION` and `BCR.apk.sha256` here.
