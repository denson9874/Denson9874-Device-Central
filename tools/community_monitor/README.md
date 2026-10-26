# Evolution X / DerpFest Community Review & Automated Poster

Automated suite for community feedback monitoring, issue triage, user issue acknowledgment replies, and automatic release notes publishing across XDA Forums and Telegram.

---

## 1. Architecture Overview

| Component | File | Description |
|---|---|---|
| **Daily Review Runner** | [`run_daily_review.py`](run_daily_review.py) | Coordinates ingestion, triaging, issue logging in `COMMUNITY_TRIAGE.md`, dispatching live replies, and publishing release notes. |
| **XDA Poster** | [`xda_poster.py`](xda_poster.py) | Posts acknowledgment replies to thread users and publishes release notes via authenticated Google Chrome Canary session (`denson9874`). |
| **Telegram Poster** | [`tg_poster.py`](tg_poster.py) | Posts replies to `@ExpressiveLauncherFeedback` and release notes to `@ExpressiveGroup` via Bot API or desktop bridge. Auto-escapes `.zip` names to prevent unwanted web linking. |
| **Release Publisher** | [`release_publisher.py`](release_publisher.py) | Inspects build artifacts (fastboot and recovery OTA zips, SHA-256 sums), collects resolved community issues, and broadcasts dual-platform release notes. |
| **Triage Processor** | [`triage_processor.py`](triage_processor.py) | Filters noise, categorizes issues (`Bug`, `Feature`, `Support`), generates issue tracker IDs (`ISS-YYYYMMDD-XX`), and updates `COMMUNITY_TRIAGE.md`. |
| **XDA Reader** | [`xda_reader.py`](xda_reader.py) | Ingests new thread posts via Playwright headless browser or Chrome session. |
| **Telegram Reader** | [`tg_reader.py`](tg_reader.py) | Fetches feedback messages and logcat/bugreport attachments via Telegram Bot API. |

---

## 2. Usage Instructions

Nothing here posts unless you pass `--auto-reply` or run a publisher without `--dry-run`. The daily review on its own
only reads, updates `COMMUNITY_TRIAGE.md`, and writes reply drafts to `evolution-kodiak/community/replies/`.
`--mock-feed` (made-up posts for testing) implies `--dry-run`, so it never touches the backlog, state or drafts.

Tests: `./venv/bin/python -m unittest discover -s tools/community_monitor/tests`

### A. Run Daily Review with Automated Replies
Processes new Telegram feedback and XDA thread posts, logs new issues into `COMMUNITY_TRIAGE.md`, and automatically posts acknowledgment replies to users on both platforms:
```bash
python3 tools/community_monitor/run_daily_review.py --auto-reply
```

### B. Dry-Run Mode (Preview Replies Without Posting)
```bash
python3 tools/community_monitor/run_daily_review.py --auto-reply --dry-run
```

### C. Automatically Publish Release Notes
Publishes release notes for a newly built ROM on XDA and Telegram. It refuses to post if either build zip (fastboot
or OTA) isn't found, and marks the community items `RELEASED` only after both posts succeed. Release items are the
rows `evolution-kodiak/tools/community_release_notes.py` selects (see Status Definitions in `COMMUNITY_TRIAGE.md`).
Preview first with `--dry-run`, which only writes the draft:
```bash
# For DerpFest on Pixel 11 Pro XL (kodiak):
python3 tools/community_monitor/release_publisher.py --device kodiak --rom DerpFest

# For Evolution X:
python3 tools/community_monitor/release_publisher.py --device kodiak --rom EvolutionX --version 12.3

# Integrated with Daily Review:
python3 tools/community_monitor/run_daily_review.py --auto-reply --publish-release kodiak --rom DerpFest
```

### D. Single-Issue Acknowledgment CLI
```bash
# XDA Issue Acknowledgment:
python3 tools/community_monitor/xda_poster.py \
  --device kodiak \
  --post-id 89753001 \
  --author "stevecaboose" \
  --issue-id ISS-20261016-03 \
  --quote-text "Dual-screen camera preview button is greyed out" \
  --category Bug \
  --status NEEDS_LOGS

# Telegram Issue Acknowledgment:
python3 tools/community_monitor/tg_poster.py \
  --chat ExpressiveLauncherFeedback \
  --device kodiak \
  --issue-id ISS-20261016-02 \
  --author "Ashray V K" \
  --text "Battery percentage icon style resets on reboot" \
  --category Bug \
  --status NEEDS_LOGS
```

---

## 3. Scheduled Daily Automation

Not installed yet. The intended schedule is **09:00 AM America/New_York**, drafts only (scheduled runs don't post on
XDA or Telegram; see HANDOFF 2j and 2af):
```cron
0 9 * * * cd ~/Developer/ExpressiveOS && tools/community_monitor/venv/bin/python tools/community_monitor/run_daily_review.py
```
It reviews new posts, updates `COMMUNITY_TRIAGE.md`, and writes reply drafts for Daryl to review and post.
