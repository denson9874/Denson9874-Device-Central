# Working on ExpressiveOS: the checklist

Read this before any change, build, test or release. Each rule comes from something that
went wrong (or right) between Oct 25 and Nov 8, 2026; the retrospective has the stories.
GEMINI.md's honesty rules apply to Claude too.

## Daryl's standing rules

- Daryl (he/him) merges every PR himself. Open drafts, assign him, never merge his repos.
- Every time and ETA in US Eastern. Post a short progress line during any wait over an hour.
- Do the smallest thing that meets the ask with the tools that exist. Ask before new
  automation, big rewrites or multi-agent runs: they spend his quota.
- His go, in his own words, is needed for each of: flash, release (pack --upload), OTA
  upload, feed merge, server deletes, and any post on XDA or Telegram. A relayed OK is not his go.
- No root and no KernelSU in the ROM. Don't offer re-roots. Never source keyboxes, tune
  spoofing for DEVICE/STRONG, or claim Wallet, Play Integrity or attestation in notes.
- Never suggest turning off his work VPN. Never type the phone's PIN: ask him to unlock.

## Before you change anything

1. Check that no other thread owns the work (thread list, memory). Two threads on one
   task made twin branches and a superseded build.
2. Search the whole product, not just our diff: every fork, `vendor/` blobs and their
   sysconfig, and the built image. The AICore bug was one line in a vendor_gms XML that a
   kit-only grep missed.
3. When you swap which app holds a role (launcher, Recents, a provider), grep for the old
   package name and every overlay `targetPackage`. Nav bar styles broke this way.
4. A fork of ours changes by a new commit on the fork plus a manifest bump, never by a kit
   patch (a kit patch against a fork without the commit broke `repo sync`).
5. A check or script written for cheetah must be run against every phone family (husky,
   the Pixel 11s). Changelog lines and verify rules failed this way.
6. Never commit keys, keystores or tokens. Look at `git diff --cached` for `*.pk8`,
   `*.keystore`, `*.jks` and `pass:` before every push to a public repo.

## Reviewing code (every PR, ours and inherited)

- Inherited Evolution X, Axion and RisingOS code is ours now. On any change near it, check:
  exported components, binder calls without a caller (uid or permission) check, trust by
  package name (`com.android.launcher3`, anything containing "google") without a uid and
  system-app check, and settings any app can read. The Nov 7 audit found 11 such holes.
- Run a second, adversarial pass that tries to disprove each finding. Label every claim
  measured (with the log line, file:line or run id) or inferred.
- Kit scripts: run the offline tests as a non-root user
  (`runuser -u ubuntu -- expressiveos-cheetah/tools/tests/eos-ota-test.sh`); root hid a
  `cpio` failure that stopped the first build. `sources/tests/run.sh` after any update.py change.
  `tools/tests/gms-drop-test.sh` after any gms-drop.py change.
- Launcher (EL): `dex-refs.py` against the phone's BOOTCLASSPATH and a cold boot on an
  Android 12 emulator before every publish.

## Building

- A change you only want to try on a phone: `expressiveos-build` with `quick` (about 6.5 min
  against 19+). It is never released.
- Before a release build: list merged-but-unreleased work in every thread and ask Daryl once
  whether anything else rides along. The first 1.1.2 build (42 min) was thrown away because
  the Pixel Launcher switch joined after it.
- Release order: cheetah alone first (the 7 Pro test), then
  `devices=kodiak,grizzly,yogi,cubs,husky`. Each switch across the split between
  kodiak/grizzly/yogi and cheetah/husky/cubs rebuilds SystemUI and Settings (about 7 min);
  this order switches twice per release, the old one four times.
- Start that five-phone session as soon as cheetah's `expressiveos-ota candidate` is done,
  while the 7 Pro test runs. Waiting for the test left the server idle 20-60 min a release.
  If the test fails, the session is rebuilt; nothing is lost but server time. Write actions
  (device-ok, pack, ota) wait for the session to end: the runner refuses them meanwhile.
- The runner: a dispatch runs that ref's scripts (tree_ref doesn't change them); only one
  run waits, and a new dispatch cancels a waiting one, so list queued runs first and tell
  the thread that owns the server. Read a red run's log before trusting it. Device Central
  sends no PR events: check PRs by hand (the GitHub tools take the old name `denson9874/expressiveos`).

## Testing before a release (7 Pro first, driven over adb with logcat)

Daryl says "fine" when things aren't: run every check yourself and keep the logs.
- Install the candidate incremental through the Updater from the test feed, as users will.
- `adb logcat -b crash` empty; no new `SecurityException` or "association not allowed".
- `dumpsys activity allowed-associations`: nothing restricts `com.google.android.as.oss`.
- Now Playing downloads its database; `dumpsys jobscheduler` shows no job blocked by
  RESTRICTED_MODE.
- `pm path com.google.android.iwlan` returns a path; on a clean install RCS connects within
  10 minutes.
- Updater after the reboot: the installed build isn't listed, and What's new shows this
  release's notes for this phone (model and security patch right).
