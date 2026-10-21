#!/usr/bin/env python3
"""
XDA Thread Ingestion Reader for ExpressiveOS / Evolution X.
Extracts community posts from active XDA threads:
- Kodiak & Grizzly (#4804712)
- Cubs (#4804723)
- Yogi (#4804826)
- Husky (#4805239)

Uses Playwright headless browser to bypass BunnyCDN Shield challenges.
Provides clean fallback diagnostics if Playwright is not yet installed.
"""

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Any

try:
    from playwright.sync_api import sync_playwright, Browser, Page, TimeoutError as PlaywrightTimeoutError
    PLAYWRIGHT_AVAILABLE = True
except ImportError:
    PLAYWRIGHT_AVAILABLE = False


class XDAReader:
    def __init__(self, config_path: Optional[str] = None):
        if config_path is None:
            config_path = str(Path(__file__).parent / "config.json")
        with open(config_path, "r", encoding="utf-8") as f:
            self.config = json.load(f)

        self.threads = self.config.get("xda", {}).get("threads", [])

    @staticmethod
    def is_chrome_available() -> bool:
        if sys.platform != "darwin":
            return False
        try:
            res = subprocess.run(
                ["osascript", "-e", 'tell application "System Events" to (name of processes) contains "Google Chrome Canary"'],
                capture_output=True, text=True, timeout=3
            )
            return res.returncode == 0 and "true" in res.stdout.lower()
        except Exception:
            return False

    def is_available(self) -> bool:
        return PLAYWRIGHT_AVAILABLE or self.is_chrome_available()

    # Pages walked back from the last one in a single review. A thread busier than this between two
    # reviews loses its oldest unread posts (with a warning) rather than stalling the review.
    MAX_PAGES = 20

    # Runs in the thread page: the page number shown and its posts (quotes left out of the text)
    _EXTRACT_JS = """
    (function() {
        let cur = document.querySelector('.pageNav-page--current');
        let page = cur ? parseInt(cur.innerText.trim(), 10) || 1 : 1;
        let posts = [];
        for (let el of document.querySelectorAll('article.message--post')) {
            let id = el.getAttribute('data-content') || el.getAttribute('id') || '';
            id = id.replace('post-', '').trim();
            let authorEl = el.querySelector('.message-userDetails .username, [itemprop="name"]');
            let author = authorEl ? authorEl.innerText.trim() : 'Unknown';
            let timeEl = el.querySelector('time.u-dt');
            let ts = timeEl ? (timeEl.getAttribute('datetime') || timeEl.innerText.trim()) : '';
            let contentEl = el.querySelector('.bbWrapper');
            let clone = contentEl ? contentEl.cloneNode(true) : null;
            if (clone) {
                clone.querySelectorAll('blockquote').forEach(b => b.remove());
            }
            let text = clone ? clone.innerText.trim() : '';
            let quotes = [];
            for (let q of el.querySelectorAll('blockquote.bbCodeBlock--quote')) {
                quotes.push(q.innerText.trim());
            }
            posts.push({post_id: id, author: author, timestamp: ts, text: text, quotes: quotes});
        }
        return JSON.stringify({page: page, posts: posts});
    })()
    """

    @staticmethod
    def _page_url(url: str, page: int) -> str:
        return url.rstrip("/") + f"/page-{page}"

    @staticmethod
    def _post_num(post_id: Optional[str]) -> Optional[int]:
        try:
            return int(str(post_id).replace("post-", ""))
        except (TypeError, ValueError):
            return None

    def _collect_new_posts(
        self,
        thread_info: Dict[str, Any],
        fetch_page,
        last_post_id: Optional[str] = None
    ) -> Tuple[List[Dict[str, Any]], Optional[str]]:
        """
        Walks back from the thread's last page until it reaches a post at or below last_post_id (or page 1),
        so posts on every unread page are returned, oldest first. fetch_page(n) returns (actual_page, raw_posts);
        n=999 lands on the last page. Without a last_post_id (first run) only the last page is read.
        """
        thread_id = thread_info["id"]
        device = thread_info.get("device", "unknown")
        last_num = self._post_num(last_post_id)

        pages: List[List[Dict[str, Any]]] = []
        page_no, raw = fetch_page(999)
        if raw is None:
            return [], last_post_id
        pages.append(raw)
        while last_post_id and page_no > 1 and len(pages) < self.MAX_PAGES:
            nums = [self._post_num(r.get("post_id")) for r in raw]
            if any(n is not None and last_num is not None and n <= last_num for n in nums) or \
                    any(r.get("post_id") == last_post_id for r in raw):
                break
            page_no, raw = fetch_page(page_no - 1)
            if raw is None:
                break
            pages.append(raw)
        else:
            if last_post_id and len(pages) >= self.MAX_PAGES:
                sys.stderr.write(
                    f"[XDAReader] Thread {thread_id}: more than {self.MAX_PAGES} unread pages; "
                    "older unread posts were skipped.\n"
                )

        posts = []
        highest_id = last_post_id
        seen = set()
        for raw in reversed(pages):
            for p in raw:
                pid = p.get("post_id", "")
                if not pid or pid in seen:
                    continue
                seen.add(pid)
                num = self._post_num(pid)
                if last_post_id and (pid == last_post_id or (num is not None and last_num is not None and num <= last_num)):
                    continue
                posts.append({
                    "source": "xda",
                    "thread_id": thread_id,
                    "thread_name": thread_info.get("name"),
                    "device": device,
                    "post_id": pid,
                    "author": p.get("author") or "Unknown",
                    "timestamp": p.get("timestamp") or datetime.now(timezone.utc).isoformat(),
                    "text": p.get("text", ""),
                    "quotes": p.get("quotes", []),
                    "url": f"https://xdaforums.com/t/{thread_id}/post-{pid}"
                })
                hnum = self._post_num(highest_id)
                if num is not None and (hnum is None or num > hnum):
                    highest_id = pid
        return posts, highest_id

    def fetch_thread_posts_chrome(
        self,
        thread_info: Dict[str, Any],
        last_post_id: Optional[str] = None
    ) -> Tuple[List[Dict[str, Any]], Optional[str]]:
        url = thread_info["url"]
        escaped_js = json.dumps(self._EXTRACT_JS)

        def fetch_page(n: int):
            apple_script = f"""
            tell application "Google Chrome Canary"
                tell front window
                    set newTab to make new tab with properties {{URL:"{self._page_url(url, n)}"}}
                end tell
                delay 3
                set postData to execute active tab of front window javascript {escaped_js}
                tell front window
                    close active tab
                end tell
                return postData
            end tell
            """
            res = subprocess.run(["osascript", "-e", apple_script], capture_output=True, text=True, timeout=20)
            if res.returncode != 0 or not res.stdout.strip():
                return n, None
            try:
                data = json.loads(res.stdout.strip())
            except Exception:
                return n, None
            return int(data.get("page") or 1), data.get("posts", [])

        return self._collect_new_posts(thread_info, fetch_page, last_post_id)

    def fetch_thread_posts(
        self,
        thread_info: Dict[str, Any],
        last_post_id: Optional[str] = None,
        max_posts: int = 50
    ) -> Tuple[List[Dict[str, Any]], Optional[str]]:
        if self.is_chrome_available():
            try:
                posts, highest = self.fetch_thread_posts_chrome(thread_info, last_post_id)
                if posts or highest:
                    return posts, highest
            except Exception as e:
                sys.stderr.write(f"[XDAReader] Chrome Canary fetch failed: {e}, falling back to Playwright\n")

        if PLAYWRIGHT_AVAILABLE:
            return self.fetch_thread_posts_playwright(thread_info, last_post_id, max_posts)

        sys.stderr.write(
            "[XDAReader] Neither Chrome Canary nor Playwright available. "
            "Run 'pip3 install playwright && playwright install chromium' or launch Chrome Canary.\\n"
        )
        return [], last_post_id

    def fetch_thread_posts_playwright(
        self,
        thread_info: Dict[str, Any],
        last_post_id: Optional[str] = None,
        max_posts: int = 50
    ) -> Tuple[List[Dict[str, Any]], Optional[str]]:
        url = thread_info["url"]
        thread_id = thread_info["id"]

        with sync_playwright() as p:
            browser = p.chromium.launch(
                headless=True,
                args=[
                    "--disable-blink-features=AutomationControlled",
                    "--no-sandbox",
                    "--disable-setuid-sandbox"
                ]
            )
            context = browser.new_context(
                user_agent=(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/124.0.0.0 Safari/537.36"
                ),
                viewport={"width": 1280, "height": 800}
            )
            page = context.new_page()

            def fetch_page(n: int):
                try:
                    page.goto(self._page_url(url, n), wait_until="domcontentloaded", timeout=30000)
                    page.wait_for_timeout(2000)
                    # BunnyCDN Shield challenge: give it time to resolve
                    if "Shield" in page.title() or "challenge" in page.content().lower():
                        page.wait_for_timeout(4000)
                    data = json.loads(page.evaluate(self._EXTRACT_JS))
                    return int(data.get("page") or 1), data.get("posts", [])
                except Exception as e:
                    sys.stderr.write(f"[XDAReader] Error reading thread {thread_id} page {n}: {e}\n")
                    return n, None

            try:
                return self._collect_new_posts(thread_info, fetch_page, last_post_id)
            finally:
                browser.close()

    def fetch_all_threads(
        self,
        state: Dict[str, Any]
    ) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
        """
        Iterates over all configured threads and extracts new posts.
        """
        all_posts = []
        updated_state = dict(state)
        xda_state = updated_state.setdefault("xda", {})

        for thread in self.threads:
            tid = thread["id"]
            last_id = xda_state.get(tid)
            posts, highest_id = self.fetch_thread_posts(thread, last_post_id=last_id)
            all_posts.extend(posts)
            if highest_id:
                xda_state[tid] = highest_id

        return all_posts, updated_state


if __name__ == "__main__":
    reader = XDAReader()
    print(f"Playwright available: {reader.is_available()}")
    if not reader.is_available():
        print("To enable XDA live scraping, install Playwright:")
        print("  pip3 install playwright && playwright install chromium")
        sys.exit(0)

    if reader.threads:
        sample_thread = reader.threads[0]
        print(f"Testing fetch for: {sample_thread['name']} ({sample_thread['url']})")
        posts, high = reader.fetch_thread_posts(sample_thread)
        print(f"Extracted {len(posts)} posts. Highest post ID: {high}")
        for p in posts[:3]:
            print(f"[{p['timestamp']}] {p['author']}: {p['text'][:100]}...")
