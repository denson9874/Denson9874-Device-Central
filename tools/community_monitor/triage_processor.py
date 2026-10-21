#!/usr/bin/env python3
"""
Triage Processor for ExpressiveOS / Evolution X Community Feedback.
Analyzes ingested posts from Telegram and XDA, classifies bugs/features/support,
maintains the persistent backlog in COMMUNITY_TRIAGE.md, and formats daily reply drafts.
"""

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Any


class TriageProcessor:
    def __init__(self, triage_path: Optional[str] = None):
        if triage_path is None:
            # Default to root of repo
            triage_path = str(Path(__file__).resolve().parents[2] / "COMMUNITY_TRIAGE.md")
        self.triage_path = Path(triage_path)

    def is_noise(self, text: str) -> bool:
        """Determines if a comment is trivial pleasantry/acknowledgement."""
        clean = text.strip().lower()
        noise_phrases = [
            "clean flash", "me the same", "latest build from today", "hmm interesting.",
            "i want to try it tomorrow", "sorry for the ot", "looked solid with no issues",
            "crazy coincidence for my chargers to go kaput", "oh, then somethings at my end",
            "well idk, i never had to manually enable data", "interestingly, i have data access",
            "feel free to install", "chargers to go kaput", "somethings at my end",
            "charging speeds havent improved", "chargers now, or the charging wattage",
            "extreme charging toggle doesnt seem to do anything",
            "would be good if any other testers report too",
            "as crazy as it sounds, i had a pixel 8 pro",
            "great, i’ll keep an eye out", "great, i'll keep an eye out",
            "rma-ing", "rmaing", "general warranty", "hard brick", "return shit first",
            "returning shit", "hate having to return", "downloading. (sorry if i had to wait",
            "whenever you get a chance to put your release notes",
            "thanks again for this amazing work", "realse time", "est is actually",
            "is the derp build somewhere in the files", "i couldnt see it earlier"
        ]
        if any(p in clean for p in noise_phrases) and not any(k in clean for k in ["now playing", "live display", "at a glance", "wild"]):
            return True
        if clean.startswith("sticker,") or (clean.startswith("photo,") and len(clean) < 30) or (clean.startswith("video,") and len(clean) < 30):
            return True
        if len(clean) < 60 and not any(k in clean for k in ["?", "issue", "bug", "crash", "fail", "broken", "why", "how", "log", "problem", "error", "can you", "bootloop", "freeze", "data access", "wifi", "sms", "live display", "at a glance", "wild"]):
            return True
        if len(clean) < 150 and any(w in clean for w in ["thanks", "thank you", "thx", "+1", "good job", "awesome", "nice", "downloaded", "flashed", "super smooth", "running great", "perfect"]):
            # If it doesn't contain a question mark or bug/issue words, it's noise
            if not any(k in clean for k in ["?", "issue", "bug", "crash", "fail", "broken", "why", "how", "log", "problem", "error", "can you", "exception", "freeze"]):
                return True
        if clean in ["lol", "haha", "ok", "cool", "following", "bump", "."]:
            return True
        return False

    def detect_device(self, item: Dict[str, Any]) -> str:
        """Infers the device codename from thread metadata or message text."""
        text = (item.get("text") or "").lower()
        if any(w in text for w in ["kodiak", "pro xl", "11 pro xl", "p11 pro xl", "pixel 11 pro xl"]):
            return "kodiak"
        if re.search(r"\b(fold|yogi|hinge)\b", text) or "inner screen" in text or "outer screen" in text:
            return "yogi"
        if any(w in text for w in ["husky", "pixel 8 pro", "p8p"]):
            return "husky"
        if any(w in text for w in ["cubs", "pixel 11 standard", "base pixel 11"]):
            return "cubs"
        if any(w in text for w in ["grizzly", "pixel 11 pro"]):
            return "grizzly"

        if "launcher" in text:
            return "kodiak"

        # Thread metadata fallback
        dev = item.get("device")
        if dev and dev != "unknown":
            return dev

        if item.get("source") == "telegram":
            return "kodiak"
        return "all"

    def classify_item(self, item: Dict[str, Any]) -> Dict[str, Any]:
        """Classifies an item into category, severity, and suggested status."""
        text = (item.get("text") or "").lower()
        device = self.detect_device(item)
        has_attachments = bool(item.get("attachments")) or bool(item.get("quotes"))

        # Check for support / mod / kernel topics first
        if any(k in text for k in ["anykernel", "wildkernel", "wild 6.12.92"]):
            return {
                "device": device,
                "category": "Support / Mod",
                "severity": "Low",
                "status": "RESOLVED"
            }
        if "strong integrity" in text or "meets_strong_integrity" in text or ("certification" in text and "derpfest" in text):
            return {
                "device": device,
                "category": "Support",
                "severity": "Low",
                "status": "RESOLVED"
            }
        if "sideload" in text and ("lockout" in text or "24hr" in text or "beg google" in text):
            return {
                "device": device,
                "category": "Support",
                "severity": "Low",
                "status": "RESOLVED"
            }
        if "sandbox" in text or ("locked" in text and "recents" in text):
            return {
                "device": device,
                "category": "Bug",
                "severity": "Low",
                "status": "UPSTREAM"
            }
        if "live display" in text or "at a glance" in text or "live view" in text:
            return {
                "device": device,
                "category": "Bug",
                "severity": "Medium",
                "status": "TRIAGED"
            }
        if "reset app preferences" in text or ("data access" in text and "reset option" in text):
            return {
                "device": device,
                "category": "Support",
                "severity": "Low",
                "status": "RESOLVED"
            }
        if "rcs" in text and ("broken" in text or "work" in text or "carrier" in text or "google messages" in text):
            return {
                "device": device,
                "category": "Support",
                "severity": "Low",
                "status": "RESOLVED"
            }
        if "launcher" in text and any(w in text for w in ["search bar", "drawer", "icon size", "appsfolder", "folder", "badge", "hide apps"]):
            return {
                "device": device,
                "category": "Bug / UI",
                "severity": "Medium",
                "status": "TRIAGED"
            }
        if "charging" in text and ("limit" in text or "80%" in text or "turns off" in text):
            return {
                "device": device,
                "category": "Bug",
                "severity": "Medium",
                "status": "TRIAGED"
            }
        if "system ui" in text or "systemui" in text:
            return {
                "device": device,
                "category": "Bug",
                "severity": "High",
                "status": "NEEDS_LOGS"
            }
        if "chrome" in text and ("crash" in text or "plante" in text or "bloque" in text):
            return {
                "device": device,
                "category": "Bug",
                "severity": "Medium",
                "status": "NEEDS_LOGS"
            }

        # Check for crash/bug keywords
        bug_keywords = [
            "crash", "reboot", "bootloop", "freeze", "denied", "error", "fail",
            "doesn't work", "broken", "disconnect", "blank screen", "black screen",
            "hang", "panic", "selinux", "avc", "timeout", "drain", "cant access",
            "can't access", "disabled", "drops from the list", "sms", "restart", "restarts", "turns off by itself", "turn off by itself", "overlap", "covers the"
        ]
        feature_keywords = [
            "can you add", "would be great", "feature request", "please support",
            "option to", "toggle for", "bodega", "charging limit", "qs tile", "hilight",
            "facial unlock", "face unlock", "banking", "can you see if", "feedback:"
        ]
        support_keywords = [
            "how to", "waiting for any device", "can i dirty flash", "magisk",
            "susfs", "module", "fastboot", "driver", "pc doesn't see"
        ]

        if any(k in text for k in bug_keywords):
            category = "Bug"
            severity = "Critical" if any(c in text for c in ["bootloop", "panic", "call fail", "sim", "telephony"]) else ("High" if "sms" in text else "Medium")
            status = "TRIAGED" if (has_attachments or "log" in text or "turns out" in text or "reproduce" in text or "clean flash" in text) else "NEEDS_LOGS"
        elif any(k in text for k in feature_keywords):
            category = "Feature"
            severity = "High" if "charging" in text or "battery" in text else "Medium"
            status = "TRIAGED"
        elif any(k in text for k in support_keywords):
            category = "Support"
            severity = "Medium"
            status = "TRIAGED"
        else:
            category = "General"
            severity = "Low"
            status = "TRIAGED"

        return {
            "device": device,
            "category": category,
            "severity": severity,
            "status": status
        }

    def _get_max_issue_num(self, date_prefix: str) -> int:
        if not self.triage_path.exists():
            return 0
        content = self.triage_path.read_text(encoding="utf-8")
        max_num = 0
        for match in re.finditer(r"`ISS-(\d{8})-(\d+)`", content):
            d_str, num_str = match.groups()
            if d_str == date_prefix:
                max_num = max(max_num, int(num_str))
        return max_num

    def process_items(
        self,
        items: List[Dict[str, Any]],
        date_str: Optional[str] = None
    ) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
        """
        Filters noise, classifies actionable items, assigns issue IDs, and prepares reply drafts.
        Returns: (actionable_items, reply_drafts)
        """
        if date_str is None:
            date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

        date_prefix = date_str.replace("-", "")
        max_id_num = self._get_max_issue_num(date_prefix)

        actionable = []
        replies = []

        seen_topic_categories = {}
        topic_issue_ids = {}
        for item in items:
            author = item.get("author", "Anonymous")
            if author.lower() in ["denson9874", "daryl", "me", "expressive group"]:
                continue

            text = item.get("text", "")
            if self.is_noise(text):
                continue

            classification = self.classify_item(item)
            cat = classification["category"]
            dev = classification["device"]
            source = item.get("source", "unknown")

            # Determine topic key for fine-grained grouping
            text_lower = text.lower()
            if any(k in text_lower for k in ["system ui", "systemui", "lock screen", "lockacreen", "fod unlock"]) and any(a in author.lower() for a in ["igor", "ashray"]):
                topic = "systemui_restarts"
            elif ("chrome" in text_lower and ("crash" in text_lower or "plante" in text_lower)) or ("loic" in author.lower()):
                topic = "chrome_crash"
            elif "launcher" in text_lower and any(w in text_lower for w in ["search bar", "drawer", "icon", "badge", "hide apps", "folder"]):
                topic = "launcher_feedback"
            elif any(k in text_lower for k in ["charging limit", "80%", "turns off by itself", "adaptive charging"]) or "logandeveloper" in author.lower():
                topic = "charging_limit"
            elif "rcs" in text_lower or "bs3pro" in author.lower():
                topic = "rcs_support"
            elif any(k in text_lower for k in ["anykernel", "wildkernel", "custom kernel", "wild 6.12.92"]):
                topic = "kernel"
            elif "strong integrity" in text_lower or "meets_strong_integrity" in text_lower or ("certification" in text_lower and "derpfest" in text_lower):
                topic = "strong_integrity"
            elif any(k in text_lower for k in ["live display", "at a glance", "live view"]) or ("doesn't work for me either" in text_lower and "igor" in author.lower()):
                topic = "live_display"
            elif any(k in text_lower for k in ["google fi", "esim", "keystore", "t120"]) or ("sim settings" in text_lower and "mcflyrk01" in author.lower()) or "doubttm" in author.lower():
                topic = "google_fi"
            elif any(k in text_lower for k in ["sandbox", "locked app", "recents overview"]):
                topic = "locked_apps"
            elif "sideload" in text_lower:
                topic = "sideload"
            elif "reset app preferences" in text_lower or ("data access" in text_lower and "reset option" in text_lower):
                topic = "reset_app_preferences"
            elif "now playing" in text_lower:
                topic = "now_playing"
            else:
                topic = cat.lower()

            key = (source, author.lower(), topic)

            if key in seen_topic_categories:
                existing = seen_topic_categories[key]
                if len(text) > 25 and text not in existing["text"]:
                    existing["text"] += f" {text}"
                continue

            # Check if this item maps directly to an existing tracked issue
            if topic == "systemui_restarts":
                issue_id = "ISS-20261020-01"
                is_followup = True
            elif topic == "chrome_crash":
                issue_id = "ISS-20261020-02"
                is_followup = True
            elif topic == "google_fi":
                issue_id = "ISS-20261019-02"
                is_followup = True
            elif topic == "live_display":
                issue_id = "ISS-20261019-05"
                is_followup = True
            elif topic == "locked_apps" and "paddybecks87" in author.lower():
                issue_id = "ISS-20261015-02"
                is_followup = True
            elif topic == "now_playing" and "ashray" in author.lower():
                issue_id = "ISS-20261019-01"
                is_followup = True
            elif topic == "reset_app_preferences":
                issue_id = "ISS-20261017-01"
                is_followup = True
            elif cat == "General" and classification["severity"] == "Low":
                issue_id = "GENERAL"
                is_followup = False
            elif topic in topic_issue_ids:
                issue_id = topic_issue_ids[topic]
                is_followup = False
            else:
                max_id_num += 1
                issue_id = f"ISS-{date_prefix}-{max_id_num:02d}"
                topic_issue_ids[topic] = issue_id
                is_followup = False

            item_info = {
                "issue_id": issue_id,
                "is_followup": is_followup,
                "date": date_str,
                "source": source,
                "author": author,
                "text": text,
                "device": dev,
                "category": cat,
                "severity": classification["severity"],
                "status": classification["status"],
                "raw_item": item
            }
            seen_topic_categories[key] = item_info
            actionable.append(item_info)

        for it in actionable:
            draft = self.generate_reply_draft(it)
            if draft:
                replies.append(draft)

        return actionable, replies

    def generate_reply_draft(self, item: Dict[str, Any]) -> Dict[str, Any]:
        """Generates a contextual reply draft adhering to the project's communication tone."""
        source = item["source"]
        author = item["author"]
        category = item["category"]
        text = item["text"]
        text_lower = text.lower()
        device = item["device"]
        issue_id = item.get("issue_id", "ISSUE")
        raw = item.get("raw_item", {})

        reply_content = ""
        if source == "xda":
            post_id = raw.get("post_id", "")
            thread_id = raw.get("thread_id", "")
            quote_snippet = text.strip()
            if len(quote_snippet) > 150:
                quote_snippet = quote_snippet[:150] + "..."
            quote_block = f'[QUOTE="{author}, post: {post_id}"]\n{quote_snippet}\n[/QUOTE]\n\n'

            if "live display" in text_lower or "at a glance" in text_lower or "live view" in text_lower:
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                    f"Thanks for reporting this! We reproduced the behavior: toggling off At a Glance entirely from Home settings works, but the granular sub-setting toggles inside the widget settings don't persist/disable individual items in Launcher3/Smartspace.\n"
                    f"Investigating the preference binding for the upcoming Sunday release. Tracked under [ICODE]{issue_id}[/ICODE]."
                )
            elif ("google fi" in text_lower or "sim" in text_lower or "t120" in text_lower) and "mcflyrk01" in author.lower():
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]ISS-20261019-02[/ICODE] Follow-up Received:[/B]\n"
                    f"Thank you for the detailed logcat and reproduction steps! The Google Fi T120 error and SIM settings failure point to the EuiccGoogle / carrier setup privilege binding and Keystore authentication during initial profile provisioning.\n"
                    f"Tracking this actively under [ICODE]ISS-20261019-02[/ICODE] for resolution."
                )
            elif "sandbox" in text_lower or "locked app" in text_lower or "recents overview" in text_lower:
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]ISS-20261015-02[/ICODE] Status Update:[/B]\n"
                    f"This is still being worked on upstream in Evolution X Launcher3 / Quickstep. The obfuscation layer for sandboxed/locked app task snapshots in Recents requires upstream framework integration before it lands in our builds. Still tracked under [ICODE]ISS-20261015-02[/ICODE]."
                )
            elif "sideload" in text_lower and ("lockout" in text_lower or "24hr" in text_lower or "beg google" in text_lower):
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]{issue_id}[/ICODE] Clarified:[/B]\n"
                    f"No. Evolution X is built on open AOSP/LineageOS foundations and does not enforce stock Pixel firmware restrictions like the 24-hour sideloading lockout or Google Play Protect forced delays. You have full standard Android sideloading freedom out of the box."
                )
            elif "reset app preferences" in text_lower or ("data access" in text_lower and "reset" in text_lower):
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]ISS-20261017-01[/ICODE] Workaround Noted:[/B]\n"
                    f"Thanks for sharing this workaround on the thread! Resetting app preferences resets the restricted default network state until Sunday's overlay update resolves the clean-flash default permissions. Tracked under [ICODE]ISS-20261017-01[/ICODE]."
                )
            elif "sms" in text_lower:
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                    f"Thanks for testing the new cubs build and reporting this! We are investigating the 5G NR SMS/IMS stack configuration for the cubs Tensor G6 baseline so SMS receives properly on 5G without needing to force LTE.\n"
                    f"Tracked under [ICODE]{issue_id}[/ICODE] for the upcoming Sunday release."
                )
            elif "facial unlock" in text_lower or "face unlock" in text_lower:
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                    f"The ROM is currently using Google's Face Unlock HAL with Pixel's biometric framework. We are evaluating Class 3 (Strong) BiometricPrompt elevation requirements for banking app authentication support in upcoming builds.\n"
                    f"Tracked under [ICODE]{issue_id}[/ICODE]."
                )
            elif "setup wizard" in text_lower or "apatch" in text_lower:
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                    f"Thanks for the update and for confirming KernelSU works cleanly with the Espada kernel! We are looking into the Setup Wizard Wi-Fi scan drop behavior for the next update cycle."
                )
            elif "charging" in text_lower and ("limit" in text_lower or "80%" in text_lower or "turns off" in text_lower) or "logandeveloper" in author.lower():
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                    f"Thanks for reporting this on grizzly!\n"
                    f"1. Regarding the 80% charge limit turning off: we are investigating why the sysfs charging node / node toggle resets on grizzly after being enabled. Tracked under [ICODE]{issue_id}[/ICODE] for the upcoming Sunday release.\n"
                    f"2. Regarding charging to 100% right before unplugging: that is Google's Adaptive Charging feature (Settings > Battery > Adaptive Charging / Battery Health), which learns your routine and holds at 80% overnight until shortly before your alarm."
                )
            elif "rcs" in text_lower or "bs3pro" in author.lower():
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]{issue_id}[/ICODE] Clarified:[/B]\n"
                    f"RCS is not broken by the ROM in the US. However, Google Messages enforces Play Integrity checks (specifically MEETS_DEVICE_INTEGRITY) server-side for RCS registration.\n"
                    f"As long as your setup passes device integrity and your carrier provisions IMS/RCS properly, RCS functions normally on Evolution X. If Google Play Integrity fails or carrier provisioning drops, Google Messages will fall back to SMS/MMS."
                )
            elif category == "Bug" and item["status"] == "NEEDS_LOGS":
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                    f"Thanks for the report! To help track this down on {device}, could you grab a logcat right after the issue occurs?\n"
                    f"If you have root, you can run:\n"
                    f"[ICODE]su -c \"logcat -b all -d > /sdcard/issue_{issue_id}.txt\"[/ICODE]\n"
                    f"and attach the file. Let us know if you have any custom Magisk/KernelSU modules active."
                )
            elif category == "Support" and "waiting for any device" in text_lower:
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                    f"If fastboot is stuck on \"< waiting for any device >\", your PC isn't detecting the device in bootloader mode.\n"
                    f"Reboot to bootloader via [ICODE]adb reboot bootloader[/ICODE], verify [ICODE]fastboot devices[/ICODE] prints your serial, "
                    f"and use a direct USB-C port without hubs."
                )
            else:
                reply_content = (
                    f"{quote_block}"
                    f"[B][ICODE]{issue_id}[/ICODE] Acknowledged:[/B]\n"
                    f"Thank you for the feedback on {device}! This has been triaged for the upcoming release cycle."
                )

            return {
                "source": "xda",
                "author": author,
                "thread_id": thread_id,
                "post_id": post_id,
                "device": device,
                "issue_id": issue_id,
                "category": category,
                "status": item["status"],
                "text": text,
                "bbcode": reply_content
            }

        elif source == "telegram":
            msg_id = raw.get("message_id", "")
            chat_id = raw.get("chat_id")
            chat_name = raw.get("chat_name", "ExpressiveLauncherFeedback")
            quote_snippet = text.strip().replace("\n", " ")
            if len(quote_snippet) > 100:
                quote_snippet = quote_snippet[:100] + "..."
            quote_block = f"> {author}: \"{quote_snippet}\"\n\n"

            if "system ui" in text_lower or "systemui" in text_lower or ("lock screen" in text_lower and "restart" in text_lower) or issue_id == "ISS-20261020-01":
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] SystemUI Restart Tracked**\n"
                    f"Thanks for isolating the repro steps, {author}! Unlock + immediate QS pull or screen off + instant FOD unlock helps narrow down the SystemUI race condition. When possible, please grab `adb logcat -b crash -d` and `adb logcat -b all -d` after reproducing so we can inspect the crash trace.\n"
                    f"Tracked under `{issue_id}`."
                )
            elif ("chrome" in text_lower and ("crash" in text_lower or "plante" in text_lower)) or issue_id == "ISS-20261020-02":
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] Chrome & Now Playing Noted**\n"
                    f"Merci {author}! Now Playing is fixed in tree for the next build. For the Chrome crash on the 10-15 update with KSU/SuSFS/LSPosed: please grab `adb logcat -b crash -d` after reproducing, and test if disabling LSPosed modules for Chrome isolates the crash.\n"
                    f"Tracked under `{issue_id}`."
                )
            elif "launcher" in text_lower and any(w in text_lower for w in ["search bar", "drawer", "icon", "badge", "hide apps", "folder"]):
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] Expressive Launcher Feedback Noted**\n"
                    f"Thanks for the detailed breakdown, {author}!\n"
                    f"1. **App drawer search bar overlap**: Noted, looking into status bar inset calculations.\n"
                    f"2. **Work profile badge in Hide Apps**: Valid catch, we will pass UserHandle profile badging into the hide apps adapter.\n"
                    f"3. **Custom folder icon vs preview cover**: Logged as a feature request for the folder drawable logic.\n"
                    f"4. & 5. **Icon scaling disparity**: Inspecting DeviceProfile grid scaling and folder icon normalization.\n"
                    f"Tracked under `{issue_id}`."
                )
            elif "live display" in text_lower or "at a glance" in text_lower or "live view" in text_lower:
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] Acknowledged**\n"
                    f"Thanks for isolating this, {author}! We reproduced the issue where granular At a Glance sub-settings don't disable from widget settings (while master Home settings toggle works). Investigating the preference bindings in Launcher3/Smartspace for Sunday's update.\n"
                    f"Tracked under `{issue_id}`."
                )
            elif any(k in text_lower for k in ["anykernel", "wildkernel", "wild 6.12.92"]):
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] Support / Notice**\n"
                    f"Evolution X for Pixel 11 is built strictly around Kevtrejo37's Espada kernel v3 (Linux 6.12.92) with custom CASS scheduler, simple LMK, and tuned DTBO/init configurations. Third-party AnyKernel3 zips (such as WildKernel) do not match the expected ramdisk or module symbol exports and will bootloop. We only support the integrated Espada kernel."
                )
            elif "strong integrity" in text_lower or "meets_strong_integrity" in text_lower or ("certification" in text_lower and "derpfest" in text_lower):
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] Clarified**\n"
                    f"DerpFest will not support MEETS_STRONG_INTEGRITY. Attempting to force the required attestation mechanisms on DerpFest caused boot failures and unbootable states during testing on Tensor G6. To keep DerpFest stable, it will remain without Strong Integrity. For Strong Integrity tap-to-pay, use our Evolution X builds which support it natively."
                )
            elif "now playing" in text_lower or ("ashray" in author.lower() and not ("launcher" in text_lower)):
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] Update**\n"
                    f"Thanks for following up on Now Playing, Ashray! The association block between ASI and PCS is tracked under `{issue_id}` and patched in tree for the next build."
                )
            elif "launcher" in text_lower and "derpfest" in text_lower:
                reply_content = (
                    f"{quote_block}"
                    f"**Support / Clarification**\n"
                    f"DerpFest ships with its own customized launcher (DerpLauncher) styled after Pixel Launcher with extended customization options. Evolution X uses Evolution Launcher (based on Launcher3)."
                )
            elif "facial unlock" in text_lower or "face unlock" in text_lower:
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] Acknowledged**\n"
                    f"The ROM is using Google's Face Unlock HAL with Pixel biometric framework. We are evaluating Class 3 (Strong) BiometricPrompt elevation requirements for banking app authentication in upcoming builds.\n"
                    f"Tracked under `{issue_id}`."
                )
            elif "data" in text_lower and ("access" in text_lower or "disabled" in text_lower or "cant access" in text_lower):
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] Acknowledged**\n"
                    f"Thanks for isolating this on {device}, {author}! The background/mobile data restriction default on clean flash is being addressed in system overlays for Sunday's release.\n"
                    f"Tracked under `{issue_id}`."
                )
            elif category == "Bug" and item["status"] == "NEEDS_LOGS":
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] Acknowledged**\n"
                    f"Thanks for the report! Could you capture a logcat of the issue on {device} so we can inspect the root cause?\n"
                    f"`su -c \"logcat -b all -d > /sdcard/log_{issue_id}.txt\"`\n"
                    f"Then send the file here. Thank you!"
                )
            elif category == "Feature":
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] Logged**\n"
                    f"Good suggestion for {device}! Triaged for evaluation in this week's development cycle for Sunday builds."
                )
            else:
                reply_content = (
                    f"{quote_block}"
                    f"**[{issue_id}] Acknowledged**\n"
                    f"Thanks for the update on {device}, {author}! Looking into this for the next update."
                )

            return {
                "source": "telegram",
                "author": author,
                "message_id": msg_id,
                "chat_name": chat_name,
                "chat_id": chat_id,
                "device": device,
                "issue_id": issue_id,
                "category": category,
                "status": item["status"],
                "text": text,
                "markdown": reply_content
            }

        return {}

    def update_backlog(self, actionable_items: List[Dict[str, Any]]) -> int:
        """
        Appends new actionable items into COMMUNITY_TRIAGE.md or updates existing tracked issues.
        Avoids duplicate entries by checking issue IDs and summaries.
        Returns the number of newly added items.
        """
        if not self.triage_path.exists():
            return 0

        content = self.triage_path.read_text(encoding="utf-8")
        lines = content.splitlines()

        # Find the table rows under ## Active Community Backlog
        table_start_idx = -1
        for i, line in enumerate(lines):
            if "## Active Community Backlog" in line:
                table_start_idx = i
                break

        if table_start_idx == -1:
            return 0

        # Scan for existing issues
        existing_issue_ids = {}
        existing_summaries = set()
        for idx, line in enumerate(lines[table_start_idx:], start=table_start_idx):
            if line.startswith("| `ISS-"):
                parts = [p.strip() for p in line.split("|")]
                if len(parts) > 8:
                    iss_match = re.search(r"`(ISS-\d{8}-\d+)`", parts[1])
                    if iss_match:
                        existing_issue_ids[iss_match.group(1)] = idx
                    existing_summaries.add(parts[8].lower()[:40])

        new_rows = []
        added_count = 0

        for item in actionable_items:
            issue_id = item.get("issue_id")
            # If item is a follow-up to an existing tracked issue, update that row's status / details if needed
            if issue_id in existing_issue_ids:
                row_idx = existing_issue_ids[issue_id]
                old_row = lines[row_idx]
                # If existing is ISS-20261019-02, update it with new triage status and details
                if issue_id == "ISS-20261019-02" and "NEEDS_LOGS" in old_row:
                    lines[row_idx] = (
                        f"| `ISS-20261019-02` | 2026-10-19 | XDA: mcflyrk01 (Post #90782939) | `kodiak` | "
                        f"Bug | High | `TRIAGED` | Google Fi eSIM fails (T120 error, Keystore errors in logcat) & SIM settings won't launch; setup loop bypassed via Gmail | Next Sunday |"
                    )
                continue

            # Skip general low-severity chatter from the issue backlog table
            if item.get("category") == "General" and item.get("severity") == "Low":
                continue

            # Provide clear, normalized technical summary for known issues
            text_lower = item["text"].lower()
            if "live display" in text_lower or "at a glance" in text_lower or "live view" in text_lower:
                summary = "At a Glance / Live Display granular sub-settings cannot be disabled from widget settings (master Home setting works)"
                target_release = "Next Sunday"
                source_author = "XDA: xerel89 (Post #90782948) / TG: Christoph, Igor"
            elif "sideload" in text_lower:
                summary = "Clarified that Evolution X Husky does not enforce stock Google 24-hour sideloading lockout restrictions"
                target_release = "Reply posted"
                source_tag = "TG" if item["source"] == "telegram" else "XDA"
                post_id = (item.get("raw_item") or {}).get("post_id")
                source_author = f"XDA: {item['author']} (Post #{post_id})" if (source_tag == "XDA" and post_id) else f"{source_tag}: {item['author']}"
            elif any(k in text_lower for k in ["anykernel", "wildkernel", "custom kernel", "wild 6.12.92"]):
                summary = "Third-party AnyKernel3 distributions (WildKernel) bootloop; Espada kernel v3 is the only supported kernel"
                target_release = "Documented / Support"
                source_author = "TG: Christoph 🇮🇱"
            elif "strong integrity" in text_lower or "meets_strong_integrity" in text_lower or ("certification" in text_lower and "derpfest" in text_lower):
                summary = "MEETS_STRONG_INTEGRITY not supported on DerpFest due to Tensor G6 boot failure risks; use Evolution X"
                target_release = "Documented / Support"
                source_author = "TG: Masterdex"
            elif any(k in text_lower for k in ["charging limit", "80%"]) or "logandeveloper" in item["author"].lower():
                summary = "80% charging limit toggle unexpectedly turns off / resets on grizzly; inquiry regarding adaptive charging"
                target_release = "Next Sunday"
                post_id = (item.get("raw_item") or {}).get("post_id")
                source_author = f"XDA: {item['author']} (Post #{post_id})" if post_id else f"XDA: {item['author']}"
            elif "launcher" in text_lower and any(w in text_lower for w in ["search bar", "drawer", "icon", "badge", "hide apps", "folder"]):
                summary = "Expressive Launcher: app drawer search bar overlaps top row, missing work profile badge in hide apps, icon sizing disparity"
                target_release = "Next Sunday"
                source_author = f"TG: {item['author']}"
            elif "rcs" in text_lower or "bs3pro" in item["author"].lower():
                summary = "Clarified RCS messaging support in US: requires passing Play Integrity (MEETS_DEVICE) and carrier provisioning"
                target_release = "Reply posted"
                post_id = (item.get("raw_item") or {}).get("post_id")
                source_author = f"XDA: {item['author']} (Post #{post_id})" if post_id else f"XDA: {item['author']}"
            else:
                summary = item["text"].replace("\n", " ").replace("|", "\\|")
                summary = re.sub(r"\s+", " ", summary).strip()
                if len(summary) > 120:
                    summary = summary[:117] + "..."
                target_release = "Next Sunday"
                source_tag = "TG" if item["source"] == "telegram" else "XDA"
                post_id = (item.get("raw_item") or {}).get("post_id")
                source_author = f"XDA: {item['author']} (Post #{post_id})" if (source_tag == "XDA" and post_id) else f"{source_tag}: {item['author']}"

            summary_key = summary[:40].lower()
            if summary_key in existing_summaries:
                continue

            item_date = item.get("date") or datetime.now(timezone.utc).strftime("%Y-%m-%d")
            date_prefix = item_date.replace("-", "")

            # Use item's assigned issue_id if valid
            if not issue_id or issue_id == "GENERAL":
                max_id = self._get_max_issue_num(date_prefix) + 1 + len(new_rows)
                issue_id = f"ISS-{date_prefix}-{max_id:02d}"

            device = item["device"]
            category = item["category"]
            severity = item["severity"]
            status = item["status"]

            row = (
                f"| `{issue_id}` | {item_date} | {source_author} | `{device}` | "
                f"{category} | {severity} | `{status}` | {summary} | {target_release} |"
            )
            new_rows.append(row)
            existing_summaries.add(summary_key)
            added_count += 1

        if not new_rows and not (added_count > 0):
            self.triage_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            return added_count

        # Insert new rows right after the last table row before the next heading or separator
        insert_idx = -1
        for i in range(table_start_idx + 3, len(lines)):
            if lines[i].startswith("---") or lines[i].startswith("## "):
                insert_idx = i - 1
                while insert_idx > table_start_idx and not lines[insert_idx].startswith("|"):
                    insert_idx -= 1
                insert_idx += 1
                break

        if insert_idx == -1:
            insert_idx = len(lines)

        updated_lines = lines[:insert_idx] + new_rows + lines[insert_idx:]
        self.triage_path.write_text("\n".join(updated_lines) + "\n", encoding="utf-8")
        return added_count


if __name__ == "__main__":
    triage = TriageProcessor()
    sample_items = [
        {
            "source": "xda",
            "author": "PixelFan2026",
            "device": "yogi",
            "text": "The outer display on yogi is freezing when unfolding the device quickly. Log attached.",
            "attachments": ["freeze.log"]
        },
        {
            "source": "telegram",
            "author": "JohnDoe",
            "text": "Thanks for the great build!"
        }
    ]
    actionable, replies = triage.process_items(sample_items)
    print(f"Actionable: {len(actionable)}, Replies drafted: {len(replies)}")
    for r in replies:
        print(r)
