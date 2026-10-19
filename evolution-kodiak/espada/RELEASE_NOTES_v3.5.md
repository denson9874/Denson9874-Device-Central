# Espada Kernel v3.5 (2026-10-18)

Pixel 11 / 11 Pro / 11 Pro XL, October 2026 firmware.

v3.5 is the Anvil beta I have been testing since v3, moved to stable. It sits on a newer base,
Google's android16-6.12-lts branch at Linux 6.12.96 (v3 was on 6.12.92), and it brings a reworked
Simple LMK, a better little/mid core choice in CASS, a per-app uname spoof, USB OTG in recovery and
a pile of fixes.

## Read this before flashing
- October 2026 firmware only (CD1A.261005.003), same as v3. The zips refuse to flash on anything
  older or newer.
- Pick one zip:
  - `Espada-Kernel-spacecraft-v3.5-20261018.zip` has KernelSU-Next 3.4.2 + SuSFS v2.3.0 built in.
    That is the same driver as v3, so the 3.4.2 manager you already have is the right one. Do not
    combine it with Magisk.
  - `Espada-Kernel-spacecraft-v3.5-magisk-20261018.zip` is the plain kernel with no root built in.
    Keep your Magisk patched init_boot. The zip does not touch init_boot.
- The first boot after flashing takes about 6 seconds longer. That is Android, not the kernel: after
  any flash it mounts /data in a one-time safe mode and commits it once the boot is good. The second
  boot is back to normal.
- If you ran the Anvil V1.3.1 beta, the KSU zip has the exact same boot and vendor_kernel_boot
  images, so there is nothing new to flash.

## Changes since v3
1. New base: Linux 6.12.96 from Google's android16-6.12-lts branch. That brings 1,116 upstream fixes
   from 6.12.93 to 6.12.96 and 134 of Google's own changes. 303 of the upstream fixes touch code that
   is actually built into this kernel (the rest are for hardware the phone does not have). Among them:
   - binder: two use-after-free fixes (freeing a transaction, releasing a thread)
   - f2fs, the /data filesystem: two deadlock fixes in the garbage collection path and a
     use-after-free in atomic writes
   - erofs (the system partitions) and eventpoll: use-after-free fixes
   - USB gadget: a use-after-free when a gadget driver binds and a leak in f_fs, which adb runs on
   - networking: use-after-free fixes in IP fragment reassembly and IPsec policy lookup, plus
     overflow and out-of-bounds fixes in IPv6, netfilter and traffic control
   - memory: a shrinker teardown race and a writeback race at cgroup unmount
   - an ALSA timer use-after-free, an exFAT use-after-free (USB drives, SD cards) and an overflow in
     keyctl
   Some fixes v3 carried by hand are in Google's branch now, so they come from there.
2. Two changes from 6.12.9x are reverted because they break the Pixel:
   - "mailbox: Fix NULL message support in mbox_send_message()" keeps the AoC (the low-power chip
     behind audio, sensors and the always-on stuff) from starting. Google's AoC driver sends
     doorbells with no data, and with that change each one waits for the AoC to answer the previous
     one, which it never does while it is still booting. The phone sat on the boot animation for two
     minutes with no sound.
   - "block: invalidate cached plug timestamp after task switch" makes the scheduler clear a
     block-layer timestamp after every preemption, through a pointer it does not check. An interrupt
     landing at the wrong moment right after a batch of disk I/O makes the next task switch write
     through NULL. It crashed my phone twice in an hour during the beta. With the revert this is the
     same code as v3. The change only made a disk timing statistic more exact.
3. CASS decides between the little and the mid cores with the measured power numbers now. Until v3
   it always preferred a little core when the task fit, which is right when the phone is quiet. But
   the two little cores run at one shared clock that all the background work keeps up, so a light
   app thread often landed on a little core that was already running near its top speed while a mid
   core sat idle at the bottom. In traces of a scripted session with regular apps, about 70 % of the
   little cores' busy time was work that could have run on a mid. Now it compares what the work would
   cost on each side and only moves it when the mid is clearly cheaper. On a quiet phone it still
   picks the little cores.
   `echo N > /sys/module/cass/parameters/em_cluster` (as root) switches back to the v3 behaviour
   without a reboot, `echo Y` turns it on again. It is on by default.
