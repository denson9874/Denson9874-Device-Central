# ExpressiveOS Flasher

A web page that installs ExpressiveOS on a Pixel from the browser over USB, as Google's Android Flash Tool does for stock
Android. It adds a choice of root (KernelSU Next, or none with the build's stock `init_boot`), the ExpressiveOS look, and
the Bloom mark, which fills petal by petal while a build downloads, turns inside a ring of petal colours while it installs,
and bursts into full bloom when the phone is done.

Phones: Pixel 7 Pro (cheetah), Pixel 8 Pro (husky), Pixel 11 (cubs), Pixel 11 Pro (grizzly), Pixel 11 Pro XL (kodiak) and
Pixel 11 Pro Fold (yogi). It works in Chrome or Edge on a computer, and in Chrome on Android with the target phone on a
USB-C cable. Firefox and Safari have no WebUSB.

It's one Cloudflare Worker, `expressiveos-flash`, on the same account and R2 bucket as `ota-mirror`. Once deployed, it
lives at `https://expressiveos-flash.daryldenson-apps.workers.dev`.

## How it works

| Path | What |
|---|---|
| `/` | The page (Vite's build of `index.html` and `src/`, served as static assets) |
| `/api/releases/<device>` | R2 `expressiveos/<device>/flasher.json`, the device's build list |
| `/dl/<device>/<file>` | R2 `expressiveos/<device>/flasher/<file>`, with byte ranges so downloads resume |

`worker/index.ts` answers only those two R2 paths, and only for the six codenames and file names shaped like a release's
fastboot zip or stock `init_boot`. Nothing else in the bucket can be reached: no listing, no target-files, no OTA
packages. `publish/flasher_publish.py` is what puts the files and the manifest there ([publish/README.md](publish/README.md)).
SourceForge can't be used as the source, because it sends no CORS headers.

The six steps:

1. **Phone.** Pick the model, or press "Detect a connected phone" to read it from a phone in Fastboot Mode.
2. **Build.** The release, root (KernelSU Next or no root, when the build has a stock `init_boot`), and a clean install
   or keeping data. Test builds show up with `?testers` on the address.
3. **Download.** The zip goes into the browser's private storage (OPFS) and is checked against its SHA-256 as it
   arrives. A closed tab or a dropped connection resumes from where it stopped, with a Range request. A zip the user
   already has can be picked instead, and it must match the listed SHA-256.
4. **Connect.** WebUSB to the phone in Fastboot Mode. The page checks the product against the build's `android-info.txt`,
   and offers to unlock the bootloader with `flashing unlock` when it's locked.
5. **Install.** What `fastboot -w update` does with the zip's `fastboot-info.txt`: `set_active`, cancel a pending
   snapshot update, the boot images in the bootloader, restart into fastbootd, `update-super`, the logical partitions
   (resized to each image), then erase userdata and metadata for a clean install. Images bigger than the phone's
   download buffer go in sparse pieces of at most 1 GiB, and a raw image's AVB footer is moved to the end of its
   partition, both as AOSP fastboot does. Without root, the stock `init_boot` goes to both slots. The page keeps the
   screen awake, and when the phone comes back from a restart as a device the browser doesn't know yet (Chrome on Android
   always does this), it shows a Reconnect button.
6. **Done.** Full bloom, and how to finish setting up root.

Nothing is ever loaded whole into memory. The zip is read as slices of the stored file, so a 7 GB release needs about
7 GB of free disk but little memory.

## Deploy (Daryl)

```sh
cd tools/expressiveos_flasher
npm ci
npm run deploy        # cf deploy: needs `cf auth login` once, as for ota-mirror
```

Nothing is public until this runs. After the first deploy:

- Publish a release so the page has something to list. On the build server, after `eos-pack.sh`:
  `python3 -I tools/expressiveos_flasher/publish/flasher_publish.py cheetah ~/releases/expressiveos-cheetah/<name>-fastboot.zip`.
  It uses the same `r2:` rclone remote as the OTA scripts.
- A custom domain (for example `flash.<your domain>`) can be added in the Cloudflare dashboard under the Worker's
  Settings, Domains & Routes, or by adding `domains: ["flash.example.com"]` to `cloudflare.config.ts`.

## Develop and test

```sh
npm ci
npm run dev           # local page and Worker (cf dev); R2 is a local, empty simulation
npm test              # unit tests (Vitest): sparse splitting, Zip64, the plans, whole installs on a simulated Pixel
npm run typecheck
npm run build && npm run test:e2e   # the built page in Chromium with a simulated phone behind navigator.usb
```

- `test/fake-phone.ts` simulates a Pixel's bootloader and fastbootd: A/B slots, physical partitions, logical partitions
  in super that `update-super` lays out and `resize-logical-partition` sizes (rounded up to 4 KiB, as liblp does), and
  restarts that hand out a new connection. The install tests check every partition byte for byte afterwards.
- `e2e/run.mjs` needs Playwright with Chromium (`require("playwright")`). It builds `e2e/fake-usb.ts` into a script that
  replaces `navigator.usb`, serves the built page with its real Content-Security-Policy from `public/_headers` and a
  small fixture release, and walks four runs: root with a paused and resumed download, no root with keep-data on a
  phone-sized screen where the browser asks for the phone again, the wrong phone, and a locked bootloader. Screenshots
  land in `e2e/out/screenshots/`.

## Files

| Path | What |
|---|---|
| `src/fastboot/` | The fastboot protocol over WebUSB, sparse images, `android-info.txt`, `fastboot-info.txt`, `super_empty.img` |
| `src/flash/` | The install plan, running it, and the checks before it (phone report, unlock) |
| `src/zip/zip.ts` | Zip64 central directory reader that hands out entries as Blob slices |
| `src/store/` | The download worker (OPFS sync access handle, SHA-256 as it downloads, resume) |
| `src/ui/` | The page: `app.ts` (the six steps), `bloom.ts` (the Bloom stage), `styles.css` |
| `worker/` | The Worker; `http.ts` holds its range and file-name checks, apart for the tests |
| `publish/` | `flasher_publish.py`, run on the build server to publish a release to R2 |
