# OTA mirror

The Updaters of our Evolution X and DerpFest builds download their OTA packages from here instead of SourceForge.
The `ota-mirror` Worker serves the R2 bucket `denson9874-ota` at `https://ota-mirror.daryldenson-apps.workers.dev/<key>`:
GET and HEAD of an exact key, with byte ranges so interrupted downloads resume. Nothing lists the bucket.
R2 doesn't charge for downloads, and a file is downloadable as soon as its upload finishes.

| Keys | Uploaded by |
|---|---|
| `<dev>/17/<EvolutionX zip>` | `evolution-kodiak/tools/p11-ota.sh <dev> --upload` |
| `derpfest/<dev>/<DerpFest zip>` | `derpfest-husky/tools/derp-ota.sh <dev> --upload` |
| `expressiveos/<dev>/target-files/<target-files zip>` | `expressiveos-cheetah/tools/eos-pack.sh --upload` |
| `expressiveos/keybox.xml` | `expressiveos-cheetah/tools/eos-keybox.py upload <keybox.xml>` |

The scripts still upload every release to SourceForge for manual downloads (the XDA and Telegram links). The mirror keeps
only each device's current and previous build: the scripts delete older ones after publishing the Updater JSON.

## Deploy the Worker

```sh
npm ci
cf deploy        # needs cf auth login
```

## Set up uploads on the build server (once)

1. Cloudflare dashboard → R2 Object Storage → Manage API tokens → Create API token: **Object Read & Write**, applied to the
   `denson9874-ota` bucket only.
2. On the build server, add the token as the rclone remote `r2:` (the scripts call `~/bin/rclone`):

   ```sh
   ~/bin/rclone config create r2 s3 provider=Cloudflare no_check_bucket=true \
       endpoint=https://c79ebf2ae3002a3588d9cf3d8aa91431.r2.cloudflarestorage.com \
       access_key_id=<Access Key ID> secret_access_key=<Secret Access Key>
   ~/bin/rclone lsf r2:denson9874-ota    # no error = the remote works
   ```

`no_check_bucket=true` matters: a token limited to one bucket may not create buckets, which rclone otherwise tries.
