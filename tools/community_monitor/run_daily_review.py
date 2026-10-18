#!/usr/bin/env python3
"""
Master Daily Review Runner for ExpressiveOS / Evolution X.
Coordinates Telegram and XDA ingestion, triages comments, updates COMMUNITY_TRIAGE.md,
and prepares daily response drafts and summary briefing.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Any

# Ensure local imports work cleanly
script_dir = Path(__file__).resolve().parent
sys.path.insert(0, str(script_dir))

from tg_reader import TelegramReader
from xda_reader import XDAReader
from triage_processor import TriageProcessor
from xda_poster import XDAPoster
from tg_poster import TelegramPoster
from release_publisher import ReleasePublisher


def load_state(state_file: Path) -> Dict[str, Any]:
    if state_file.exists():
        try:
            with open(state_file, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            sys.stderr.write(f"[ReviewRunner] Failed to read state file: {e}\n")
    return {"telegram": {"last_update_id": 0}, "xda": {}}


def save_state(state_file: Path, state: Dict[str, Any]):
    state_file.parent.mkdir(parents=True, exist_ok=True)
    with open(state_file, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)


def telegram_chat_target(reply: Dict[str, Any], config: Dict[str, Any]) -> str:
    """Where a Telegram reply goes: the numeric chat id, else the group's @handle from config.

    chat_name is the group's display title ("Expressive Group Feedback"), which the Bot API
    can't address."""
    if reply.get("chat_id"):
        return str(reply["chat_id"])
    for group in config.get("telegram", {}).get("groups", []):
        if reply.get("chat_name") in (group.get("name"), group.get("chat_identifier")):
            return group["chat_identifier"]
    return "ExpressiveLauncherFeedback"


def get_mock_feed(date_str: str) -> List[Dict[str, Any]]:
    """Provides realistic sample posts for testing the pipeline offline."""
    return [
        {
            "source": "telegram",
            "chat_name": "Expressive Group Feedback",
            "message_id": 1042,
            "author": "Ashray V K",
            "timestamp": f"{date_str}T10:15:00Z",
            "text": "The battery percentage icon style option in Expressive Lab is resetting to default after rebooting on kodiak. Here is the logcat.",
            "attachments": [
                {
                    "file_name": "battery_icon_logcat.txt",
                    "mime_type": "text/plain",
                    "file_size": 45120
                }
            ]
        },
        {
            "source": "telegram",
            "chat_name": "Expressive Group Feedback",
            "message_id": 1043,
            "author": "PixelLover",
            "timestamp": f"{date_str}T10:22:00Z",
            "text": "Thanks for the latest build! Working super smooth so far!"
        },
        {
            "source": "xda",
            "thread_id": "4804826",
            "thread_name": "Pixel 11 Pro Fold (yogi)",
            "device": "yogi",
            "post_id": "89753001",
            "author": "stevecaboose",
            "timestamp": f"{date_str}T11:05:00Z",
            "text": "Hey Daryl! Tested yogi today. Fold/unfold transition works great, but the camera app dual-screen preview button is greyed out when unfolded.",
            "quotes": []
        },
        {
            "source": "xda",
            "thread_id": "4805239",
            "thread_name": "Pixel 8 Pro (husky)",
            "device": "husky",
            "post_id": "89754010",
            "author": "AndroidTinkerer",
            "timestamp": f"{date_str}T11:45:00Z",
            "text": "Can you add a Quick Settings tile for turning off 5G on husky to save battery when on Wi-Fi?",
            "quotes": []
        }
    ]


