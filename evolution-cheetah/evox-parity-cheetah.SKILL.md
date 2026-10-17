---
name: evox-parity-cheetah
description: Weekly Evolution X parity build for the Pixel 7 Pro (cheetah) on the build server. Sundays, after the four Pixel 11 runs.
---

Weekly parity routine for the **Pixel 7 Pro (cheetah)**. Same job as evox-parity-kodiak/grizzly/cubs/yogi:
start the server's routine for one device, wait for it, report. Never flash a phone, never post on XDA or
Telegram, never edit or push any tree or script. Drafting announcement text for Daryl is fine.

1. SSH to the build server: `ssh -i ~/.ssh/voltage_build_ed25519 build@157.180.50.152`.
2. If `~/evolution-cheetah/prepare.sh` or `~/cheetah-images.sh` is missing, stop and report that cheetah
   isn't set up on the server (see ExpressiveOS `evolution-cheetah/README.md`).
3. Start the routine detached, so it survives the SSH session:
   `nohup ~/p11-routine.sh cheetah > ~/routine-logs/cheetah-latest.out 2>&1 &`
   It waits for the tree lock itself (the Pixel 11 runs go first), syncs if nobody synced in the last
   6 hours, and skips the build when nothing cheetah depends on changed.
4. Check every 10 minutes (`tail -3 ~/routine-logs/cheetah-latest.out`) until the last line starts with
   `ROUTINE_RESULT=`. Allow up to 10 hours: the lock wait, a sync, the kernel and the ROM build.
5. Report:
   - **PUBLISHED:** the fastboot zip and OTA names and SHA-256s (`~/releases/cheetah/*.sha256`), the
     `OTA_PUBLISHED` line, and the upstream changelog (`~/releases/cheetah/CHANGES-<date>.txt`, top
     projects only). Offer a short XDA/Telegram update draft in the style of the Pixel 11 ones, marked
     UNTESTED unless Daryl says a tester booted it.
   - **NOCHANGE:** one line, nothing else.
   - **FAILED:** the `FAIL:` line and the 30 lines before it from the log the last line names. If the
     build failed, add the first `FAILED:`/`error:` lines from `~/cheetah-build.log`.
     Don't retry and don't change anything.
