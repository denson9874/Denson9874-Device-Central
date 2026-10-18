#!/usr/bin/env python3
"""
Unit tests for ReleasePublisher.
"""

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import sys

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from release_publisher import ReleasePublisher


class TestReleasePublisher(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.publisher = ReleasePublisher(out_dir=self.tmp.name)

    def test_format_xda_announcement(self):
        artifacts = {
            "ota_file": "DerpFest-v17-kodiak.zip",
            "ota_size_mb": 3200,
            "ota_sha256": "abc12345",
            "fastboot_file": "DerpFest-v17-kodiak-fastboot.zip",
            "fastboot_size_mb": 5100,
            "fastboot_sha256": "def67890"
        }
        fixes = [
            {"id": "ISS-20261016-01", "reporter": "TG: Ashray", "category": "Bug", "summary": "Fix AOD flicker"}
        ]
        bbcode = self.publisher.format_xda_announcement(
            rom="DerpFest",
            device="kodiak",
            version="v17",
            artifacts=artifacts,
            community_fixes=fixes
        )
        self.assertIn("DerpFest v17", bbcode)
        self.assertIn("Google Pixel 11 Pro XL", bbcode)
        self.assertIn("ISS-20261016-01", bbcode)
        self.assertIn("Kevtrejo37", bbcode)
        self.assertIn("Espada Kernel", bbcode)

    def test_format_telegram_announcement(self):
        artifacts = {
            "ota_file": "DerpFest-v17-kodiak.zip",
            "ota_size_mb": 3200,
            "ota_sha256": "abc12345",
            "fastboot_file": "DerpFest-v17-kodiak-fastboot.zip",
            "fastboot_size_mb": 5100,
            "fastboot_sha256": "def67890"
        }
        fixes = [
            {"id": "ISS-20261016-01", "reporter": "TG: Ashray", "category": "Bug", "summary": "Fix AOD flicker"}
        ]
        md = self.publisher.format_telegram_announcement(
            rom="DerpFest",
            device="kodiak",
            version="v17",
            artifacts=artifacts,
            community_fixes=fixes
        )
        self.assertIn("🚀 **New Update Released: DerpFest v17**", md)
        self.assertIn("`DerpFest-v17-kodiak.zip`", md)
        self.assertIn("`DerpFest-v17-kodiak-fastboot.zip`", md)
        self.assertIn("Kevtrejo37", md)

    def test_dry_run_publish(self):
        res = self.publisher.publish_release(
            rom="DerpFest",
            device="kodiak",
            version="v17",
            dry_run=True
        )
        self.assertTrue(res.get("xda", {}).get("dry_run"))
        self.assertTrue(res.get("telegram", {}).get("dry_run"))
        self.assertTrue(Path(res.get("draft_file")).exists())
        self.assertEqual(Path(res.get("draft_file")).parent, Path(self.tmp.name))

    def test_live_publish_refused_without_build_zips(self):
        missing = {"complete": False, "ota_file": "NOT FOUND", "ota_size_mb": "?", "ota_sha256": "NOT FOUND",
                   "fastboot_file": "NOT FOUND", "fastboot_size_mb": "?", "fastboot_sha256": "NOT FOUND"}
        with patch.object(self.publisher, "inspect_build_artifacts", return_value=missing), \
             patch.object(self.publisher.xda_poster, "post_release_announcement") as xda, \
             patch.object(self.publisher.tg_poster, "post_release_announcement") as tg, \
             patch.object(self.publisher, "mark_items_released") as mark:
            res = self.publisher.publish_release(rom="DerpFest", device="kodiak", dry_run=False)
        xda.assert_not_called()
        tg.assert_not_called()
        mark.assert_not_called()
        self.assertFalse(res["xda"]["success"])
        self.assertFalse(res["telegram"]["success"])


if __name__ == "__main__":
    unittest.main()