def main():
    parser = argparse.ArgumentParser(description="ExpressiveOS Daily Community Review Runner")
    parser.add_argument("--dry-run", action="store_true", help="Run without writing state or triage updates")
    parser.add_argument("--mock-feed", action="store_true", help="Use simulated mock feed for testing (implies --dry-run)")
    parser.add_argument("--date", type=str, default=None, help="Target date in YYYY-MM-DD format")
    parser.add_argument("--skip-tg", action="store_true", help="Skip Telegram ingestion")
    parser.add_argument("--skip-xda", action="store_true", help="Skip XDA ingestion")
    parser.add_argument("--auto-reply", action="store_true", help="Automatically reply to users on XDA and Telegram acknowledging their reported issues")
    parser.add_argument("--publish-release", choices=["kodiak", "grizzly", "cubs", "yogi", "husky", "all"], default=None, help="Automatically publish release notes for a device across XDA and Telegram")
    parser.add_argument("--rom", choices=["DerpFest", "EvolutionX"], default="DerpFest", help="Target ROM for release notes publication (default: DerpFest)")
    args = parser.parse_args()
    # The mock feed is made-up posts: it must never reach the backlog, state, drafts or a live reply
    if args.mock_feed:
        args.dry_run = True

    date_str = args.date or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    date_compact = date_str.replace("-", "")

    # Load configuration
    config_file = script_dir / "config.json"
    with open(config_file, "r", encoding="utf-8") as f:
        config = json.load(f)

    repo_root = script_dir.resolve().parents[1]
    paths_cfg = config.get("paths", {})

    state_file = repo_root / paths_cfg.get("state_file", "evolution-kodiak/community/state.json")
    raw_dir = repo_root / paths_cfg.get("raw_dir", "evolution-kodiak/community/daily_raw")
    replies_dir = repo_root / paths_cfg.get("replies_dir", "evolution-kodiak/community/replies")
    attachments_dir = repo_root / paths_cfg.get("attachments_dir", "evolution-kodiak/community/attachments") / date_str
    triage_file = repo_root / paths_cfg.get("triage_file", "COMMUNITY_TRIAGE.md")

    raw_dir.mkdir(parents=True, exist_ok=True)
    replies_dir.mkdir(parents=True, exist_ok=True)

    state = load_state(state_file)
    print(f"=== ExpressiveOS Daily Community Review: {date_str} ===")

    all_raw_items = []
    new_tg_offset = state.get("telegram", {}).get("last_update_id", 0)

    if args.mock_feed:
        print("[ReviewRunner] Using mock community feed for demonstration / testing.")
        all_raw_items = get_mock_feed(date_str)
    else:
        # 1. Telegram Ingestion
        if not args.skip_tg:
            tg_reader = TelegramReader(config_path=str(config_file))
            if tg_reader.is_configured():
                print("[ReviewRunner] Ingesting Telegram feedback via Bot API...")
                last_offset = state.get("telegram", {}).get("last_update_id")
                tg_msgs, next_offset = tg_reader.fetch_updates(
                    offset=last_offset,
                    download_attachments=not args.dry_run,
                    attachments_dir=str(attachments_dir)
                )
                print(f"  -> Fetched {len(tg_msgs)} new Telegram messages.")
                all_raw_items.extend(tg_msgs)
                if next_offset:
                    new_tg_offset = next_offset
            elif tg_reader.is_desktop_available():
                print("[ReviewRunner] Ingesting Telegram feedback via Desktop bridge...")
                last_offset = state.get("telegram", {}).get("last_update_id")
                tg_msgs, next_offset = tg_reader.fetch_desktop_updates(offset=last_offset)
                print(f"  -> Fetched {len(tg_msgs)} new Telegram messages.")
                all_raw_items.extend(tg_msgs)
                if next_offset:
                    new_tg_offset = next_offset
            else:
                print("[ReviewRunner] Telegram bot token not configured and Desktop not open; skipping Telegram.")

        # 2. XDA Ingestion
        if not args.skip_xda:
            xda_reader = XDAReader(config_path=str(config_file))
            if xda_reader.is_available():
                engine_name = "Chrome Canary session" if xda_reader.is_chrome_available() else "Playwright"
                print(f"[ReviewRunner] Ingesting XDA threads via {engine_name}...")
                xda_posts, updated_state = xda_reader.fetch_all_threads(state)
                print(f"  -> Fetched {len(xda_posts)} new XDA posts.")
                all_raw_items.extend(xda_posts)
                state = updated_state
            else:
                print("[ReviewRunner] Neither Playwright nor Chrome Canary available; skipping live XDA scraping.")

    # Save raw feed
    raw_archive = raw_dir / f"raw_{date_compact}.json"
    if not args.dry_run and all_raw_items:
        with open(raw_archive, "w", encoding="utf-8") as f:
            json.dump(all_raw_items, f, indent=2)
        print(f"[ReviewRunner] Saved raw feed to: {raw_archive}")

    # 3. Triage & Backlog Processing
    processor = TriageProcessor(triage_path=str(triage_file))
    actionable_items, replies = processor.process_items(all_raw_items, date_str=date_str)
    print(f"[ReviewRunner] Triaged {len(all_raw_items)} total items -> {len(actionable_items)} actionable, {len(replies)} replies drafted.")

    added_count = 0
    if not args.dry_run:
        added_count = processor.update_backlog(actionable_items)
        state.setdefault("telegram", {})["last_update_id"] = new_tg_offset
        save_state(state_file, state)

    # 4. Save formatted replies draft
    replies_file = replies_dir / f"COMMUNITY_REPLIES_{date_compact}.md"
    if replies:
        reply_lines = [
            f"# Community Replies Draft ({date_str})\n",
            "Review and approve these response drafts before posting to Telegram or XDA.\n",
            "---\n"
        ]

        # Group replies by source
        tg_replies = [r for r in replies if r.get("source") == "telegram"]
        xda_replies = [r for r in replies if r.get("source") == "xda"]

        if tg_replies:
            reply_lines.append("## Telegram Replies (`@ExpressiveLauncherFeedback`)\n")
            for r in tg_replies:
                reply_lines.append(f"### In reply to {r['author']}:\n")
                reply_lines.append("```markdown")
                reply_lines.append(r.get("markdown", ""))
                reply_lines.append("```\n")

        if xda_replies:
            reply_lines.append("## XDA Replies\n")
            for r in xda_replies:
                reply_lines.append(f"### In reply to {r['author']} (Post #{r.get('post_id')}):\n")
                reply_lines.append("```bbcode")
                reply_lines.append(r.get("bbcode", ""))
                reply_lines.append("```\n")

        if not args.dry_run:
            with open(replies_file, "w", encoding="utf-8") as f:
                f.write("\n".join(reply_lines))
            print(f"[ReviewRunner] Formatted reply drafts saved to: {replies_file}")

    # 5. Live Auto-Reply Execution (acknowledging user reports)
    replies_sent_count = 0
    if args.auto_reply and replies:
        print("\n[ReviewRunner] Dispatching live acknowledgments to Telegram and XDA...")
        xda_poster = XDAPoster(config_path=str(config_file))
        tg_poster = TelegramPoster(config_path=str(config_file))
        posted_replies = set(state.get("posted_replies", []))

        for r in replies:
            source = r.get("source")
            author = r.get("author")
            issue_id = r.get("issue_id")

            if source == "xda":
                post_id = str(r.get("post_id", ""))
                key = f"xda_{post_id}"
                if key in posted_replies:
                    print(f"  -> Skipping already acknowledged XDA post #{post_id} ({author})")
                    continue

                print(f"  -> Acknowledging XDA post #{post_id} from {author} (Issue: {issue_id})...")
                res = xda_poster.acknowledge_issue(
                    thread_id=r.get("thread_id") or r.get("device") or "kodiak",
                    post_id=post_id,
                    author=author,
                    device=r.get("device", "kodiak"),
                    issue_id=issue_id,
                    user_text=r.get("text", ""),
                    category=r.get("category", "General"),
                    status=r.get("status", "TRIAGED"),
                    dry_run=args.dry_run
                )
                if res.get("success"):
                    posted_replies.add(key)
                    replies_sent_count += 1
                else:
                    print(f"     [WARN] Failed to post XDA reply: {res.get('error')}")

            elif source == "telegram":
                msg_id = r.get("message_id")
                key = f"tg_{msg_id}" if msg_id else f"tg_{author}_{issue_id}"
                if key in posted_replies:
                    print(f"  -> Skipping already acknowledged Telegram message from {author}")
                    continue

                print(f"  -> Acknowledging Telegram message from {author} (Issue: {issue_id})...")
                res = tg_poster.acknowledge_issue(
                    author=author,
                    device=r.get("device", "kodiak"),
                    issue_id=issue_id,
                    user_text=r.get("text", ""),
                    category=r.get("category", "General"),
                    status=r.get("status", "TRIAGED"),
                    message_id=msg_id,
                    chat_identifier=telegram_chat_target(r, config),
                    dry_run=args.dry_run
                )
                if res.get("success"):
                    posted_replies.add(key)
                    replies_sent_count += 1
                else:
                    print(f"     [WARN] Failed to post Telegram reply: {res.get('error')}")

        if not args.dry_run:
            state["posted_replies"] = list(posted_replies)
            save_state(state_file, state)

    # 6. Automatic Release Notes Publication
    if args.publish_release:
        target_devs = ["kodiak", "grizzly", "cubs", "yogi", "husky"] if args.publish_release == "all" else [args.publish_release]
        publisher = ReleasePublisher(triage_path=str(triage_file))
        published = []
        for dev in target_devs:
            print(f"\n[ReviewRunner] Publishing release notes for {dev.upper()} ({args.rom})...")
            pub_res = publisher.publish_release(
                rom=args.rom,
                device=dev,
                dry_run=args.dry_run,
                mark_released=False
            )
            xda_ok = pub_res.get('xda', {}).get('success')
            tg_ok = pub_res.get('telegram', {}).get('success')
            print(f"  -> XDA: {xda_ok}, TG: {tg_ok}")
            if xda_ok and tg_ok:
                published.append(dev)
        # Once for the whole run, so a row for several devices closes when all of them shipped
        if not args.dry_run and published:
            marked = publisher.mark_items_released(published, args.rom)
            print(f"[ReviewRunner] Marked RELEASED in {triage_file.name}: {', '.join(marked) or 'nothing'}")

    # 7. Daily Summary Output
    print("\n" + "="*50)
    print(f"DAILY COMMUNITY BRIEFING ({date_str})")
    print("="*50)
    print(f"• Items Reviewed: {len(all_raw_items)}")
    print(f"• Actionable Items: {len(actionable_items)} ({added_count} added to COMMUNITY_TRIAGE.md)")
    print(f"• Reply Drafts Prepared: {len(replies)}")
    if args.auto_reply:
        label = "Replies Previewed (dry-run, nothing sent)" if args.dry_run else "Live Replies Sent"
        print(f"• {label}: {replies_sent_count}")
    if actionable_items:
        print("\nActionable Items Identified:")
        for item in actionable_items:
            print(f"  - [{item['device'].upper()}][{item['category']}] {item['author']}: {item['text'][:80]}...")
    if replies:
        print(f"\nDraft Responses Available in:\n  {replies_file}")
    print("="*50 + "\n")


if __name__ == "__main__":
    main()