- `adb reboot fastboot`, `fastboot getvar is-userspace` = yes, then recovery shows its menu,
  on each phone we have (the Pixel 11 recovery once shipped broken for 4 days).
- Every check must be able to fail: an empty feed is not "up to date". A bug found after a
  release adds its check line here before its fix merges.
- Any crash, `SecurityException`, association or SELinux denial seen during a test is traced
  to a file and line, or reported as `UNEXPLAINED: <log line>`. Never write it off as noise,
  "usually" or pre-existing: the AICore denials were called "stock GMS noise" on Nov 1 and
  shipped in three releases.
- Phone tests run only on the phones Daryl has (7 Pro, kodiak, his 8 Pro when he says so).
  A phone nobody has (grizzly, cubs, yogi) needs no phone test: once its build passes its own
  verify, it goes to the release channel with the others (Daryl, 11-11: "No tests are
  needed"). Say plainly in the thread which phones were tested on a device.
- A rooted test phone: list root modules and their hidden paths before blaming the ROM. A
  ReSuSFS hidden-path list once crashed app zygotes and looked like a ROM bug.
- Never call something fixed without the adb output or log line that shows it.

## Each Pixel Drop

- Follow the kit README's "Pixel Drops": sort Google's list into the four groups per phone
  family, `tools/gms-drop.py compare` against the newest stock image, refresh vendor_gms by a
  fork commit plus a manifest pin, then test on the 7 Pro and one Pixel 11.
- A Drop feature is in the notes only with the adb output that shows it on that phone. Features
  behind Google's device check (on-device Gemini) are listed as not available, never worked around.
- Config XMLs in vendor_gms are never overwritten from stock: they carry our fixes (nowplaying.xml).

## Releasing (each step after Daryl's go for it)

device-ok -> `expressiveos-pack release devices=cheetah,kodiak,grizzly,yogi,cubs,husky`: one
session that, for each phone in turn, packs the release, uploads its OTA (reusing the tested
candidate incremental) and publishes it to the web installer, stopping at the first failure
(his go for it must cover the OTA upload too, as the 1.1.2 card did) -> `expressiveos-progress`
with query `feed` prints the feed files -> feed PR on expressiveos_ota (Daryl merges) ->
Drive backup (keeps the last two) and R2 prune (current only) ->
`server-cleanup` (keep each phone's newest target-files, the next incremental's base, and
husky's build output: its fresh build is the slowest, Daryl 11-08) ->
XDA thread titles, ROM Information lines and kernel source links (no new go needed) ->
Telegram and XDA drafts, posted only on his go.
Dispatch each step as soon as the one before it ends: on 1.1.2, with a dispatch per step and
phone, the server sat idle about 45 of the chain's 143 minutes.

## How Claude works (from its own Nov 8 self-review of every thread)

- Quota: one review pass by default, a second only for signing, flashing, security or
  release-pipeline code. A third pass, a new tool, or hardening code that can't run yet
  needs Daryl's yes on a card with an hour estimate. A direct instruction ("put the build
  on R2") means the next tool call does that step. When he says a thing is done, stop.
- Say running, done, live, merged, installed, missing or "can't" only with a tool result
  from the same turn, quoted; otherwise "not checked yet". Try once before "I can't".
- Every cause is "confirmed by <log line, repro or byte comparison>" or "hypothesis,
  disproved if <test>". No fix for a hypothesis merges or deploys before that test runs.
  When a bug cleared itself, first ask what changed in the minutes before.
- After Daryl merges: `git branch -r --contains <sha>` lists origin/main, and server scripts
  match the repo. Report "on main and live" or "merged, not live". A PR that needs another
  stays draft until its base is on main.
- Before a build over 15 minutes: the server tree is at the latest merged fix, the
  patch-against-fork check passes for changes under `patches/`, and a new verify script
  passes against the last good target-files.
- Daryl's phone: start with its state (serial, build date, root and init_boot sha256,
  firmware) and end with what changed and what stays changed. A no-wipe test flash replaces
  init_boot: say so first. Pick UI by text, never by coordinates; never Clear all, reset or
  uninstall.
- Public posts: each phone's values come from its own build info, every claim from a test,
  and every live page is opened after an edit to check links and preview text.
- When Daryl sets a rule or a thread finds a workaround, save it to memory in the same turn
  and fix any open card, PR body or brief that contradicts it. One thread owns each decision.
- Daryl gets only physical steps and consent. Steps for his Mac are copy-paste blocks that
  start with `cd <absolute path>`, list each prompt and its answer, give the exact consent
  phrase up front, and were dry-run first.
- One question per message or card; a second one says "I'll do X unless you say otherwise".
  The first sentence answers his question or confirms what he sees.
- Recommend shipping a ready, testable fix in the next build; recommend waiting only with a
  named risk. List the in-house option first: he picked it every time.
- Never ask for a PIN, password or token in chat, and never read a secret from the
  clipboard (`read -s`). Near attestation or integrity, state the boundary in the first message.
- Times come from `TZ=America/New_York date`. Post a revised ETA before a promised one passes.
