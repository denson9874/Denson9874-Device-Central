# denson9874 Device Central: the ExpressiveOS build kit

<div align="center">
  <p><strong>The build kit, release tools and web installer for ExpressiveOS 2.0, denson9874's pure-AOSP Android 17 ROM for the Pixel 7 Pro, Pixel 8 Pro and the Pixel 11 series.</strong></p>

  <p>
    <a href="#repository-structure">Repository Structure</a> •
    <a href="#phones">Phones</a> •
    <a href="#installing-and-updating">Installing and Updating</a> •
    <a href="#building-from-source">Building from Source</a> •
    <a href="#help-and-bugs">Help and Bugs</a>
  </p>
</div>

---

## Repository Structure

```
Denson9874-Device-Central/
├── expressiveos-cheetah/      # The ExpressiveOS kit for all six phones: pins, patches, branding,
│                              # launcher, release notes, and the build, pack and release scripts
├── tools/
│   ├── build_speed/           # Build server speed checks (ccache, ninja's explain, timings)
│   ├── expressiveos_flasher/  # The web installer (Cloudflare Worker and R2)
│   ├── expressiveos_feedback_bot/  # Telegram Bugs/Ideas -> private GitHub issues (Cloudflare Worker)
│   └── ota_mirror/            # R2 mirror for the Updater's OTA packages
├── .github/workflows/         # The build server's runner actions (kodiak-build.yml)
└── docs/assets/screenshots/   # Logo
```

ExpressiveOS's ROM sources are organized across four functional GitHub organizations (all synced via [`ExpressiveOS/manifest`](https://github.com/ExpressiveOS/manifest), branch `expressiveos-2.0`):

| Organization | Manifest Remote | Purpose |
| :--- | :--- | :--- |
| [`ExpressiveOS`](https://github.com/ExpressiveOS) | `expressiveos` | Core ROM platform, frameworks, custom apps, vendor/GMS/UI, `manifest`, and Git LFS object store (`blobs`) |
| [`ExpressiveOS-Devices`](https://github.com/ExpressiveOS-Devices) | `expressiveos-devices` | Google Pixel device trees (`cheetah`, `husky`, `kodiak`, `grizzly`, `cubs`, `yogi`), Pixel HALs/sepolicy, and vendor blob repos |
| [`ExpressiveOS-ASB`](https://github.com/ExpressiveOS-ASB) | `expressiveos-asb` | Upstream AOSP repositories carrying monthly Android Security Bulletin (ASB) cherry-picks |
| [`ExpressiveOS-Legacy`](https://github.com/ExpressiveOS-Legacy) | *(archived)* | Read-only archive of ExpressiveOS 1.x repositories |

---

## Phones

| Phone | Codename | XDA thread |
| :--- | :--- | :--- |
| Pixel 7 Pro | `cheetah` | [cheetah](https://xdaforums.com/t/4807488/) |
| Pixel 8 Pro | `husky` | [husky](https://xdaforums.com/t/4807490/) |
| Pixel 11 | `cubs` | [cubs](https://xdaforums.com/t/4807493/) |
| Pixel 11 Pro | `grizzly` | [grizzly, kodiak, yogi](https://xdaforums.com/t/4807494/) |
| Pixel 11 Pro XL | `kodiak` | [grizzly, kodiak, yogi](https://xdaforums.com/t/4807494/) |
| Pixel 11 Pro Fold | `yogi` | [grizzly, kodiak, yogi](https://xdaforums.com/t/4807494/) |

Every build is a user build signed with ExpressiveOS's own release keys, with Google apps included
and no root.

---

## Installing and Updating

* **First install:** the [web installer](https://expressiveos-flash.daryldenson-apps.workers.dev)
  flashes the phone from a desktop browser. The bootloader has to be unlocked, and coming from any
  other ROM needs a clean install, because ExpressiveOS is signed with its own keys.
* **Updates:** the built-in Updater reads
  [`denson9874/expressiveos_ota`](https://github.com/denson9874/expressiveos_ota) and installs each
  monthly release to the inactive slot in the background. Updates keep your data.
* **Keep the bootloader unlocked.** Locking it with a custom ROM installed can leave the phone
  unable to boot.

---

## Building from Source

Builds run on the build server from [`expressiveos-cheetah/`](expressiveos-cheetah/README.md): its
README covers the tree, the patches, the build, pack and release steps, and the runner actions in
[`.github/workflows/kodiak-build.yml`](.github/workflows/kodiak-build.yml).

---

## Help and Bugs

* **Telegram:** [Expressive Group](https://t.me/ExpressiveGroup), with topics for ROM support,
  installs and updates, and bugs.
* **No logs, no report.** Capture a logcat right after the problem happens, and post it with your
  build date and the steps to reproduce:
```sh
adb logcat -b all -d > log.txt
```
* **Custom setups get limited to no support.** That covers root modules, Xposed/LSPosed, other
  kernels, and apps from APKMirror and similar sites that don't match the build (Google system apps
  especially). Reproduce the problem on a clean install without them first.

---

## License

Each source repository keeps its own license and upstream notices.
