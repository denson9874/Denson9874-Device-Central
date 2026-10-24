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
        self.assertEqual(len(self.reader.threads), 6)
        thread_ids = {t["id"] for t in self.reader.threads}
        self.assertIn("4804712", thread_ids)  # kodiak/grizzly
        self.assertIn("4804723", thread_ids)  # cubs
        self.assertIn("4804826", thread_ids)  # yogi
        self.assertIn("4805239", thread_ids)  # husky
        self.assertIn("4805779", thread_ids)  # husky DerpFest
        self.assertIn("4806248", thread_ids)  # cheetah

    def test_thread_device_mapping(self):
        mapping = {t["id"]: t["device"] for t in self.reader.threads}
        self.assertEqual(mapping["4804712"], "kodiak")
        self.assertEqual(mapping["4804723"], "cubs")
        self.assertEqual(mapping["4804826"], "yogi")
        self.assertEqual(mapping["4805239"], "husky")

    def _pages(self, per_page, first_id, count):
        """Thread with `count` posts numbered from first_id, `per_page` to a page."""
        posts = [{"post_id": str(first_id + i), "author": f"u{i}", "timestamp": "t", "text": f"p{i}", "quotes": []}
                 for i in range(count)]
        pages = [posts[i:i + per_page] for i in range(0, count, per_page)]
        calls = []

        def fetch_page(n):
            calls.append(n)
            n = min(n, len(pages))
            return n, pages[n - 1]
        return fetch_page, calls

    def test_walks_back_over_every_unread_page(self):
        thread = self.reader.threads[0]
        fetch_page, calls = self._pages(per_page=20, first_id=1000, count=70)  # pages 1-4, last page 4
        posts, highest = self.reader._collect_new_posts(thread, fetch_page, last_post_id="1015")
        self.assertEqual([p["post_id"] for p in posts], [str(i) for i in range(1016, 1070)])
        self.assertEqual(highest, "1069")
        self.assertEqual(calls, [999, 3, 2, 1])

    def test_stops_at_the_page_holding_last_post(self):
        thread = self.reader.threads[0]
        fetch_page, calls = self._pages(per_page=20, first_id=1000, count=70)
        posts, highest = self.reader._collect_new_posts(thread, fetch_page, last_post_id="1065")
        self.assertEqual([p["post_id"] for p in posts], ["1066", "1067", "1068", "1069"])
        self.assertEqual(calls, [999])

    def test_first_run_reads_only_last_page(self):
        thread = self.reader.threads[0]
        fetch_page, calls = self._pages(per_page=20, first_id=1000, count=70)
        posts, highest = self.reader._collect_new_posts(thread, fetch_page, last_post_id=None)
        self.assertEqual(len(posts), 10)
        self.assertEqual(calls, [999])


if __name__ == "__main__":
    unittest.main()
