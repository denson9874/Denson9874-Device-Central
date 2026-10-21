#!/usr/bin/env python3
"""
XDA Thread Reply and Release Notes Poster for ExpressiveOS / Evolution X.
Automates posting replies to acknowledge community issues and publishing release notes.
Supports:
1. Google Chrome Canary via AppleScript (uses Daryl's authenticated denson9874 session).
2. Playwright headless browser (if cookies/storage state are available).
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, Optional, Any

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]


class XDAPoster:
    def __init__(self, config_path: Optional[str] = None):
        if config_path is None:
            config_path = str(SCRIPT_DIR / "config.json")
        with open(config_path, "r", encoding="utf-8") as f:
            self.config = json.load(f)

        self.threads = self.config.get("xda", {}).get("threads", [])
        self.thread_map = {t["id"]: t for t in self.threads}
        for t in self.threads:
            self.thread_map[t["device"]] = t

    def get_thread_info(self, thread_or_device: str) -> Optional[Dict[str, Any]]:
        if thread_or_device in self.thread_map:
            return self.thread_map[thread_or_device]
        # Match numeric thread id in string
        for tid, tinfo in self.thread_map.items():
            if str(tid) == str(thread_or_device):
                return tinfo
        return None

    def post_reply_chrome(
        self,
        thread_url: str,
        bbcode_content: str,
        dry_run: bool = False
    ) -> Dict[str, Any]:
        """
        Posts BBCode to an XDA thread using Google Chrome Canary.
        Bypasses Cloudflare / BunnyCDN by using the already-authenticated browser session.
        """
        if dry_run:
            print(f"[XDAPoster DRY-RUN] Would post to {thread_url}:")
            print("-" * 40)
            print(bbcode_content)
            print("-" * 40)
            return {"success": True, "dry_run": True, "url": thread_url}

        # Escape bbcode_content for embedding in JS
        js_escaped_content = json.dumps(bbcode_content)
        # The JS sits inside an AppleScript string literal: escape it for AppleScript too
        js_escaped_content = js_escaped_content.replace("\\", "\\\\").replace('"', '\\"')

        apple_script = f"""
        tell application "Google Chrome Canary"
            tell front window
                set newTab to make new tab with properties {{URL:"{thread_url}"}}
            end tell
            delay 4
            
            -- Wait for quick reply form to load
            set maxRetries to 6
            set replyLoaded to false
            repeat with i from 1 to maxRetries
                set checkRes to execute active tab of front window javascript "
                    (function() {{
                        let form = document.querySelector('form.js-quickReply');
                        return !!form;
                    }})()
                "
                if checkRes is true or checkRes is "true" then
                    set replyLoaded to true
                    exit repeat
                end if
                delay 1.5
            end repeat
            
            if not replyLoaded then
                close active tab of front window
                return "{{\\"success\\": false, \\"error\\": \\"Quick reply form not found on page\\"}}"
            end if
            
            -- Toggle BBCode mode, enter message, and submit
            set postRes to execute active tab of front window javascript "
                (function() {{
                    let form = document.querySelector('form.js-quickReply');
                    if (!form) return JSON.stringify({{success: false, error: 'Form not found'}});
                    
                    // 1. Toggle BBCode editor if Froala WYSIWYG is active
                    let bbToggle = document.querySelector('[data-xf-click=bb-code-toggle], button[data-cmd=xfBbCode]');
                    let ta = document.querySelector('textarea[name=message]');
                    if (bbToggle && (!ta || ta.offsetWidth === 0)) {{
                        bbToggle.click();
                    }}
                    
                    // Re-query textarea after toggle
                    ta = document.querySelector('textarea[name=message]');
                    let content = {js_escaped_content};
                    
                    if (ta) {{
                        ta.value = content;
                        ta.dispatchEvent(new Event('input', {{ bubbles: true }}));
                        ta.dispatchEvent(new Event('change', {{ bubbles: true }}));
                    }} else {{
                        // Fallback to froala contenteditable div if bbcode toggle unavailable
                        let fr = document.querySelector('.fr-element, .fr-view');
                        if (fr) {{
                            fr.innerText = content;
                            fr.dispatchEvent(new Event('input', {{ bubbles: true }}));
                        }} else {{
                            return JSON.stringify({{success: false, error: 'Could not find message textarea or editor'}});
                        }}
                    }}
                    
                    // 2. Click Post reply
                    let submitBtn = form.querySelector('button.button--primary, button[type=submit]');
                    if (!submitBtn) {{
                        return JSON.stringify({{success: false, error: 'Submit button not found'}});
                    }}
                    submitBtn.click();
                    return JSON.stringify({{success: true, submitted: true}});
                }})()
            "
            
            delay 3
            set finalUrl to URL of active tab of front window
            close active tab of front window
            return "{{\\"success\\": true, \\"final_url\\": \\"" & finalUrl & "\\"}}"
        end tell
        """

        try:
            proc = subprocess.run(
                ["osascript", "-e", apple_script],
                capture_output=True,
                text=True,
                check=True,
                timeout=45
            )
            raw_output = proc.stdout.strip()
            # Parse json from output
            match = re.search(r"\{.*\}", raw_output)
            if match:
                return json.loads(match.group(0))
            return {"success": True, "raw": raw_output}
        except subprocess.TimeoutExpired:
            return {"success": False, "error": "Operation timed out during XDA post"}
        except subprocess.CalledProcessError as e:
            return {"success": False, "error": f"AppleScript error: {e.stderr.strip()}"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def acknowledge_issue(
        self,
        thread_id: str,
        post_id: str,
        author: str,
        device: str,
        issue_id: str,
        user_text: str,
        category: str,
        status: str,
        dry_run: bool = False
    ) -> Dict[str, Any]:
        """
        Formats and submits an issue acknowledgment reply to an XDA thread.
        """
        tinfo = self.get_thread_info(thread_id)
        if not tinfo:
            return {"success": False, "error": f"Thread ID {thread_id} not found in configuration"}

        thread_url = tinfo["url"]
        quote_snippet = user_text.strip()
        if len(quote_snippet) > 200:
            quote_snippet = quote_snippet[:200] + "..."

        quote_block = f'[QUOTE="{author}, post: {post_id}"]\n{quote_snippet}\n[/QUOTE]\n\n'

        if category == "Bug" and status == "NEEDS_LOGS":
            ack_body = (
                f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                f"Thanks for reporting this on [B]{device}[/B]! To isolate the root cause, could you grab a clean logcat right after the issue reproduces?\n\n"
                f"With root (Magisk/KernelSU), you can run:\n"
                f"[ICODE]su -c \"logcat -b all -d > /sdcard/issue_{issue_id}.txt\"[/ICODE]\n\n"
                f"Please attach the log file or share a pastebin link so we can investigate. Thank you!"
            )
        elif category == "Support" and "waiting for any device" in user_text.lower():
            ack_body = (
                f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                f"If fastboot hangs on [ICODE]< waiting for any device >[/ICODE], your PC cannot communicate with the device in bootloader mode.\n\n"
                f"1. If booted into Android OS, reboot to bootloader first: [ICODE]adb reboot bootloader[/ICODE]\n"
                f"2. Verify connection: [ICODE]fastboot devices[/ICODE] (ensure your serial number prints)\n"
                f"3. Use a direct USB-C port on your computer (avoid USB hubs/adapters) and official Google platform-tools r35+."
            )
        elif category == "Feature":
            ack_body = (
                f"[B][ICODE]{issue_id}[/ICODE] Logged:[/B]\n"
                f"Thank you for the suggestion for [B]{device}[/B]! This request has been logged in our community backlog for evaluation in the upcoming build cycle."
            )
        else:
            ack_body = (
                f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                f"Thank you for the feedback on [B]{device}[/B]! This report has been triaged into our development backlog for the next release update."
            )

        full_bbcode = quote_block + ack_body
        return self.post_reply_chrome(thread_url, full_bbcode, dry_run=dry_run)

    def post_release_announcement(
        self,
        device: str,
        bbcode_content: str,
        dry_run: bool = False
    ) -> Dict[str, Any]:
        """
        Posts a new release announcement post to the device's XDA thread.
        """
        tinfo = self.get_thread_info(device)
        if not tinfo:
            return {"success": False, "error": f"Device {device} not found in XDA configuration"}

        return self.post_reply_chrome(tinfo["url"], bbcode_content, dry_run=dry_run)


def main():
    parser = argparse.ArgumentParser(description="XDA Thread Posting and Issue Acknowledgment")
    parser.add_argument("--device", help="Target device codename (kodiak, grizzly, cubs, yogi, husky)")
    parser.add_argument("--thread-id", help="Target XDA thread ID")
    parser.add_argument("--post-id", default="0", help="Quoted post ID")
    parser.add_argument("--author", default="User", help="Author of quoted post")
    parser.add_argument("--issue-id", help="Issue tracker ID (e.g. ISS-20261016-02)")
    parser.add_argument("--quote-text", help="Text to quote")
    parser.add_argument("--message", help="Direct BBCode text to post")
    parser.add_argument("--file", help="Path to file containing BBCode message")
    parser.add_argument("--category", default="General", help="Issue category (Bug, Feature, Support)")
    parser.add_argument("--status", default="TRIAGED", help="Issue status (TRIAGED, NEEDS_LOGS)")
    parser.add_argument("--dry-run", action="store_true", help="Print BBCode without posting")
    args = parser.parse_args()

    poster = XDAPoster()

    # Mode 1: Acknowledge an issue
    if args.issue_id and args.quote_text:
        tid = args.thread_id or args.device or "kodiak"
        res = poster.acknowledge_issue(
            thread_id=tid,
            post_id=args.post_id,
            author=args.author,
            device=args.device or "kodiak",
            issue_id=args.issue_id,
            user_text=args.quote_text,
            category=args.category,
            status=args.status,
            dry_run=args.dry_run
        )
        print(json.dumps(res, indent=2))
        return

    # Mode 2: Direct message or file post
    bbcode = args.message
    if args.file:
        bbcode = Path(args.file).read_text(encoding="utf-8")

    if not bbcode:
        parser.error("Must provide either (--issue-id and --quote-text) or (--message or --file)")

    target = args.device or args.thread_id
    if not target:
        parser.error("Must specify --device or --thread-id")

    res = poster.post_release_announcement(target, bbcode, dry_run=args.dry_run)
    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
