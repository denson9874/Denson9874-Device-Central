#!/usr/bin/env python3
"""
Unit tests for evolution-kodiak/tools/community_release_notes.py (the Sunday changelog's community items).
"""

import tempfile
import unittest
from pathlib import Path
import sys

TOOLS_DIR = Path(__file__).resolve().parents[3] / "evolution-kodiak" / "tools"
sys.path.insert(0, str(TOOLS_DIR))

from community_release_notes import release_items, mark_released

BACKLOG = """# Backlog

| Issue ID | Date Logged | Source & Reporter | Device | Category | Severity | Status | Summary & Technical Details | Target Release |
|:---|:---|:---|:---|:---|:---|:---|:---|:---|
| `ISS-1` | 2026-10-12 | TG: A | `kodiak` | Bug | Medium | `RESOLVED` | AOD flash | 2026-10-18 |
| `ISS-2` | 2026-10-12 | TG: A | `kodiak` | Support | Low | `RESOLVED` | PIN prompt twice | 2026-10-18 |
| `ISS-3` | 2026-10-13 | TG: A | `kodiak` | Bug / Mod | Low | `RESOLVED` | Morphe ENOENT | Documented workaround |
| `ISS-4` | 2026-10-15 | XDA: B | `kodiak` | Bug | Low | `TRIAGED` | Recents previews | Upstream |
| `ISS-5` | 2026-10-16 | Report | All P11 | Bug | Critical | `VERIFIED` | Use device MAC | 2026-10-18 |
| `ISS-6` | 2026-10-16 | Report | All | Bug | Low | `VERIFIED` | Everyone | 2026-10-18 |
| `ISS-7` | 2026-10-16 | XDA: C | `husky` | Feature | Low | `VERIFIED` | 5G tile | 2026-10-18 |
| `ISS-8` | 2026-10-16 | XDA: D | `kodiak` | Bug | Low | `VERIFIED` | stray | pipe | 2026-10-18 |
"""


class TestCommunityReleaseNotes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.triage = Path(self.tmp.name) / "COMMUNITY_TRIAGE.md"
        self.triage.write_text(BACKLOG, encoding="utf-8")

    def ids(self, device):
        return [i["id"] for i in release_items(self.triage, device)]

    def test_release_items_skip_support_answers_and_undated_rows(self):
        self.assertEqual(self.ids("kodiak"), ["ISS-1", "ISS-5", "ISS-6"])

    def test_all_p11_is_not_husky(self):
        self.assertEqual(self.ids("husky"), ["ISS-6", "ISS-7"])
        self.assertEqual(self.ids("cubs"), ["ISS-5", "ISS-6"])

    def test_multi_device_rows_wait_for_every_device(self):
        self.assertEqual(mark_released(self.triage, ["kodiak"], "test"), ["ISS-1"])
        self.assertEqual(self.ids("grizzly"), ["ISS-5", "ISS-6"])
        self.assertEqual(mark_released(self.triage, ["kodiak", "grizzly", "cubs", "yogi"]), ["ISS-5"])
        self.assertEqual(self.ids("grizzly"), ["ISS-6"])
        text = self.triage.read_text(encoding="utf-8")
        self.assertIn("| `ISS-1` | 2026-10-12 | TG: A | `kodiak` | Bug | Medium | `RELEASED` | AOD flash |", text)
        self.assertIn("(test) |", text)
        # Closed support rows and the malformed row are left as they were
        self.assertIn("| `ISS-2` | 2026-10-12 | TG: A | `kodiak` | Support | Low | `RESOLVED` |", text)
        self.assertIn("| stray | pipe |", text)

    def test_missing_triage_file(self):
        self.assertEqual(release_items(Path(self.tmp.name) / "none.md", "kodiak"), [])
        self.assertEqual(mark_released(Path(self.tmp.name) / "none.md", ["kodiak"]), [])


if __name__ == "__main__":
    unittest.main()
