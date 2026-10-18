#!/usr/bin/env python3
"""
Automated Community Release Notes Publisher for ExpressiveOS / Evolution X / DerpFest.
Gathers build artifact metadata, compiles resolved community issues from COMMUNITY_TRIAGE.md,
generates dual-platform release announcements (XDA BBCode & Telegram Markdown),
and automatically publishes them across both platforms on Daryl's behalf.
"""

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Any

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]

# Ensure local imports work
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(REPO_ROOT / "evolution-kodiak" / "tools"))
from xda_poster import XDAPoster
from tg_poster import TelegramPoster
# Which backlog rows are release items, and for which devices: shared with the Sunday changelog
from community_release_notes import release_items, mark_released as mark_triage_released

DEVICE_NAMES = {
    "kodiak": "Google Pixel 11 Pro XL",
    "grizzly": "Google Pixel 11 Pro",
    "cubs": "Google Pixel 11",
    "yogi": "Google Pixel 11 Pro Fold",
    "husky": "Google Pixel 8 Pro"
}


def format_changelog_items(items: List[str], style: str) -> str:
    """Formats extra changelog lines as list items: "bbcode" for XDA, "telegram" for Telegram."""
    bullet = "[*]" if style == "bbcode" else "•"
    return "\n".join(f"{bullet} {item}" for item in items)


def read_changelog_items(path: Path) -> List[str]:
    """Reads one changelog item per line, skipping blank lines and lines starting with #."""
    lines = (line.strip() for line in path.read_text(encoding="utf-8").splitlines())
    return [line for line in lines if line and not line.startswith("#")]


