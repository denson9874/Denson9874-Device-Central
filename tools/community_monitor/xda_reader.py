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

    def fetch_thread_posts_chrome(
        self,
        thread_info: Dict[str, Any],
        last_post_id: Optional[str] = None
    ) -> Tuple[List[Dict[str, Any]], Optional[str]]:
        url = thread_info["url"]
        thread_id = thread_info["id"]
        device = thread_info.get("device", "unknown")
        target_url = url.rstrip("/") + "/page-999"

        js_code = """
        (function() {
            let posts = [];
            let els = document.querySelectorAll('article.message--post');
            for (let el of els) {
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
                let text = clone ? clone.innerText.trim() : (contentEl ? contentEl.innerText.trim() : '');
                let quotes = [];
                let quoteEls = el.querySelectorAll('blockquote.bbCodeBlock--quote');
                for (let q of quoteEls) {
                    quotes.push(q.innerText.trim());
                }
                posts.push({post_id: id, author: author, timestamp: ts, text: text, quotes: quotes});
            }
            return JSON.stringify(posts);
        })()
        """
        escaped_js = json.dumps(js_code)
        apple_script = f'''
        tell application "Google Chrome Canary"
            tell front window
                set newTab to make new tab with properties {{URL:"{target_url}"}}
            end tell
            delay 3
            set postData to execute active tab of front window javascript {escaped_js}
            tell front window
                close active tab
            end tell
            return postData
        end tell
        '''
        res = subprocess.run(["osascript", "-e", apple_script], capture_output=True, text=True, timeout=20)
        if res.returncode != 0 or not res.stdout.strip():
            return [], last_post_id

        try:
            raw_posts = json.loads(res.stdout.strip())
        except Exception:
            return [], last_post_id

        posts = []
        highest_id = last_post_id

        for p in raw_posts:
            pid = p.get("post_id", "")
            if last_post_id and pid:
                try:
                    if int(pid) <= int(str(last_post_id).replace("post-", "")):
                        continue
                except ValueError:
                    if pid == last_post_id:
                        continue

            posts.append({
                "source": "xda",
                "thread_id": thread_id,
                "thread_name": thread_info.get("name"),
                "device": device,
                "post_id": pid,
                "author": p.get("author", "Unknown"),
                "timestamp": p.get("timestamp") or datetime.now(timezone.utc).isoformat(),
                "text": p.get("text", ""),
                "quotes": p.get("quotes", []),
                "url": f"https://xdaforums.com/t/{thread_id}/post-{pid}"
            })

            if pid:
                try:
                    if not highest_id or int(pid) > int(str(highest_id).replace("post-", "")):
                        highest_id = pid
                except ValueError:
                    highest_id = pid

        return posts, highest_id

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
        device = thread_info.get("device", "unknown")

        posts = []
        highest_post_id = last_post_id

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

            try:
                # 1. Navigate to thread root
                page.goto(url, wait_until="domcontentloaded", timeout=30000)
                page.wait_for_timeout(2000)

                # Check for BunnyCDN challenge or wait for resolution
                if "Shield" in page.title() or "challenge" in page.content().lower():
                    page.wait_for_timeout(4000)

                # 2. Find pagination to navigate to the last page if multiple pages exist
                last_page_links = page.query_selector_all("ul.pageNav-main li.pageNav-page a")
                target_url = url
                if last_page_links:
                    last_href = last_page_links[-1].get_attribute("href")
                    if last_href:
                        if not last_href.startswith("http"):
                            target_url = f"https://xdaforums.com{last_href}"
                        else:
                            target_url = last_href
                        page.goto(target_url, wait_until="domcontentloaded", timeout=30000)
                        page.wait_for_timeout(2000)

                # 3. Extract posts on the current (latest) page
                post_elements = page.query_selector_all("article.message--post")
                for post_el in post_elements:
                    post_id = post_el.get_attribute("data-content") or post_el.get_attribute("id") or ""
                    post_id = post_id.replace("post-", "").strip()

                    # Filter by last_post_id if provided
                    if last_post_id and post_id:
                        try:
                            if int(post_id) <= int(last_post_id.replace("post-", "")):
                                continue
                        except ValueError:
                            if post_id == last_post_id:
                                continue

                    author_el = post_el.query_selector(".message-userDetails .username, [itemprop='name']")
                    author_name = author_el.inner_text().strip() if author_el else "Unknown"

                    time_el = post_el.query_selector("time.u-dt")
                    timestamp = time_el.get_attribute("datetime") if time_el else ""
                    if not timestamp and time_el:
                        timestamp = time_el.inner_text().strip()
                    if not timestamp:
                        timestamp = datetime.now(timezone.utc).isoformat()

                    content_el = post_el.query_selector(".bbWrapper")
                    content_text = content_el.inner_text().strip() if content_el else ""

                    # Extract quotes
                    quotes = []
                    quote_els = post_el.query_selector_all("blockquote.bbCodeBlock--quote")
                    for q in quote_els:
                        quotes.append(q.inner_text().strip())

                    posts.append({
                        "source": "xda",
                        "thread_id": thread_id,
                        "thread_name": thread_info.get("name"),
                        "device": device,
                        "post_id": post_id,
                        "author": author_name,
                        "timestamp": timestamp,
                        "text": content_text,
                        "quotes": quotes,
                        "url": f"https://xdaforums.com/t/{thread_id}/post-{post_id}"
                    })

                    if post_id:
                        try:
                            if not highest_post_id or int(post_id) > int(highest_post_id):
                                highest_post_id = post_id
                        except ValueError:
                            highest_post_id = post_id

            except Exception as e:
                sys.stderr.write(f"[XDAReader] Error reading thread {thread_id}: {e}\n")
            finally:
                browser.close()

        return posts, highest_post_id

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
