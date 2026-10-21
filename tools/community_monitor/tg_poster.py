#!/usr/bin/env python3
"""
Telegram Reply and Release Notes Poster for ExpressiveOS / Evolution X.
Automates posting replies to acknowledge user reports in @ExpressiveLauncherFeedback
and publishing release announcements to @ExpressiveGroup.
Supports:
1. Telegram Bot API (via token in TELEGRAM_TRIAGE_BOT_TOKEN or ~/.telegram_triage_bot_token)
2. macOS Telegram.app / Web Bridge for direct desktop posting.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Optional, Any

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]


class TelegramPoster:
    def __init__(self, config_path: Optional[str] = None):
        if config_path is None:
            config_path = str(SCRIPT_DIR / "config.json")
        with open(config_path, "r", encoding="utf-8") as f:
            self.config = json.load(f)

        self.token = self._resolve_token()
        self.api_base = f"https://api.telegram.org/bot{self.token}" if self.token else None

    def _resolve_token(self) -> Optional[str]:
        env_var = self.config.get("telegram", {}).get("bot_token_env", "TELEGRAM_TRIAGE_BOT_TOKEN")
        token = os.environ.get(env_var)
        if token:
            return token.strip()

        token_file = self.config.get("telegram", {}).get("bot_token_file")
        if token_file:
            path = Path(os.path.expanduser(token_file))
            if path.exists():
                return path.read_text(encoding="utf-8").strip()

        return None

    def is_bot_configured(self) -> bool:
        return bool(self.token)

    @staticmethod
    def sanitize_telegram_markdown(text: str) -> str:
        """
        Ensures any bare *.zip, *.tar, or *.apk filenames are enclosed in backticks
        so Telegram does not erroneously convert them to web hyperlinks (.zip is a valid TLD).
        """
        # Match words ending in .zip, .apk, .tar.gz, .img that aren't already wrapped in `
        pattern = r"(?<!`)\b([a-zA-Z0-9_\-\.]+\.(?:zip|apk|img|tar|tar\.gz))\b(?!`)"
        return re.sub(pattern, r"`\1`", text)

    def post_via_bot(
        self,
        chat_identifier: str,
        text: str,
        reply_to_message_id: Optional[int] = None,
        parse_mode: str = "Markdown"
    ) -> Dict[str, Any]:
        """
        Posts message via standard Telegram Bot API.
        """
        if not self.is_bot_configured():
            return {
                "success": False,
                "error": "Telegram bot token not configured. Set TELEGRAM_TRIAGE_BOT_TOKEN or ~/.telegram_triage_bot_token"
            }

        # Normalize chat_id (prepend @ if username)
        chat_id = chat_identifier
        if not chat_id.startswith("@") and not chat_id.startswith("-") and not chat_id.isdigit():
            chat_id = f"@{chat_id}"

        url = f"{self.api_base}/sendMessage"
        payload = {
            "chat_id": chat_id,
            "text": text,
            "parse_mode": parse_mode,
            "disable_web_page_preview": True
        }
        if reply_to_message_id:
            payload["reply_parameters"] = {"message_id": int(reply_to_message_id)}

        data_bytes = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data_bytes,
            headers={"Content-Type": "application/json", "User-Agent": "ExpressiveOS-Triage/1.0"}
        )

        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                res_data = json.loads(resp.read().decode("utf-8"))
            if res_data.get("ok"):
                return {
                    "success": True,
                    "method": "bot_api",
                    "message_id": res_data.get("result", {}).get("message_id"),
                    "chat": chat_id
                }
            return {
                "success": False,
                "error": res_data.get("description", "Unknown Bot API error")
            }
        except Exception as e:
            return {"success": False, "error": f"HTTP error sending to Telegram: {e}"}

    def post_via_desktop_bridge(
        self,
        chat_identifier: str,
        text: str,
        dry_run: bool = False
    ) -> Dict[str, Any]:
        """
        Uses macOS open command and AppleScript clipboard automation to dispatch to Telegram desktop.
        """
        clean_chat = chat_identifier.lstrip("@")
        if dry_run:
            print(f"[TelegramPoster DRY-RUN] Would post to @{clean_chat}:")
            print("-" * 40)
            print(text)
            print("-" * 40)
            return {"success": True, "dry_run": True, "chat": f"@{clean_chat}"}

        # Use pbcopy to put formatted text on macOS pasteboard
        try:
            copy_proc = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
            copy_proc.communicate(text.encode("utf-8"))

            # Open chat deep link and simulate paste + Enter
            apple_script = f"""
            tell application "Telegram" to activate
            open location "tg://resolve?domain={clean_chat}"
            delay 1.5
            tell application "System Events"
                tell process "Telegram"
                    keystroke "v" using command down
                    delay 0.5
                    keystroke return
                end tell
            end tell
            """
            subprocess.run(["osascript", "-e", apple_script], check=True, timeout=10)
            return {"success": True, "method": "desktop_bridge", "chat": f"@{clean_chat}"}
        except Exception as e:
            return {"success": False, "error": f"Failed to post via Telegram Desktop: {e}"}

    def acknowledge_issue(
        self,
        author: str,
        device: str,
        issue_id: str,
        user_text: str,
        category: str,
        status: str,
        message_id: Optional[int] = None,
        chat_identifier: str = "ExpressiveLauncherFeedback",
        dry_run: bool = False
    ) -> Dict[str, Any]:
        """
        Formats and submits an issue acknowledgment reply to Telegram.
        """
        quote_author = f"@{author}" if not author.startswith("@") else author
        clean_user_text = user_text.strip().replace("\n", " ")
        if len(clean_user_text) > 120:
            clean_user_text = clean_user_text[:120] + "..."

        quote_block = f"> {quote_author}: \"{clean_user_text}\"\n\n"

        if category == "Bug" and status == "NEEDS_LOGS":
            body = (
                f"**[{issue_id}] Acknowledged**\n"
                f"Thanks for the report on **{device}**! To help us trace this down, could you capture a logcat right after it happens?\n\n"
                f"`su -c \"logcat -b all -d > /sdcard/log_{issue_id}.txt\"`\n\n"
                f"Attach the log file here or send via DM so we can analyze the stack trace. Thank you!"
            )
        elif category == "Feature":
            body = (
                f"**[{issue_id}] Logged**\n"
                f"Good suggestion for **{device}**! We have logged this in the community backlog for evaluation in upcoming development builds."
            )
        elif category == "Support" and "waiting for any device" in user_text.lower():
            body = (
                f"**[{issue_id}] Acknowledged**\n"
                f"If fastboot hangs on `< waiting for any device >`, your phone is currently booted into Android OS rather than bootloader mode.\n\n"
                f"1. Run: `adb reboot bootloader`\n"
                f"2. Confirm with `fastboot devices`\n"
                f"3. Run your flash command again."
            )
        else:
            body = (
                f"**[{issue_id}] Acknowledged**\n"
                f"Thanks for the feedback on **{device}**, {quote_author}! This has been triaged for the upcoming build cycle."
            )

        full_message = self.sanitize_telegram_markdown(quote_block + body)

        if dry_run:
            print(f"[TelegramPoster DRY-RUN] Would post to @{chat_identifier.lstrip('@')}:")
            print("-" * 40)
            print(full_message)
            print("-" * 40)
            return {"success": True, "dry_run": True, "chat": chat_identifier}

        # Try Bot API first if configured
        if self.is_bot_configured():
            res = self.post_via_bot(chat_identifier, full_message, reply_to_message_id=message_id)
            if res.get("success"):
                return res

        # Fallback to desktop bridge
        return self.post_via_desktop_bridge(chat_identifier, full_message, dry_run=dry_run)

    def post_release_announcement(
        self,
        chat_identifier: str,
        announcement_text: str,
        dry_run: bool = False
    ) -> Dict[str, Any]:
        """
        Posts release announcement to Telegram.
        """
        sanitized = self.sanitize_telegram_markdown(announcement_text)
        if dry_run:
            print(f"[TelegramPoster DRY-RUN] Would post release notes to @{chat_identifier.lstrip('@')}:")
            print("-" * 40)
            print(sanitized)
            print("-" * 40)
            return {"success": True, "dry_run": True, "chat": chat_identifier}

        if self.is_bot_configured():
            res = self.post_via_bot(chat_identifier, sanitized)
            if res.get("success"):
                return res

        return self.post_via_desktop_bridge(chat_identifier, sanitized, dry_run=dry_run)


def main():
    parser = argparse.ArgumentParser(description="Telegram Posting and Issue Acknowledgment")
    parser.add_argument("--chat", default="ExpressiveLauncherFeedback", help="Target chat username or ID")
    parser.add_argument("--device", default="kodiak", help="Target device")
    parser.add_argument("--issue-id", help="Issue tracker ID (e.g. ISS-20261016-02)")
    parser.add_argument("--author", default="User", help="Author of user report")
    parser.add_argument("--text", help="Message or quote text")
    parser.add_argument("--reply-to", type=int, default=None, help="Telegram message ID to reply to")
    parser.add_argument("--category", default="General", help="Issue category")
    parser.add_argument("--status", default="TRIAGED", help="Issue status")
    parser.add_argument("--file", help="Path to markdown file to post")
    parser.add_argument("--announcement", action="store_true", help="Post as general announcement without quoting")
    parser.add_argument("--dry-run", action="store_true", help="Preview message without sending")
    args = parser.parse_args()

    poster = TelegramPoster()

    if args.announcement:
        content = args.text
        if args.file:
            content = Path(args.file).read_text(encoding="utf-8")
        if not content:
            parser.error("Must provide --text or --file for announcement")
        res = poster.post_release_announcement(args.chat, content, dry_run=args.dry_run)
        print(json.dumps(res, indent=2))
        return

    if args.issue_id and args.text:
        res = poster.acknowledge_issue(
            author=args.author,
            device=args.device,
            issue_id=args.issue_id,
            user_text=args.text,
            category=args.category,
            status=args.status,
            message_id=args.reply_to,
            chat_identifier=args.chat,
            dry_run=args.dry_run
        )
        print(json.dumps(res, indent=2))
        return

    parser.error("Must provide either (--announcement and --text/--file) or (--issue-id and --text)")


if __name__ == "__main__":
    main()
