#!/usr/bin/env python3
"""
Unit tests for XDAReader.
"""

import unittest
from pathlib import Path
import sys

script_dir = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(script_dir))

from xda_reader import XDAReader


class TestXDAReader(unittest.TestCase):
    def setUp(self):
        self.reader = XDAReader()

    def test_threads_configuration(self):
        self.assertEqual(len(self.reader.threads), 4)
        thread_ids = {t["id"] for t in self.reader.threads}
        self.assertIn("4804712", thread_ids)  # kodiak/grizzly
        self.assertIn("4804723", thread_ids)  # cubs
        self.assertIn("4804826", thread_ids)  # yogi
        self.assertIn("4805239", thread_ids)  # husky

    def test_thread_device_mapping(self):
        mapping = {t["id"]: t["device"] for t in self.reader.threads}
        self.assertEqual(mapping["4804712"], "kodiak")
        self.assertEqual(mapping["4804723"], "cubs")
        self.assertEqual(mapping["4804826"], "yogi")
        self.assertEqual(mapping["4805239"], "husky")


if __name__ == "__main__":
    unittest.main()
