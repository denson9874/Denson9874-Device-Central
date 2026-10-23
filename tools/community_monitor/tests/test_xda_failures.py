#!/usr/bin/env python3
"""
Unit tests for XDAReader's handling of threads it can't read: a failed or empty page must not move a
thread's state past unread posts, and every such thread is reported in thread_warnings.
"""

import contextlib
import io
import json
import unittest
from pathlib import Path
from unittest import mock
import sys

script_dir = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(script_dir))

import xda_reader
from xda_reader import XDAReader, ThreadReadError


def make_pages(per_page, first_id, count):
    posts = [{"post_id": str(first_id + i), "author": f"u{i}", "timestamp": "t", "text": f"p{i}", "quotes": []}
             for i in range(count)]
    return [posts[i:i + per_page] for i in range(0, count, per_page)]


class TestXDAReadFailures(unittest.TestCase):
    def setUp(self):
        self.reader = XDAReader()
        self.thread = self.reader.threads[0]

    def fetcher(self, pages, broken=None, empty=None, reason=None):
        """fetch_page over `pages`; page numbers in `broken` fail (None), in `empty` load with no posts."""
        calls = []

        def fetch_page(n):
            calls.append(n)
            n = min(n, len(pages))
            if broken and n in broken:
                self.reader._fetch_error = reason
                return n, None
            if empty and n in empty:
                return n, []
            return n, pages[n - 1]
        return fetch_page, calls

    def test_empty_last_page_is_a_failure_not_no_new_posts(self):
        fetch_page, _ = self.fetcher(make_pages(20, 1000, 70), empty={4})
        with self.assertRaises(ThreadReadError) as cm:
            self.reader._collect_new_posts(self.thread, fetch_page, last_post_id="1065")
        self.assertIn("no posts on the page", str(cm.exception))

    def test_failed_page_reports_the_fetcher_reason(self):
        fetch_page, _ = self.fetcher(make_pages(20, 1000, 70), broken={4}, reason="Chrome Canary timed out after 20 s")
        with self.assertRaises(ThreadReadError) as cm:
            self.reader._collect_new_posts(self.thread, fetch_page, last_post_id="1065")
        self.assertIn("last page: Chrome Canary timed out after 20 s", str(cm.exception))

    def test_failed_older_page_doesnt_return_the_newer_pages(self):
        # Before: page 3 failing returned page 4's posts and moved state to 1069, so 1016-1059 were never read
        fetch_page, calls = self.fetcher(make_pages(20, 1000, 70), broken={3}, reason="boom")
        with self.assertRaises(ThreadReadError) as cm:
            self.reader._collect_new_posts(self.thread, fetch_page, last_post_id="1015")
        self.assertIn("page 3", str(cm.exception))
        self.assertEqual(calls, [999, 3])

    def test_fetch_thread_posts_keeps_state_and_warns_on_failure(self):
        pages = make_pages(20, 1000, 70)
        fetch_page, _ = self.fetcher(pages, broken={2}, reason="boom")
        chrome = lambda t, last: self.reader._collect_new_posts(t, fetch_page, last)
        with mock.patch.object(XDAReader, "is_chrome_available", return_value=True), \
                mock.patch.object(self.reader, "fetch_thread_posts_chrome", side_effect=chrome), \
                mock.patch.object(xda_reader, "PLAYWRIGHT_AVAILABLE", False):
            posts, highest = self.reader.fetch_thread_posts(self.thread, last_post_id="1015")
        self.assertEqual((posts, highest), ([], "1015"))
        self.assertEqual(len(self.reader.thread_warnings), 1)
        w = self.reader.thread_warnings[0]
        self.assertEqual((w["thread_id"], w["kind"]), (self.thread["id"], "failed"))
        self.assertIn("page 2: boom", w["reason"])

    def test_chrome_failure_falls_back_to_playwright(self):
        good = ([{"post_id": "1066"}], "1066")
        with mock.patch.object(XDAReader, "is_chrome_available", return_value=True), \
                mock.patch.object(self.reader, "fetch_thread_posts_chrome", side_effect=ThreadReadError("last page: x")), \
                mock.patch.object(xda_reader, "PLAYWRIGHT_AVAILABLE", True), \
                mock.patch.object(self.reader, "fetch_thread_posts_playwright", return_value=good):
            self.assertEqual(self.reader.fetch_thread_posts(self.thread, last_post_id="1065"), good)
        self.assertEqual(self.reader.thread_warnings, [])

    def test_both_engines_failing_lists_both_reasons(self):
        with mock.patch.object(XDAReader, "is_chrome_available", return_value=True), \
                mock.patch.object(self.reader, "fetch_thread_posts_chrome", side_effect=ThreadReadError("last page: a")), \
                mock.patch.object(xda_reader, "PLAYWRIGHT_AVAILABLE", True), \
                mock.patch.object(self.reader, "fetch_thread_posts_playwright", side_effect=ThreadReadError("last page: b")):
            self.assertEqual(self.reader.fetch_thread_posts(self.thread, last_post_id="1065"), ([], "1065"))
        reason = self.reader.thread_warnings[0]["reason"]
        self.assertIn("Chrome Canary: last page: a", reason)
        self.assertIn("Playwright: last page: b", reason)

    def test_no_engine_is_reported(self):
        with mock.patch.object(XDAReader, "is_chrome_available", return_value=False), \
                mock.patch.object(xda_reader, "PLAYWRIGHT_AVAILABLE", False):
            self.assertEqual(self.reader.fetch_thread_posts(self.thread, last_post_id="1065"), ([], "1065"))
        self.assertIn("neither Chrome Canary nor Playwright", self.reader.thread_warnings[0]["reason"])

    def test_fetch_all_threads_reads_the_rest_and_resets_warnings(self):
        bad_id = self.reader.threads[0]["id"]

        def per_thread(thread, last):
            if thread["id"] == bad_id:
                raise ThreadReadError("last page: no posts on the page")
            return [{"post_id": "9", "thread_id": thread["id"]}], "9"

        state = {"xda": {t["id"]: "1" for t in self.reader.threads}}
        self.reader.thread_warnings = [{"thread_id": "stale", "name": "x", "kind": "failed", "reason": "old"}]
        with mock.patch.object(XDAReader, "is_chrome_available", return_value=True), \
                mock.patch.object(self.reader, "fetch_thread_posts_chrome", side_effect=per_thread), \
                mock.patch.object(xda_reader, "PLAYWRIGHT_AVAILABLE", False):
            posts, new_state = self.reader.fetch_all_threads(state)
        self.assertEqual(len(posts), len(self.reader.threads) - 1)
        self.assertEqual(new_state["xda"][bad_id], "1")  # not advanced: retried next run
        self.assertTrue(all(new_state["xda"][t["id"]] == "9" for t in self.reader.threads[1:]))
        self.assertEqual([w["thread_id"] for w in self.reader.thread_warnings], [bad_id])

    def test_more_than_max_pages_is_reported_as_truncated(self):
        pages = make_pages(1, 1000, XDAReader.MAX_PAGES + 5)  # posts 1000-1024, one per page
        fetch_page, _ = self.fetcher(pages)
        posts, highest = self.reader._collect_new_posts(self.thread, fetch_page, last_post_id="999")
        self.assertEqual([p["post_id"] for p in posts], [str(i) for i in range(1005, 1025)])
        self.assertEqual(highest, "1024")
        self.assertEqual(self.reader.thread_warnings[0]["kind"], "truncated")

    def test_no_truncation_warning_when_the_last_page_read_holds_last_post(self):
        # The MAX_PAGES-th page read holds last_post_id: everything unread was returned, nothing skipped
        pages = make_pages(1, 1000, XDAReader.MAX_PAGES + 1)  # 1000-1020; page 2 (=1001) is the 20th read
        fetch_page, _ = self.fetcher(pages)
        posts, _ = self.reader._collect_new_posts(self.thread, fetch_page, last_post_id="1001")
        self.assertEqual([p["post_id"] for p in posts], [str(i) for i in range(1002, 1021)])
        self.assertEqual(self.reader.thread_warnings, [])

    def test_no_truncation_warning_when_page_1_is_the_last_page_read(self):
        pages = make_pages(1, 1000, XDAReader.MAX_PAGES)  # the whole thread is MAX_PAGES pages
        fetch_page, _ = self.fetcher(pages)
        posts, _ = self.reader._collect_new_posts(self.thread, fetch_page, last_post_id="999")
        self.assertEqual(len(posts), XDAReader.MAX_PAGES)
        self.assertEqual(self.reader.thread_warnings, [])

    def test_playwright_fallback_keeps_the_threads_position(self):
        with mock.patch.object(XDAReader, "is_chrome_available", return_value=True), \
                mock.patch.object(self.reader, "fetch_thread_posts_chrome", side_effect=ThreadReadError("last page: x")), \
                mock.patch.object(xda_reader, "PLAYWRIGHT_AVAILABLE", True), \
                mock.patch.object(self.reader, "fetch_thread_posts_playwright", return_value=([], "1065")) as pw:
            self.reader.fetch_thread_posts(self.thread, last_post_id="1065")
        pw.assert_called_once_with(self.thread, "1065", 50)  # not None: that would read only the last page

    def test_fetch_all_threads_passes_each_threads_saved_position(self):
        seen = {}

        def per_thread(thread, last):
            seen[thread["id"]] = last
            return [], last
        state = {"xda": {t["id"]: f"1{i}" for i, t in enumerate(self.reader.threads)}}
        with mock.patch.object(XDAReader, "is_chrome_available", return_value=True), \
                mock.patch.object(self.reader, "fetch_thread_posts_chrome", side_effect=per_thread):
            self.reader.fetch_all_threads(state)
        self.assertEqual(seen, state["xda"])


