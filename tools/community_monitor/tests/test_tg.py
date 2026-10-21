#!/usr/bin/env python3
"""
Unit tests for TelegramReader.
"""

import json
import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock
import sys

script_dir = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(script_dir))

from tg_reader import TelegramReader


class TestTelegramReader(unittest.TestCase):
    def setUp(self):
        self.reader = TelegramReader(token="MOCK_BOT_TOKEN_123456")

    def test_configured_state(self):
        self.assertTrue(self.reader.is_configured())
        unconfigured = TelegramReader(token=None)
        unconfigured.token = None
        self.assertFalse(unconfigured.is_configured())

    @patch("urllib.request.urlopen")
    def test_fetch_updates_parsing(self, mock_urlopen):
        mock_response = MagicMock()
        mock_response.read.return_value = json.dumps({
            "ok": True,
            "result": [
                {
                    "update_id": 5001,
                    "message": {
                        "message_id": 101,
                        "date": 1760630400,
                        "chat": {
                            "id": -1001234567,
                            "title": "Expressive Group Feedback",
                            "username": "ExpressiveLauncherFeedback"
                        },
                        "from": {
                            "id": 999,
                            "username": "TestUser",
                            "first_name": "Test"
                        },
                        "text": "Wi-Fi calling works, but battery style resets after reboot.",
                        "document": {
                            "file_id": "doc_abc123",
                            "file_name": "logcat.txt",
                            "mime_type": "text/plain",
                            "file_size": 2048
                        }
                    }
                }
            ]
        }).encode("utf-8")
        mock_urlopen.return_value.__enter__.return_value = mock_response

        msgs, next_offset = self.reader.fetch_updates(offset=5000, download_attachments=False)
        self.assertEqual(len(msgs), 1)
        self.assertEqual(next_offset, 5002)

        m = msgs[0]
        self.assertEqual(m["source"], "telegram")
        self.assertEqual(m["author"], "TestUser")
        self.assertEqual(m["message_id"], 101)
        self.assertIn("battery style resets", m["text"])
        self.assertEqual(len(m["attachments"]), 1)
        self.assertEqual(m["attachments"][0]["file_name"], "logcat.txt")

    @patch.object(TelegramReader, "is_desktop_available", return_value=True)
    @patch("subprocess.run")
    def test_desktop_new_message_after_seen_is_kept(self, mock_run, _avail):
        def ui(*titles):
            out = MagicMock(); out.returncode = 0
            out.stdout = ("---TG_DELIM---\n").join(titles)
            return out
        first = ["Alice\nWi-Fi drops on kodiak\nReceived 10:01", "Bob\nThanks for the build\nReceived 10:05"]
        mock_run.return_value = ui(*first)
        msgs, seen = self.reader.fetch_desktop_updates(seen=[])
        self.assertEqual([m["author"] for m in msgs], ["Alice", "Bob"])

        # Next poll: one message scrolled off the top, a new one appended where the old index scheme
        # would have given it the saved offset
        mock_run.return_value = ui(first[1], "Carol\nCamera crashes on husky\nReceived 11:20")
        msgs2, seen2 = self.reader.fetch_desktop_updates(seen=seen)
        self.assertEqual([m["author"] for m in msgs2], ["Carol"])
        self.assertEqual(len(set(seen2)), 3)
        # Same message, same id, wherever it appears in the list
        self.assertEqual(TelegramReader.desktop_message_key("Bob", "Thanks for the build", "Received 10:05"),
                         seen[1])


if __name__ == "__main__":
    unittest.main()
