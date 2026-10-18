#!/usr/bin/env python3
"""
Triage Processor for ExpressiveOS / Evolution X Community Feedback.
Analyzes ingested posts from Telegram and XDA, classifies bugs/features/support,
maintains the persistent backlog in COMMUNITY_TRIAGE.md, and formats daily reply drafts.
"""

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Any


class TriageProcessor:
    def __init__(self, triage_path: Optional[str] = None):
        if triage_path is None:
            # Default to root of repo
            triage_path = str(Path(__file__).resolve().parents[2] / "COMMUNITY_TRIAGE.md")
        self.triage_path = Path(triage_path)

    def is_noise(self, text: str) -> bool:
        """Determines if a comment is trivial pleasantry/acknowledgement."""
        clean = text.strip().lower()
        noise_phrases = [
            "clean flash", "me the same", "latest build from today", "hmm interesting.",
            "i want to try it tomorrow", "sorry for the ot", "looked solid with no issues",
            "crazy coincidence for my chargers to go kaput", "oh, then somethings at my end",
            "well idk, i never had to manually enable data", "interestingly, i have data access",
            "feel free to install", "chargers to go kaput", "somethings at my end",
            "charging speeds havent improved", "chargers now, or the charging wattage",
            "extreme charging toggle doesnt seem to do anything",
            "would be good if any other testers report too",
            "as crazy as it sounds, i had a pixel 8 pro",
            "great, i’ll keep an eye out", "great, i'll keep an eye out"
        ]
        if any(p in clean for p in noise_phrases):
            return True
        if len(clean) < 60 and not any(k in clean for k in ["?", "issue", "bug", "crash", "fail", "broken", "why", "how", "log", "problem", "error", "can you", "bootloop", "freeze", "data access", "wifi", "sms"]):
            return True
        if len(clean) < 150 and any(w in clean for w in ["thanks", "thank you", "thx", "+1", "good job", "awesome", "nice", "downloaded", "flashed", "super smooth", "running great", "perfect"]):
            # If it doesn't contain a question mark or bug/issue words, it's noise
            if not any(k in clean for k in ["?", "issue", "bug", "crash", "fail", "broken", "why", "how", "log", "problem", "error", "can you", "exception", "freeze"]):
                return True
        if clean in ["lol", "haha", "ok", "cool", "following", "bump", "."]:
            return True
        return False

    def detect_device(self, item: Dict[str, Any]) -> str:
        """Infers the device codename from thread metadata or message text."""
        # 1. Thread metadata
        dev = item.get("device")
        if dev and dev != "unknown":
            return dev

        text = (item.get("text") or "").lower()
        if any(w in text for w in ["kodiak", "pro xl", "11 pro xl", "p11 pro xl", "pixel 11 pro xl"]):
            return "kodiak"
        if any(w in text for w in ["fold", "yogi", "inner screen", "outer screen", "hinge"]):
            return "yogi"
        if any(w in text for w in ["husky", "pixel 8 pro", "p8p"]):
            return "husky"
        if any(w in text for w in ["cubs", "pixel 11 standard", "base pixel 11"]):
            return "cubs"
        if any(w in text for w in ["grizzly", "pixel 11 pro"]):
            return "grizzly"

        if item.get("source") == "telegram":
            return "kodiak"
        return "all"

    def classify_item(self, item: Dict[str, Any]) -> Dict[str, Any]:
        """Classifies an item into category, severity, and suggested status."""
        text = (item.get("text") or "").lower()
        device = self.detect_device(item)
        has_attachments = bool(item.get("attachments")) or bool(item.get("quotes"))

        # Check for crash/bug keywords
        bug_keywords = [
            "crash", "reboot", "bootloop", "freeze", "denied", "error", "fail",
            "doesn't work", "broken", "disconnect", "blank screen", "black screen",
            "hang", "panic", "selinux", "avc", "timeout", "drain", "cant access",
            "can't access", "disabled", "drops from the list", "sms"
        ]
        feature_keywords = [
            "can you add", "would be great", "feature request", "please support",
            "option to", "toggle for", "bodega", "charging limit", "qs tile", "hilight",
            "facial unlock", "face unlock", "banking"
        ]
        support_keywords = [
            "how to", "waiting for any device", "can i dirty flash", "magisk",
            "susfs", "module", "fastboot", "driver", "pc doesn't see"
        ]

        if any(k in text for k in bug_keywords):
            category = "Bug"
            severity = "Critical" if any(c in text for c in ["bootloop", "panic", "call fail", "sim", "telephony"]) else ("High" if "sms" in text else "Medium")
            status = "TRIAGED" if (has_attachments or "log" in text or "turns out" in text or "reproduce" in text or "clean flash" in text) else "NEEDS_LOGS"
        elif any(k in text for k in feature_keywords):
            category = "Feature"
            severity = "High" if "charging" in text or "battery" in text else "Medium"
            status = "TRIAGED"
        elif any(k in text for k in support_keywords):
            category = "Support"
            severity = "Medium"
            status = "TRIAGED"
        else:
            category = "General"
            severity = "Low"
            status = "TRIAGED"

        return {
            "device": device,
            "category": category,
            "severity": severity,
            "status": status
        }

    def _get_max_issue_num(self, date_prefix: str) -> int:
        if not self.triage_path.exists():
            return 0
        content = self.triage_path.read_text(encoding="utf-8")
        max_num = 0
        for match in re.finditer(r"`ISS-(\d{8})-(\d+)`", content):
            d_str, num_str = match.groups()
            if d_str == date_prefix:
                max_num = max(max_num, int(num_str))
        return max_num

    def process_items(
        self,
        items: List[Dict[str, Any]],
        date_str: Optional[str] = None
    ) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
        """
        Filters noise, classifies actionable items, assigns issue IDs, and prepares reply drafts.
        Returns: (actionable_items, reply_drafts)
        """
        if date_str is None:
            date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

        date_prefix = date_str.replace("-", "")
        max_id_num = self._get_max_issue_num(date_prefix)

        actionable = []
        replies = []

        seen_author_categories = {}
        for item in items:
            author = item.get("author", "Anonymous")
            if author.lower() in ["denson9874", "daryl", "me", "expressive group"]:
                continue

            text = item.get("text", "")
            if self.is_noise(text):
                continue

            classification = self.classify_item(item)
            cat = classification["category"]
            dev = classification["device"]
            source = item.get("source", "unknown")
            key = (source, author.lower())

            if key in seen_author_categories:
                existing = seen_author_categories[key]
                if len(text) > 25 and text not in existing["text"]:
                    existing["text"] += f" {text}"
                if cat in ["Bug", "Feature"] and existing["category"] == "General":
                    existing["category"] = cat
                    existing["severity"] = classification["severity"]
                    existing["status"] = classification["status"]
                continue

            max_id_num += 1
            issue_id = f"ISS-{date_prefix}-{max_id_num:02d}"

            item_info = {
                "issue_id": issue_id,
                "date": date_str,
                "source": source,
                "author": author,
                "text": text,
                "device": dev,
                "category": cat,
                "severity": classification["severity"],
                "status": classification["status"],
                "raw_item": item
            }
            seen_author_categories[key] = item_info
            actionable.append(item_info)

        for it in actionable:
            draft = self.generate_reply_draft(it)
            if draft:
                replies.append(draft)

        return actionable, replies

    def generate_reply_draft(self, item: Dict[str, Any]) -> Dict[str, Any]:
        """Generates a contextual reply draft adhering to the project's communication tone."""
        source = item["source"]
        author = item["author"]
        category = item["category"]
        text = item["text"]
        device = item["device"]
        issue_id = item.get("issue_id", "ISSUE")
        raw = item.get("raw_item", {})

        reply_content = ""
        if source == "xda":
            post_id = raw.get("post_id", "")
            thread_id = raw.get("thread_id", "")
            quote_snippet = text.strip()
            if len(quote_snippet) > 150:
                quote_snippet = quote_snippet[:150] + "..."
            quote_block = f'[QUOTE="{author}, post: {post_id}"]\n{quote_snippet}\n[/QUOTE]\n\n'

            if "sms" in text.lower():
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                    f"Thanks for testing the new cubs build and reporting this! We are investigating the 5G NR SMS/IMS stack configuration for the cubs Tensor G6 baseline so SMS receives properly on 5G without needing to force LTE.\n"
                    f"Tracked under [ICODE]{issue_id}[/ICODE] for the upcoming Sunday release."
                )
            elif "facial unlock" in text.lower() or "face unlock" in text.lower():
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                    f"The ROM is currently using Google's Face Unlock HAL with Pixel's biometric framework. We are evaluating Class 3 (Strong) BiometricPrompt elevation requirements for banking app authentication support in upcoming builds.\n"
                    f"Tracked under [ICODE]{issue_id}[/ICODE]."
                )
            elif "setup wizard" in text.lower() or "apatch" in text.lower():
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                    f"Thanks for the update and for confirming KernelSU works cleanly with the Espada kernel! We are looking into the Setup Wizard Wi-Fi scan drop behavior for the next update cycle."
                )
            elif category == "Bug" and item["status"] == "NEEDS_LOGS":
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                    f"Thanks for the report! To help track this down on {device}, could you grab a logcat right after the issue occurs?\n"
                    f"If you have root, you can run:\n"
                    f"[ICODE]su -c \"logcat -b all -d > /sdcard/issue_{issue_id}.txt\"[/ICODE]\n"
                    f"and attach the file. Let us know if you have any custom Magisk/KernelSU modules active."
                )
            elif category == "Support" and "waiting for any device" in text.lower():
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                    f"If fastboot is stuck on \"< waiting for any device >\", your PC isn't detecting the device in bootloader mode.\n"
                    f"Reboot to bootloader via [ICODE]adb reboot bootloader[/ICODE], verify [ICODE]fastboot devices[/ICODE] prints your serial, "
                    f"and use a direct USB-C port without hubs."
                )
            else:
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                    f"Thank you for the feedback on {device}! This has been triaged for the upcoming release cycle."
                )

            return {
                "source": "xda",
                "author": author,
                "thread_id": thread_id,
                "post_id": post_id,
                "device": device,
                "issue_id": issue_id,
                "category": category,
                "status": item["status"],
                "text": text,
                "bbcode": reply_content
            }

        elif source == "telegram":
            msg_id = raw.get("message_id", "")
            chat_id = raw.get("chat_id")
            chat_name = raw.get("chat_name", "ExpressiveLauncherFeedback")
            quote_snippet = text.strip().replace("\n", " ")
            if len(quote_snippet) > 100:
                quote_snippet = quote_snippet[:100] + "..."
            quote_block = f"> {author}: \"{quote_snippet}\"\n\n"

            if "facial unlock" in text.lower() or "face unlock" in text.lower():
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] Acknowledged**\n"
                    f"The ROM is using Google's Face Unlock HAL with Pixel biometric framework. We are evaluating Class 3 (Strong) BiometricPrompt elevation requirements for banking app authentication in upcoming builds.\n"
                    f"Tracked under `{issue_id}`."
                )
            elif "data" in text.lower() and ("access" in text.lower() or "disabled" in text.lower() or "cant access" in text.lower()):
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] Acknowledged**\n"
                    f"Thanks for isolating this on {device}, {author}! The background/mobile data restriction default on clean flash is being addressed in system overlays for Sunday's release.\n"
                    f"Tracked under `{issue_id}`."
                )
            elif category == "Bug" and item["status"] == "NEEDS_LOGS":
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] Acknowledged**\n"
                    f"Thanks for the report! Could you capture a logcat of the issue on {device} so we can inspect the root cause?\n"
                    f"`su -c \"logcat -b all -d > /sdcard/log_{issue_id}.txt\"`\n"
                    f"Then send the file here. Thank you!"
                )
            elif category == "Feature":
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] Logged**\n"
                    f"Good suggestion for {device}! Triaged for evaluation in this week's development cycle for Sunday builds."
                )
            else:
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] Acknowledged**\n"
                    f"Thanks for the update on {device}, {author}! Looking into this for the next update."
                )

            return {
                "source": "telegram",
                "author": author,
                "message_id": msg_id,
                "chat_name": chat_name,
                "chat_id": chat_id,
                "device": device,
                "issue_id": issue_id,
                "category": category,
                "status": item["status"],
                "text": text,
                "markdown": reply_content
            }

        return {}

    def update_backlog(self, actionable_items: List[Dict[str, Any]]) -> int:
        """
        Appends new actionable items into COMMUNITY_TRIAGE.md.
        Avoids duplicate entries by checking author and similar summaries.
        Returns the number of newly added items.
        """
        if not self.triage_path.exists():
            return 0

        content = self.triage_path.read_text(encoding="utf-8")
        lines = content.splitlines()

        # Find the table rows under ## Active Community Backlog
        table_start_idx = -1
        for i, line in enumerate(lines):
            if "## Active Community Backlog" in line:
                table_start_idx = i
                break

        if table_start_idx == -1:
            return 0

        # Scan for existing issues
        existing_summaries = set()
        for line in lines[table_start_idx:]:
            if line.startswith("| `ISS-"):
                parts = [p.strip() for p in line.split("|")]
                if len(parts) > 8:
                    existing_summaries.add(parts[8].lower()[:40])

        new_rows = []
        added_count = 0

        for item in actionable_items:
            summary_key = item["text"][:40].lower()
            if summary_key in existing_summaries:
                continue

            item_date = item.get("date") or datetime.now(timezone.utc).strftime("%Y-%m-%d")
            date_prefix = item_date.replace("-", "")

            issue_id = item.get("issue_id")
            if not issue_id:
                max_id = self._get_max_issue_num(date_prefix) + 1
                issue_id = f"ISS-{date_prefix}-{max_id:02d}"

            source_tag = "TG" if item["source"] == "telegram" else "XDA"
            post_id = (item.get("raw_item") or {}).get("post_id")
            if source_tag == "XDA" and post_id:
                source_author = f"XDA: {item['author']} (Post #{post_id})"
            else:
                source_author = f"{source_tag}: {item['author']}"

            device = item["device"]
            category = item["category"]
            severity = item["severity"]
            status = item["status"]
            summary = item["text"].replace("\n", " ").replace("|", "\\|")
            summary = re.sub(r"\s+", " ", summary).strip()
            if len(summary) > 120:
                summary = summary[:117] + "..."
            target_release = "Next Sunday"

            row = (
                f"| `{issue_id}` | {item_date} | {source_author} | `{device}` | "
                f"{category} | {severity} | `{status}` | {summary} | {target_release} |"
            )
            new_rows.append(row)
            added_count += 1

        if not new_rows:
            return 0

        # Insert new rows right after the last table row before the next heading or separator
        insert_idx = -1
        for i in range(table_start_idx + 3, len(lines)):
            if lines[i].startswith("---") or lines[i].startswith("## "):
                insert_idx = i - 1
                while insert_idx > table_start_idx and not lines[insert_idx].startswith("|"):
                    insert_idx -= 1
                insert_idx += 1
                break

        if insert_idx == -1:
            insert_idx = len(lines)

        updated_lines = lines[:insert_idx] + new_rows + lines[insert_idx:]
        self.triage_path.write_text("\n".join(updated_lines) + "\n", encoding="utf-8")
        return added_count


if __name__ == "__main__":
    triage = TriageProcessor()
    sample_items = [
        {
            "source": "xda",
            "author": "PixelFan2026",
            "device": "yogi",
            "text": "The outer display on yogi is freezing when unfolding the device quickly. Log attached.",
            "attachments": ["freeze.log"]
        },
        {
            "source": "telegram",
            "author": "JohnDoe",
            "text": "Thanks for the great build!"
        }
    ]
    actionable, replies = triage.process_items(sample_items)
    print(f"Actionable: {len(actionable)}, Replies drafted: {len(replies)}")
    for r in replies:
        print(r)