class TestPageChecks(unittest.TestCase):
    def setUp(self):
        self.reader = XDAReader()
        self.thread = self.reader.threads[0]
        self.tid = self.thread["id"]

    def test_page_problem(self):
        url = self.thread["url"].rstrip("/") + "/page-3"
        self.assertIsNone(XDAReader._page_problem({"ready": "complete", "href": url}, self.tid))
        self.assertIsNone(XDAReader._page_problem({}, self.tid))  # old extractor output: no check possible
        self.assertIn("still loading", XDAReader._page_problem({"ready": "interactive", "href": url}, self.tid))
        other = "https://xdaforums.com/t/some-other-thread.4805239/page-2"
        self.assertIn("different page", XDAReader._page_problem({"ready": "complete", "href": other}, self.tid))

    def test_one_line(self):
        msg = 'TimeoutError: Page.goto: Timeout 1500ms exceeded.\nCall log:\n  - navigating to "x"\n'
        self.assertEqual(XDAReader._one_line(msg), 'TimeoutError: Page.goto: Timeout 1500ms exceeded. Call log: - navigating to "x"')
        self.assertEqual(len(XDAReader._one_line("x" * 500)), 200)

    def chrome_run(self, payload):
        out = mock.Mock(returncode=0, stdout=json.dumps(payload), stderr="")
        return mock.patch.object(xda_reader.subprocess, "run", return_value=out)

    def test_chrome_rejects_a_page_still_loading(self):
        page = {"page": 3, "posts": [{"post_id": "5"}], "ready": "loading", "href": self.thread["url"] + "/page-3"}
        with self.chrome_run(page):
            with self.assertRaises(ThreadReadError) as cm:
                self.reader.fetch_thread_posts_chrome(self.thread, "4")
        self.assertIn("page still loading", str(cm.exception))

    def test_chrome_rejects_another_threads_page(self):
        page = {"page": 1, "posts": [{"post_id": "5"}], "ready": "complete",
                "href": "https://xdaforums.com/t/other.4805239/page-1"}
        with self.chrome_run(page):
            with self.assertRaises(ThreadReadError) as cm:
                self.reader.fetch_thread_posts_chrome(self.thread, "4")
        self.assertIn("different page", str(cm.exception))

    def test_chrome_script_uses_its_own_tab_and_waits_for_it(self):
        page = {"page": 1, "posts": [{"post_id": "5"}], "ready": "complete", "href": self.thread["url"] + "/page-1"}
        with self.chrome_run(page) as run:
            self.reader.fetch_thread_posts_chrome(self.thread, "4")
        script = run.call_args[0][0][2]
        self.assertNotIn("active tab", script)
        self.assertIn("loading of newTab", script)
        self.assertIn("close newTab", script)