4. Simple LMK reworked. When memory runs low it only kills cached apps, not the one you are using,
   and it sizes each app by the memory killing it would actually free, so it kills fewer apps in a
   row. Every kill round is logged in the kernel log. This also fixes lmkd crashing once per boot
   (GitHub issue #1).
5. octobot's per-app uname spoof. Play services' integrity check, Messages and Wallet see the stock
   October kernel version, everything else sees the real one, and the build date is the stock one
   for everybody.
6. USB OTG in recovery. In recovery the Pixel 11 bootloader brings the USB-C port up as sink only,
   so a recovery cannot power or use a USB stick. asdfmonster261's tcpm patch registers the port as
   dual-role again when the hardware says it can supply power. Normal boots are not affected, there
   the port is already dual-role. OrangeFox and AERA for the Pixel 11 need this in the kernel for OTG.
7. Fixes from 6.12 stable and mainline that Google has not merged yet:
   - a use-after-free when exec() fails half way with a CPU timer armed
   - use-after-free fixes in the IGMP and MLD timers when an interface goes away, in the path MTU
     code, and in TCP when a Fast Open connection runs into a simultaneous open
   - an overflow in TCP's delayed ACK timer on slow connections, and one in the scheduler's group
     load tracking that can end in a crash
   - two binder fixes: a superseded one-way transaction to a frozen app leaked the files it
     carried, and its cleanup could close unrelated files in that app
   - 11 fixes from 6.12.113: TCP, IPv4/IPv6, WireGuard, io_uring, USB f_fs, rtc and inode cleanup

Everything else carries over from v3: the zram read-ahead fix from GrapheneOS, the measured energy
model, the 3571 MHz prime cap and the built-in schedutil rate limits. The read-ahead fix is still in
both zips. It lives in Google's vh_mm module, which is why you will not find it in the kernel repo.

## Flashing
KernelSU-Next manager, Kernel Flasher, or a custom recovery. Franco Kernel Manager does not handle
these zips. With fastboot: unzip, then on your active slot `fastboot flash boot boot-es301.img` and
`fastboot flash vendor_kernel_boot vkb-es301.img`. The zips write boot and vendor_kernel_boot only,
no wipe needed. They back up what is on the phone first (`/data/local/tmp/boot-before-es301.img`
and `vkb-before-es301.img`). If those are already there from an earlier Espada flash, the old ones
are kept. To go back, flash the v3 zip or the stock October boot.img and vendor_kernel_boot.img.

## OrangeFox and AERA
If you install OrangeFox R12.0 or AERA R1.0 (asdfmonster261's builds for the Pixel 11 family) with
their own zip or script, they rebuild vendor_boot with the boot settings the recovery was built
with. Those add `arm64.nosme`, which turns the CPU's SME/SME2 units off in Android too, not only in
recovery, and change a module loading option. Nothing breaks that I have seen, but if you care,
check `cat /proc/cmdline` after installing it.

## If it reboots by itself
Please grab the crash log right away, the phone only keeps the last one. From a PC:
`adb shell su -c cat /sys/fs/pstore/console-ramoops-0 > ramoops.txt` and
`adb shell getprop persist.sys.boot.reason.history`. Send me both or attach them to an issue.

## Known
- The usual `rust_binder ... disagrees about version` lines in the kernel log at boot. The kernel
  falls back to the C binder driver, same as every Espada build.
- Tested on grizzly (11 Pro) on CD1A.261005.003. The KSU images are the ones running on my phone
  since October 16: two days of normal use, a Genshin session and a bunch of reboots, no crashes.
  Not measured on battery yet.
- The Magisk zip is the same source built without the root driver. I have not booted that one
  myself, so tell me if something is off.
- OTG in recovery is tested up to plugging something in: in OrangeFox and in AERA the port comes up
  dual-role, but I have not attached a USB device yet.
- cubs (11) and kodiak (11 Pro XL) use the same images, but I have not tested them myself. Reports
  from those are the most useful.

## Download
KernelSU-Next: `Espada-Kernel-spacecraft-v3.5-20261018.zip`
md5 `955845eb6af7aa2ddbfeb3a170c647a4`
sha256 `4b3ea6ca129949c3e2b118dda298c1f59a1919e23f659e397d4214760bd418f3`

Magisk: `Espada-Kernel-spacecraft-v3.5-magisk-20261018.zip`
md5 `65db6362afb8ef65ca01218381929146`
sha256 `0e6ba7a231b6093c4c44e020d0d795fcc309cea478bdb84f559a26ab597c9e74`

## Credits
Sultan Alsawaf for CASS, Simple LMK and the schedutil/cpuidle/QoS patches. Adam W. Willis (octobot)
for the uname spoof. asdfmonster261 for the tcpm OTG patch. The GrapheneOS project for the
read-ahead fix. The KernelSU-Next and SuSFS projects. Eric Dumazet, Hyunwoo Kim, Tomer Pomeranc,
Jens Axboe, Jason A. Donenfeld and the other upstream authors of the fixes picked here. Google for
the GPL kernel drop and the android16-6.12-lts branch.

Source: https://github.com/atrejokm301/espada-kernel (tag `v3.5`, branch `espada`; Magisk flavour on
branch `espada-magisk`). v3.5 was rebased onto the new base instead of merged into v3, so both
branches got a merge commit that keeps the v3 history. A plain `git pull` still works.

