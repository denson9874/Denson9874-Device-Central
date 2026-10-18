#!/usr/bin/env python3
"""
Unit tests for XDAPoster and TelegramPoster.
"""

import unittest
from pathlib import Path
import sys

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from xda_poster import XDAPoster
from tg_poster import TelegramPoster


class TestPosters(unittest.TestCase):
    def setUp(self):
        self.xda_poster = XDAPoster()
        self.tg_poster = TelegramPoster()

    def test_xda_thread_lookup(self):
        tinfo = self.xda_poster.get_thread_info("kodiak")
        self.assertIsNotNone(tinfo)
        self.assertEqual(tinfo["id"], "4804712")

        tinfo_id = self.xda_poster.get_thread_info("4804826")
        self.assertIsNotNone(tinfo_id)
        self.assertEqual(tinfo_id["device"], "yogi")

    def test_xda_dry_run_acknowledgment(self):
        res = self.xda_poster.acknowledge_issue(
            thread_id="4804712",
            post_id="12345",
            author="TestUser",
            device="kodiak",
            issue_id="ISS-20261016-01",
            user_text="Camera fails when HDR is on",
            category="Bug",
            status="NEEDS_LOGS",
            dry_run=True
        )
        self.assertTrue(res.get("success"))
        self.assertTrue(res.get("dry_run"))

    def test_tg_sanitize_markdown(self):
        raw = "Download DerpFest-v17.zip and flash boot.img from the package."
        sanitized = TelegramPoster.sanitize_telegram_markdown(raw)
        self.assertIn("`DerpFest-v17.zip`", sanitized)
        self.assertIn("`boot.img`", sanitized)

        # Ensure already quoted file is not double-quoted
        raw2 = "Download `DerpFest-v17.zip` now."
        sanitized2 = TelegramPoster.sanitize_telegram_markdown(raw2)
        self.assertEqual(sanitized2, raw2)

    def test_tg_dry_run_acknowledgment(self):
        res = self.tg_poster.acknowledge_issue(
            author="Ashray",
            device="kodiak",
            issue_id="ISS-20261016-02",
            user_text="Charging speed drops after 80%",
            category="Bug",
            status="TRIAGED",
            message_id=999,
            chat_identifier="ExpressiveLauncherFeedback",
            dry_run=True
        )
        self.assertTrue(res.get("success"))
        self.assertTrue(res.get("dry_run"))

    def test_telegram_reply_target(self):
        from run_daily_review import telegram_chat_target
        config = {"telegram": {"groups": [
            {"name": "Expressive Group Feedback", "chat_identifier": "ExpressiveLauncherFeedback"}]}}
        self.assertEqual(telegram_chat_target({"chat_name": "Expressive Group Feedback", "chat_id": None}, config),
                         "ExpressiveLauncherFeedback")
        self.assertEqual(telegram_chat_target({"chat_name": "Whatever", "chat_id": -1001234}, config), "-1001234")


if __name__ == "__main__":
    unittest.main()