class TestRunnerBriefing(unittest.TestCase):
    """The briefing must say when XDA threads weren't read."""

    def run_main(self, *patches):
        import run_daily_review
        out = io.StringIO()
        with mock.patch.object(sys, "argv", ["run_daily_review.py", "--dry-run", "--skip-tg"]), \
                contextlib.redirect_stdout(out), contextlib.ExitStack() as stack:
            for p in patches:
                stack.enter_context(p)
            run_daily_review.main()
        return out.getvalue()

    def test_no_engine_is_a_briefing_warning(self):
        text = self.run_main(mock.patch.object(XDAReader, "is_available", return_value=False))
        n = len(XDAReader().threads)
        self.assertIn(f"WARNING: {n} XDA thread(s) not read", text)

    def test_failed_thread_is_listed_in_the_briefing(self):
        def fake_fetch_all(reader, state):
            reader.thread_warnings = [{"thread_id": "4804712", "name": "kodiak", "kind": "failed",
                                       "reason": "last page: no posts on the page"}]
            return [], state
        text = self.run_main(mock.patch.object(XDAReader, "is_available", return_value=True),
                             mock.patch.object(XDAReader, "is_chrome_available", return_value=True),
                             mock.patch.object(XDAReader, "fetch_all_threads", autospec=True, side_effect=fake_fetch_all))
        self.assertIn("!! XDA thread 4804712 (kodiak) NOT READ (retried next run): last page: no posts on the page", text)
        self.assertIn("WARNING: 1 XDA thread(s) not read, 0 partly read", text)
        self.assertIn("kodiak (#4804712): not read, retried next run", text)


if __name__ == "__main__":
    unittest.main()
