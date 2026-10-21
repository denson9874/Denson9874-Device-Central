#!/usr/bin/env python3
"""
Telegram Ingestion Reader for ExpressiveOS / Evolution X.
Fetches updates from @ExpressiveLauncherFeedback and @ExpressiveGroup using Telegram Bot API.
Uses only standard library (urllib.request, json, os, sys) to ensure portability.
"""

import json
import os
import re
import subprocess
import sys
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Any


class TelegramReader:
    def __init__(self, config_path: Optional[str] = None, token: Optional[str] = None):
        if config_path is None:
            config_path = str(Path(__file__).parent / "config.json")
        with open(config_path, "r", encoding="utf-8") as f:
            self.config = json.load(f)

        self.token = token or self._resolve_token()
        self.api_base = f"https://api.telegram.org/bot{self.token}" if self.token else None

    def _resolve_token(self) -> Optional[str]:
        # 1. Environment variable
        env_var = self.config.get("telegram", {}).get("bot_token_env", "TELEGRAM_TRIAGE_BOT_TOKEN")
        token = os.environ.get(env_var)
        if token:
            return token.strip()

        # 2. Token file
        token_file = self.config.get("telegram", {}).get("bot_token_file")
        if token_file:
            path = Path(os.path.expanduser(token_file))
            if path.exists():
                return path.read_text(encoding="utf-8").strip()

        return None

    def is_configured(self) -> bool:
        return bool(self.token)

    @staticmethod
    def is_desktop_available() -> bool:
        if sys.platform != "darwin":
            return False
        try:
            res = subprocess.run(
                ["osascript", "-e", 'tell application "System Events" to (name of processes) contains "Telegram"'],
                capture_output=True, text=True, timeout=3
            )
            return res.returncode == 0 and "true" in res.stdout.lower()
        except Exception:
            return False

    def fetch_desktop_updates(
        self,
        offset: Optional[int] = None
    ) -> Tuple[List[Dict[str, Any]], Optional[int]]:
        """
        Ingests user messages from open Telegram Desktop application via AppleScript.
        """
        if not self.is_desktop_available():
            return [], offset

        script = '''
        tell application "System Events"
            tell process "Telegram"
                if (name of front window) does not contain "Expressive Group Feedback" then
                    try
                        set chatList to UI elements of list "Chats" of front window
                        repeat with c in chatList
                            if title of c contains "Expressive Group Feedback" then
                                click c
                                delay 0.5
                                exit repeat
                            end if
                        end repeat
                    end try
                end if
                set titleList to (title of every UI element of list "Messages" of front window)
                set AppleScript's text item delimiters to ("---TG_DELIM---" & linefeed)
                return titleList as text
            end tell
        end tell
        '''
        try:
            res = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=10)
        except Exception as e:
            sys.stderr.write(f"[TelegramReader] Failed to query Telegram desktop: {e}\n")
            return [], offset

        if res.returncode != 0 or not res.stdout.strip():
            return [], offset

        raw_items = res.stdout.split("---TG_DELIM---\n")
        parsed_messages = []
        max_id = offset or 0

        for idx, raw in enumerate(raw_items):
            raw = raw.strip()
            if not raw:
                continue
            if raw.startswith("Seen\nMe") or raw.startswith("Me\n"):
                continue
            if "joined the group" in raw or "pinned a message" in raw:
                continue

            lines = raw.split("\n")
            author = lines[0].strip()
            if author.lower() in ["me", "seen", "expressive group", "daryl"]:
                continue

            time_str = lines[-1].strip() if "Received" in lines[-1] else ""
            content_lines = lines[1:-1] if time_str else lines[1:]

            cleaned_lines = []
            reply_to = None
            for l in content_lines:
                if l.startswith("In reply to "):
                    reply_to = l
                    continue
                if l.startswith("Reactions:") or re.match(r"Photo,\s*\d+×\d+", l) or l == "Pinned":
                    continue
                cleaned_lines.append(l)

            text = "\n".join(cleaned_lines).strip()
            if not text:
                continue

            msg_id = 2000 + idx
            if offset is not None and msg_id <= offset:
                continue

            if msg_id > max_id:
                max_id = msg_id

            parsed_messages.append({
                "source": "telegram",
                "chat_name": "Expressive Group Feedback",
                "chat_id": None,
                "message_id": msg_id,
                "update_id": msg_id,
                "author": author,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "text": text,
                "reply_to": {"text": reply_to} if reply_to else None,
                "attachments": []
            })

        return parsed_messages, max_id + 1

    def fetch_updates(
        self,
        offset: Optional[int] = None,
        limit: int = 100,
        download_attachments: bool = True,
        attachments_dir: Optional[str] = None
    ) -> Tuple[List[Dict[str, Any]], Optional[int]]:
        """
        Fetches new updates from the Telegram Bot API.
        Returns: (parsed_messages, max_update_id)
        """
        if not self.is_configured():
            sys.stderr.write(
                "[TelegramReader] Bot token not found. Set TELEGRAM_TRIAGE_BOT_TOKEN "
                "or create ~/.telegram_triage_bot_token.\n"
            )
            return [], offset

        url = f"{self.api_base}/getUpdates?limit={limit}"
        if offset is not None:
            url += f"&offset={offset}"

        req = urllib.request.Request(
            url,
            headers={"User-Agent": "ExpressiveOS-Triage/1.0"}
        )

        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        except Exception as e:
            sys.stderr.write(f"[TelegramReader] API request failed: {e}\n")
            return [], offset

        if not data.get("ok"):
            sys.stderr.write(f"[TelegramReader] API returned error: {data.get('description')}\n")
            return [], offset

        results = data.get("result", [])
        if not results:
            return [], offset

        parsed_messages = []
        max_update_id = offset or 0

        target_identifiers = {
            g["chat_identifier"].lower()
            for g in self.config.get("telegram", {}).get("groups", [])
            if g.get("chat_identifier")
        }

        for update in results:
            update_id = update.get("update_id", 0)
            if update_id > max_update_id:
                max_update_id = update_id

            msg = update.get("message") or update.get("channel_post")
            if not msg:
                continue

            chat = msg.get("chat", {})
            chat_username = (chat.get("username") or "").lower()
            chat_title = chat.get("title") or ""
            chat_id = chat.get("id")

            # Check if chat matches target groups
            is_target = False
            if chat_username and chat_username in target_identifiers:
                is_target = True
            elif any(t in chat_title.lower() for t in ["expressive", "feedback", "evolution"]):
                is_target = True
            elif not target_identifiers:
                is_target = True

            if not is_target:
                continue

            author = msg.get("from", {})
            author_name = author.get("username") or f"{author.get('first_name', '')} {author.get('last_name', '')}".strip() or "Anonymous"

            timestamp_unix = msg.get("date", 0)
            iso_time = datetime.fromtimestamp(timestamp_unix, tz=timezone.utc).isoformat()

            text = msg.get("text") or msg.get("caption") or ""
            reply_to = msg.get("reply_to_message", {})
            reply_text = reply_to.get("text") or ""
            reply_author = (reply_to.get("from") or {}).get("username") or ""

            attachments = []
            if "document" in msg:
                doc = msg["document"]
                doc_info = {
                    "file_id": doc.get("file_id"),
                    "file_name": doc.get("file_name", "unknown_document"),
                    "mime_type": doc.get("mime_type", ""),
                    "file_size": doc.get("file_size", 0)
                }
                if download_attachments and attachments_dir and self.token:
                    saved_path = self._download_file(doc["file_id"], doc_info["file_name"], attachments_dir)
                    if saved_path:
                        doc_info["local_path"] = saved_path
                attachments.append(doc_info)

            parsed_messages.append({
                "source": "telegram",
                "chat_name": chat_title or chat_username or str(chat_id),
                "chat_id": chat_id,
                "message_id": msg.get("message_id"),
                "update_id": update_id,
                "author": author_name,
                "timestamp": iso_time,
                "text": text,
                "reply_to": {
                    "author": reply_author,
                    "text": reply_text[:200]
                } if reply_text else None,
                "attachments": attachments
            })

        return parsed_messages, max_update_id + 1

    def _download_file(self, file_id: str, file_name: str, dest_dir: str) -> Optional[str]:
        try:
            info_url = f"{self.api_base}/getFile?file_id={file_id}"
            req = urllib.request.Request(info_url, headers={"User-Agent": "ExpressiveOS-Triage/1.0"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            if not data.get("ok"):
                return None

            file_path = data["result"]["file_path"]
            download_url = f"https://api.telegram.org/file/bot{self.token}/{file_path}"

            out_dir = Path(dest_dir)
            out_dir.mkdir(parents=True, exist_ok=True)
            target = out_dir / file_name

            urllib.request.urlretrieve(download_url, str(target))
            return str(target)
        except Exception as e:
            sys.stderr.write(f"[TelegramReader] Failed to download {file_name}: {e}\n")
            return None


if __name__ == "__main__":
    reader = TelegramReader()
    if not reader.is_configured():
        print("TelegramReader: Bot token not configured. (Use TELEGRAM_TRIAGE_BOT_TOKEN)")
        sys.exit(0)

    print("TelegramReader: Querying bot updates...")
    msgs, next_offset = reader.fetch_updates(download_attachments=False)
    print(f"Fetched {len(msgs)} messages. Next offset: {next_offset}")
    for m in msgs[:5]:
        print(f"[{m['timestamp']}] {m['author']}: {m['text'][:100]}")
