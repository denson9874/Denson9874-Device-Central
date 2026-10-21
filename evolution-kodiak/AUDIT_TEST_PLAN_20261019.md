# Pixel 11 audit test builds: what to test (2026-10-19)

Test builds for kodiak, grizzly, cubs and yogi with the core-function fixes from
`KODIAK_AUDIT_20261019.md`. They're unrooted fastboot zips, packed by the release scripts but **not uploaded**:
`~/releases/<device>/test/EvolutionX-17.0-<date>-<device>-12.3-Unofficial[-rN]-AUDITTEST-fastboot.zip`
on the build server, each with a `.sha256` next to it.

| Phone | Zip (in `~/releases/<device>/test/` on the build server) | SHA-256 | Kernel |
|---|---|---|---|
| kodiak | `EvolutionX-17.0-20261019-kodiak-12.3-Unofficial-AUDITTEST-fastboot.zip` | `e200d1fd403160592ee52091d761509aed79f840a47950ab068a83ed3627176b` | Espada v3.5 (6.12.96) |
| grizzly | `EvolutionX-17.0-20261019-grizzly-12.3-Unofficial-AUDITTEST-fastboot.zip` | `c099a09cb32b8248b37bb252530f36a8b9bb17b1a29df5d87589ef63254f338a` | Espada v3.5 (6.12.96) |
| cubs | `EvolutionX-17.0-20261019-cubs-12.3-Unofficial-AUDITTEST-fastboot.zip` | `f9ea104cc9354169804e402c683c02cc9daf90d0001297b88cce73ea22932b81` | Espada v3.5 (6.12.96) |
| yogi | `EvolutionX-17.0-20261020-yogi-12.3-Unofficial-AUDITTEST-fastboot.zip` | `8738f47cf9cd8eca67dc768e020558ef978ee5e4eef648f993e981a205e80e22` | stock GKI (6.12.69) |

Checked on the server: each pack script passed (`check-sepolicy` OK against the phone's stock vendor, unrooted,
boot patch level 2026-10-05, CarrierSetup on our platform key). Each zip's kernel matches its `vendor_kernel_boot`
(Espada's pair on kodiak, grizzly and cubs; stock on yogi). Each image contains EuiccGoogle, WfcActivation, both
supplicant overlays, `libnfc-nci.conf`, the six new overlays and patch 0008.

## Before handing them out

- **Kernel:** kodiak, grizzly and cubs carry **Espada v3.5**, the kernel staged for the next release. Nobody has
  booted v3.5 on our phones yet (HANDOFF 2ah). yogi uses the stock kernel. The first tester on each of those three
  phones should only confirm that it boots and that Wi-Fi, mobile data and calls work.
- **Flashing:** testers on the 10-18 build can `fastboot update` the zip **without `-w`**. The Setup Wizard and
  eSIM-setup tests need a clean flash (`-w`), which erases the phone.
- **Undo:** re-flash the 10-18 release fastboot zip without `-w`.

## Tests

Mark each one pass, fail or not tested. For every fail, collect the logs below **right after** reproducing it.

| # | Area | How to test | Pass looks like |
|---|---|---|---|
| 1 | eSIM | Settings > Network > SIMs > Add SIM (or "Download a SIM instead") | Google's eSIM screen opens and can download or transfer a profile |
| 2 | Setup Wizard (clean flash) | Sign in to Google, continue through the SIM/eSIM step | The wizard moves on; it doesn't loop back to the account screen |
| 3 | Google Fi | Activate Fi with an eSIM | No error `T120`; if one appears, note the code |
| 4 | Apps' network access, existing installs | After updating, open apps that had no network before | They connect. Apps that **you** blocked on purpose stay blocked |
| 5 | Apps' network access, new | Install a new app from Play, let a few apps update, restore apps during setup | Every app has network without touching "Allow network access" |
| 6 | Wi-Fi | Daily use, sleep/wake, roaming between access points, a carrier/Passpoint network if available | No drops or reconnect loops; Passpoint networks connect |
| 7 | Wi-Fi in Setup Wizard (clean flash) | Wait on the Wi-Fi list for a minute, then connect | Networks stay in the list and connect |
| 8 | Wi-Fi Direct | Quick Share a file to another phone; cast if available | Transfer works |
| 9 | USB tethering | Settings > Hotspot & tethering > USB tethering, to a PC | The PC gets internet |
| 10 | Hotspot | Turn on the Wi-Fi hotspot, connect a device | Works as before |
| 11 | NFC (clean flash) | Settings > Connected devices > NFC right after setup | NFC is on by default |
| 12 | Tap to pay | Google Wallet at several terminals (different shops) | Payment goes through |
| 13 | Wi-Fi calling e911 (AT&T, Cricket, Rogers, Telus, Cox, Spectrum, Boost) | Settings > Wi-Fi calling > emergency address | The address screen opens |
| 14 | Mobile data / APN | On a clean flash, check Access Point Names; SFR users especially | The carrier's correct APN is selected. Existing installs: Access Point Names > ⋮ > Reset to default once |
| 15 | Calls | Voice and VoLTE calls, a Wi-Fi call | Calls connect and have audio both ways |
| 16 | Display | Extra dim, Night Light, AOD, auto-brightness at night | No flashes or wrong brightness (Extra dim now uses the panel's even-dimmer path) |
| 17 | Fingerprint (kodiak, grizzly, cubs) | Unlock; check Settings for swipe gestures | Unlock works; no swipe-gesture option |
| 18 | Face unlock | Unlock with face | Works as before |
| 19 | Small things | Screenshot > Edit; photo picker in any app; overheat warning (passive) | Pixel's editor opens; Google Photos shows in the picker |

## Logs to send for a failure

Enable USB debugging, reproduce, then within a few minutes:

```bash
adb logcat -b all -d > logcat.txt
```

```bash
adb shell dumpsys netpolicy > netpolicy.txt
```

For tests 1-3 (eSIM):

```bash
adb shell dumpsys econtroller > econtroller.txt
```

For tests 6-8 (Wi-Fi):

```bash
adb shell dumpsys wifi > wifi.txt
```

For test 4 or 5 (an app with no network), also the app's uid and install reason:

```bash
adb shell cmd package list packages -U <package.name>
```

```bash
adb shell dumpsys package <package.name> | grep -E "installReason|firstInstallTime|INTERNET"
```

## What the maintainer reads in the logs

- **Network access heal (tests 4-5):** first boot logs `NetworkPolicy: Restoring network access for restored
  uid=…` for each healed app, and `Keeping REJECT_ALL for uid=…, install reasons: pkg=N` for each app left blocked.
  If apps that should have been healed show up as kept, their install reason tells us how far the heal must reach.
- **New-install race (test 5):** `ACTION_PACKAGE_ADDED for uid=…, INTERNET requested or package unresolved; not
  restricting` means the fix just prevented a block.
- **Wi-Fi path (test 6):** `Initializing SupplicantStaIfaceHal using AIDL Mainline implementation`, and no
  `avc: denied` lines for `wifi_mainline_supplicant`.
- **eSIM (tests 1-3):** none of `No valid EuiccService implementation found`, `Could not resolve activity`, or a
  `FATAL EXCEPTION` in `com.google.android.euicc`.