class ReleasePublisher:
    def __init__(self, triage_path: Optional[str] = None, out_dir: Optional[str] = None):
        if triage_path is None:
            triage_path = str(REPO_ROOT / "COMMUNITY_TRIAGE.md")
        self.triage_path = Path(triage_path)
        self.out_dir = Path(out_dir) if out_dir else REPO_ROOT / "evolution-kodiak/community/replies"
        self.xda_poster = XDAPoster()
        self.tg_poster = TelegramPoster()

    def get_resolved_community_fixes(self, device: str) -> List[Dict[str, str]]:
        """Release items in COMMUNITY_TRIAGE.md for this device (see community_release_notes.py)."""
        return release_items(self.triage_path, device)

    def mark_items_released(self, devices: List[str], release_tag: str) -> List[str]:
        """Moves release items covered by `devices` to RELEASED; returns their ids."""
        return mark_triage_released(self.triage_path, devices, release_tag)

    def inspect_build_artifacts(
        self,
        rom: str,
        device: str
    ) -> Dict[str, Any]:
        """Finds build files locally in Google Drive or out directory."""
        candidates = [
            Path(f"/Users/densond/Google Drive/My Drive/{rom}/{device}"),
            REPO_ROOT / f"out/target/product/{device}",
            Path(f"/Users/densond/Developer/ExpressiveOS/releases/{device}")
        ]

        found_ota = None
        found_fb = None
        ota_sha = None
        fb_sha = None

        for cdir in candidates:
            if not cdir.exists():
                continue
            for f in cdir.iterdir():
                fname = f.name
                if fname.endswith(".zip") and not fname.endswith("-fastboot.zip"):
                    if not found_ota or f.stat().st_mtime > found_ota.stat().st_mtime:
                        found_ota = f
                elif fname.endswith("-fastboot.zip"):
                    if not found_fb or f.stat().st_mtime > found_fb.stat().st_mtime:
                        found_fb = f

        def get_sha256(p: Path) -> str:
            # Check for existing .sha256 or .sha256sum file first
            for ext in [".sha256", ".sha256sum"]:
                sf = p.parent / f"{p.name}{ext}"
                if sf.exists():
                    txt = sf.read_text(encoding="utf-8").strip()
                    parts = txt.split()
                    if parts:
                        return parts[0]
            # Compute sha256
            hasher = hashlib.sha256()
            with open(p, "rb") as f:
                while chunk := f.read(65536):
                    hasher.update(chunk)
            return hasher.hexdigest()

        if found_ota:
            ota_sha = get_sha256(found_ota)
        if found_fb:
            fb_sha = get_sha256(found_fb)

        # Missing files stay visibly missing in the draft, and publish_release won't post it
        return {
            "complete": bool(found_ota and found_fb),
            "ota_file": found_ota.name if found_ota else "NOT FOUND",
            "ota_size_mb": round(found_ota.stat().st_size / (1024 * 1024), 1) if found_ota else "?",
            "ota_sha256": ota_sha or "NOT FOUND",
            "fastboot_file": found_fb.name if found_fb else "NOT FOUND",
            "fastboot_size_mb": round(found_fb.stat().st_size / (1024 * 1024), 1) if found_fb else "?",
            "fastboot_sha256": fb_sha or "NOT FOUND"
        }

    def format_xda_announcement(
        self,
        rom: str,
        device: str,
        version: str,
        artifacts: Dict[str, Any],
        community_fixes: List[Dict[str, str]],
        changelog_extra: str = ""
    ) -> str:
        """Formats comprehensive release notes in XenForo BBCode."""
        full_device = DEVICE_NAMES.get(device, device.upper())
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

        fixes_bbcode = ""
        if community_fixes:
            fixes_bbcode = "[SIZE=4][B]Community Fixes & Reporter Credits:[/B][/SIZE]\n[LIST]\n"
            for f in community_fixes:
                fixes_bbcode += f"[*] [B][ICODE]{f['id']}[/ICODE][/B] [{f['category']}] {f['summary']} (Reported by: [I]{f['reporter']}[/I])\n"
            fixes_bbcode += "[/LIST]\n\n"

        bbcode = f"""[CENTER][SIZE=5][B]New Update: {rom} {version} for {full_device} ({device})[/B][/SIZE]
[B]Build Date:[/B] {today} | [B]Android Version:[/B] 17
[B]Security Patch Level:[/B] 2026-10-05 | [B]SELinux:[/B] Enforcing[/CENTER]

[HR][/HR]

[SIZE=4][B]Package Downloads & Checksums:[/B][/SIZE]
[LIST]
[*] [B]Fastboot Factory Zip (Recommended Clean Flash):[/B]
[ICODE]{artifacts['fastboot_file']}[/ICODE] ({artifacts['fastboot_size_mb']} MB)
[B]SHA-256:[/B] [ICODE]{artifacts['fastboot_sha256']}[/ICODE]

[*] [B]Recovery A/B OTA Package (Dirty Flash / Sideload):[/B]
[ICODE]{artifacts['ota_file']}[/ICODE] ({artifacts['ota_size_mb']} MB)
[B]SHA-256:[/B] [ICODE]{artifacts['ota_sha256']}[/ICODE]
[/LIST]

[SIZE=3][B]Direct Drive Folder:[/B] Available under Google Drive [ICODE]{rom}/{device}/[/ICODE][/SIZE]

[HR][/HR]

{fixes_bbcode}[SIZE=4][B]Highlights & Changelog:[/B][/SIZE]
[LIST]
[*] Android 17 stable source rebase with complete Pixel hardware integration
[*] Clean SEPolicy compilation passing 100% against stock vendor policy
[*] Espada Kernel v3 integration with CASS scheduler and Simple LMK
[*] Full VoLTE/VoNR telephony and MediaTek T900 modem stabilization
{changelog_extra}
[/LIST]

[HR][/HR]

[SIZE=4][B]Flashing Instructions (Fastboot Update):[/B][/SIZE]
[CODE]
# 1. Reboot device to bootloader
adb reboot bootloader

# 2. Verify connection
fastboot devices

# 3. Flash update (use -w for clean install)
fastboot update {artifacts['fastboot_file']}
[/CODE]

[HR][/HR]

[SIZE=3][B]Special Thanks & Credits:[/B][/SIZE]
[LIST]
[*] [B]Kevtrejo37[/B] for the Espada Kernel ([URL="https://xdaforums.com/t/4799975/"]XDA Thread[/URL] | [URL="https://t.me/+DJmYe5_dfmwyODUx"]Telegram[/URL] | [URL="https://github.com/atrejokm301/espada-kernel"]GitHub[/URL])
[*] [B]Sultan Alsawaf[/B] for CASS and Simple LMK optimizations
[*] [B]The GrapheneOS Project[/B] for zram and memory management upstream patches
[*] The [B]{rom}[/B] team and our community testers on Telegram & XDA
[/LIST]
"""
        return bbcode.strip()

    def format_telegram_announcement(
        self,
        rom: str,
        device: str,
        version: str,
        artifacts: Dict[str, Any],
        community_fixes: List[Dict[str, str]],
        changelog_extra: str = ""
    ) -> str:
        """Formats announcement in clean Markdown with zip files in backticks."""
        full_device = DEVICE_NAMES.get(device, device.upper())
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

        fixes_md = ""
        if community_fixes:
            fixes_md = "\n**Community Fixes & Acknowledgments:**\n"
            for f in community_fixes:
                fixes_md += f"• `{f['id']}` {f['summary']} (thanks {f['reporter']})\n"

        md = f"""🚀 **New Update Released: {rom} {version}**
📱 **Device:** {full_device} (`{device}`)
📅 **Date:** {today} | **Android 17** | **SELinux Enforcing**

---

📦 **Downloads & Hashes:**
• **Fastboot Zip:** `{artifacts['fastboot_file']}` ({artifacts['fastboot_size_mb']} MB)
  `SHA-256: {artifacts['fastboot_sha256']}`
• **OTA Sideload Zip:** `{artifacts['ota_file']}` ({artifacts['ota_size_mb']} MB)
  `SHA-256: {artifacts['ota_sha256']}`

💾 *Synced directly to Google Drive folder:* `{rom}/{device}/`

---
{fixes_md}
✨ **Highlights:**
• Rebased on Android 17 with full Pixel 11 hardware features
• Zero SEPolicy denials against stock vendor
• Espada Kernel v3 (CASS scheduler & Simple LMK)
• High-speed charging & VoLTE/VoNR fully stabilized
{changelog_extra}

---

⚡ **Fastboot Flashing:**
```bash
adb reboot bootloader
fastboot devices
fastboot update {artifacts['fastboot_file']}
```

🙏 **Credits:**
• **Kevtrejo37** for the Espada Kernel ([XDA Thread](https://xdaforums.com/t/4799975/) | [Telegram](https://t.me/+DJmYe5_dfmwyODUx))
• **Sultan Alsawaf** & **The GrapheneOS Project**
• All our community testers in `@ExpressiveLauncherFeedback`!
"""
        return self.tg_poster.sanitize_telegram_markdown(md.strip())

    def publish_release(
        self,
        rom: str,
        device: str,
        version: str = "v17",
        dry_run: bool = False,
        mark_released: bool = True,
        changelog_items: Optional[List[str]] = None
    ) -> Dict[str, Any]:
        """Orchestrates building, formatting, and live posting across XDA and Telegram.

        Live posting needs both zips to be found. Items are marked RELEASED only after both
        posts succeed, and only when mark_released (a run over several devices marks once, at the end).
        changelog_items are extra highlight lines for this release (e.g. a new built-in app).
        """
        print(f"=== Publishing {rom} {version} Release for {device.upper()} ===")
        artifacts = self.inspect_build_artifacts(rom, device)
        fixes = self.get_resolved_community_fixes(device)
        print(f"• Found {len(fixes)} resolved community items in backlog.")

        items = changelog_items or []
        xda_text = self.format_xda_announcement(rom, device, version, artifacts, fixes,
                                                format_changelog_items(items, "bbcode"))
        tg_text = self.format_telegram_announcement(rom, device, version, artifacts, fixes,
                                                    format_changelog_items(items, "telegram"))

        # Save copy to replies directory
        date_compact = datetime.now(timezone.utc).strftime("%Y%m%d")
        self.out_dir.mkdir(parents=True, exist_ok=True)
        announcement_file = self.out_dir / f"RELEASE_{rom}_{device}_{date_compact}.md"
        announcement_file.write_text(
            f"# {rom} {device.upper()} Release Announcement ({date_compact})\n\n"
            f"## XDA BBCode\n```bbcode\n{xda_text}\n```\n\n"
            f"## Telegram Markdown\n```markdown\n{tg_text}\n```\n",
            encoding="utf-8"
        )
        print(f"• Saved release announcement draft to: {announcement_file}")

        results = {
            "xda": None,
            "telegram": None,
            "draft_file": str(announcement_file)
        }

        if not dry_run and not artifacts["complete"]:
            error = f"build zips for {rom} {device} not found; draft saved, nothing posted"
            print(f"• REFUSED: {error}")
            results["xda"] = results["telegram"] = {"success": False, "error": error}
            return results

        # 1. Post to XDA
        print(f"• Posting to XDA thread for {device}...")
        results["xda"] = self.xda_poster.post_release_announcement(device, xda_text, dry_run=dry_run)

        # 2. Post to Telegram (@ExpressiveGroup)
        print(f"• Posting to Telegram @ExpressiveGroup...")
        results["telegram"] = self.tg_poster.post_release_announcement("ExpressiveGroup", tg_text, dry_run=dry_run)

        posted = bool(results["xda"] and results["xda"].get("success")
                      and results["telegram"] and results["telegram"].get("success"))
        if not dry_run and mark_released and fixes and posted:
            marked = self.mark_items_released([device], f"{rom}-{version}")
            print(f"• Marked RELEASED in COMMUNITY_TRIAGE.md: {', '.join(marked) or 'nothing (multi-device rows wait for the rest)'}")

        return results


def main():
    parser = argparse.ArgumentParser(description="Publish Release Notes to XDA and Telegram")
    parser.add_argument("--device", required=True, choices=["kodiak", "grizzly", "cubs", "yogi", "husky"])
    parser.add_argument("--rom", default="DerpFest", choices=["DerpFest", "EvolutionX"])
    parser.add_argument("--version", default="v17", help="ROM release version")
    parser.add_argument("--dry-run", action="store_true", help="Format and save announcement without live posting")
    parser.add_argument("--changelog-extra-file", type=Path,
                        help="Extra highlight lines, one per line (blank lines and lines starting with # are skipped)")
    args = parser.parse_args()

    changelog_items = read_changelog_items(args.changelog_extra_file) if args.changelog_extra_file else []

    publisher = ReleasePublisher()
    res = publisher.publish_release(
        rom=args.rom,
        device=args.device,
        version=args.version,
        dry_run=args.dry_run,
        changelog_items=changelog_items
    )
    print("\nPublish Results:")
    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
