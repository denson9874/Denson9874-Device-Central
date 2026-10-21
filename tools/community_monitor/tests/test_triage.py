#!/usr/bin/env python3
"""
Unit tests for TriageProcessor.
"""

import tempfile
import unittest
from pathlib import Path
import sys

# Add tools/community_monitor to path
script_dir = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(script_dir))

from triage_processor import TriageProcessor


class TestTriageProcessor(unittest.TestCase):
    def setUp(self):
        self.processor = TriageProcessor()

    def test_noise_filtering(self):
        self.assertTrue(self.processor.is_noise("Thanks!"))
        self.assertTrue(self.processor.is_noise("great build, downloaded"))
        self.assertTrue(self.processor.is_noise("+1"))
        self.assertFalse(self.processor.is_noise("The screen flashes bright when timing out into AOD on my Pixel 11 Pro XL."))

    def test_device_detection(self):
        self.assertEqual(self.processor.detect_device({"device": "cubs"}), "cubs")
        self.assertEqual(self.processor.detect_device({"text": "Inner screen on yogi is freezing"}), "yogi")
        self.assertEqual(self.processor.detect_device({"text": "Pixel 8 Pro keeps disconnecting"}), "husky")
        self.assertEqual(self.processor.detect_device({"text": "Pixel 11 Pro XL AOD glitch"}), "kodiak")
        self.assertEqual(self.processor.detect_device({"text": "Wi-Fi MAC randomization is missing"}), "all")

    def test_classification(self):
        bug_item = {
            "source": "xda",
            "author": "Tester",
            "text": "The phone keeps crashing on bootloop when Magisk module is enabled",
            "attachments": []
        }
        res = self.processor.classify_item(bug_item)
        self.assertEqual(res["category"], "Bug")
        self.assertEqual(res["severity"], "Critical")
        self.assertEqual(res["status"], "NEEDS_LOGS")

        feature_item = {
            "source": "telegram",
            "author": "User1",
            "text": "Can you add a Quick Settings tile for Extreme Charging mode?",
            "attachments": []
        }
        res_feat = self.processor.classify_item(feature_item)
        self.assertEqual(res_feat["category"], "Feature")
        self.assertEqual(res_feat["severity"], "High")
        self.assertEqual(res_feat["status"], "TRIAGED")

    def test_backlog_update(self):
        with tempfile.NamedTemporaryFile("w+", delete=False, suffix=".md") as tmp:
            tmp.write(
                "# Test Backlog\n\n"
                "## Active Community Backlog\n\n"
                "| Issue ID | Date Logged | Source & Reporter | Device | Category | Severity | Status | Summary & Technical Details | Target Release |\n"
                "|:---|:---|:---|:---|:---|:---|:---|:---|:---|\n"
                "| `ISS-20261016-01` | 2026-10-16 | Community Report | All P11 | Bug | Critical | `RELEASED` | MAC option missing | 2026-10-16 |\n\n"
                "---\n"
            )
            tmp_path = Path(tmp.name)

        try:
            custom_processor = TriageProcessor(triage_path=str(tmp_path))
            new_items = [
                {
                    "date": "2026-10-16",
                    "source": "telegram",
                    "author": "Ashray",
                    "device": "kodiak",
                    "category": "Bug",
                    "severity": "Medium",
                    "status": "TRIAGED",
                    "text": "Battery style resets on reboot."
                }
            ]
            added = custom_processor.update_backlog(new_items)
            self.assertEqual(added, 1)

            # Check content
            content = tmp_path.read_text()
            self.assertIn("ISS-20261016-02", content)
            self.assertIn("Battery style resets on reboot.", content)

            # Re-running with same item should not duplicate
            added_again = custom_processor.update_backlog(new_items)
            self.assertEqual(added_again, 0)
        finally:
            if tmp_path.exists():
                tmp_path.unlink()


if __name__ == "__main__":
    unittest.main()
