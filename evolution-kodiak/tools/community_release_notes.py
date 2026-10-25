#!/usr/bin/env python3
"""
Sunday Community Release Notes Generator for the Evolution X and DerpFest builds.

Reads COMMUNITY_TRIAGE.md and lists the release items for a device: rows that are
VERIFIED, or RESOLVED with a release date in Target Release and a category other
than Support (support answers and workarounds are closed but ship nothing).

    community_release_notes.py <device> [--triage PATH] [--changes-file CHANGES-<date>.txt]
    community_release_notes.py <device> [<device>...] --mark-released [--tag TAG]

--changes-file appends the device's items to its changelog (p11-routine.sh, on the
server). --mark-released moves the items to RELEASED once every device a row covers
is in the list, so an "All P11" row stays open until all four devices have shipped.
The triage file is the repo's COMMUNITY_TRIAGE.md, or ~/COMMUNITY_TRIAGE.md when this
script runs outside the repo (the server copy in ~).
"""

import argparse
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Set

P11_DEVICES = ["kodiak", "grizzly", "cubs", "yogi"]
ALL_DEVICES = P11_DEVICES + ["husky", "cheetah"]

# Columns of a backlog row, after the leading "|"
ID, DATE, REPORTER, DEVICE, CATEGORY, SEVERITY, STATUS, SUMMARY, TARGET = range(9)


def default_triage_path() -> Path:
    in_repo = Path(__file__).resolve().parents[2] / "COMMUNITY_TRIAGE.md"
    return in_repo if in_repo.exists() else Path.home() / "COMMUNITY_TRIAGE.md"


def split_row(line: str) -> Optional[List[str]]:
    """The nine cells of a backlog row, or None for any other line (or a row with a stray '|')."""
    if not line.startswith("| `ISS-"):
        return None
    cells = [c.strip() for c in line.split("|")][1:-1]
    if len(cells) != 9:
        sys.stderr.write(f"[community_release_notes] skipping a row with {len(cells)} cells: {line[:60]}\n")
        return None
    return cells


def device_scope(cell: str) -> Set[str]:
    dev = cell.replace("`", "").strip().lower()
    if dev == "all p11":
        return set(P11_DEVICES)
    if dev == "all":
        return set(ALL_DEVICES)
    return {dev}


def is_release_item(cells: List[str]) -> bool:
    status = cells[STATUS].replace("`", "")
    if status == "VERIFIED":
        return True
    return (status == "RESOLVED"
            and cells[CATEGORY].strip().lower() != "support"
            and re.match(r"\d{4}-\d{2}-\d{2}", cells[TARGET]) is not None)


def release_items(triage_path: Path, device: str) -> List[Dict[str, str]]:
    """The release items in triage_path that cover device."""
    if not triage_path.exists():
        return []
    items = []
    for line in triage_path.read_text(encoding="utf-8").splitlines():
        cells = split_row(line)
        if cells and device.lower() in device_scope(cells[DEVICE]) and is_release_item(cells):
            items.append({
                "id": cells[ID].replace("`", ""),
                "reporter": cells[REPORTER],
                "category": cells[CATEGORY],
                "summary": cells[SUMMARY],
            })
    return items


def mark_released(triage_path: Path, devices: List[str], tag: Optional[str] = None) -> List[str]:
    """Moves release items whose devices are all in `devices` to RELEASED. Returns their ids."""
    if not triage_path.exists():
        return []
    shipped = {d.lower() for d in devices}
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    marked, out = [], []
    for line in triage_path.read_text(encoding="utf-8").splitlines():
        cells = split_row(line)
        if cells and is_release_item(cells) and device_scope(cells[DEVICE]) <= shipped:
            cells[STATUS] = "`RELEASED`"
            cells[TARGET] = f"{today} ({tag})" if tag else today
            line = "| " + " | ".join(cells) + " |"
            marked.append(cells[ID].replace("`", ""))
        out.append(line)
    if marked:
        triage_path.write_text("\n".join(out) + "\n", encoding="utf-8")
    return marked


def main():
    parser = argparse.ArgumentParser(description="Sunday Community Release Notes Generator")
    parser.add_argument("devices", nargs="+", choices=ALL_DEVICES, metavar="device",
                        help=f"one or more of: {', '.join(ALL_DEVICES)}")
    parser.add_argument("--triage", type=Path, default=None,
                        help="COMMUNITY_TRIAGE.md to read (default: the repo's, else ~/COMMUNITY_TRIAGE.md)")
    parser.add_argument("--changes-file", type=Path, default=None,
                        help="CHANGES-<date>.txt to append the device's items to (one device only)")
    parser.add_argument("--mark-released", action="store_true",
                        help="Move the items for these devices to RELEASED (run after the builds are published)")
    parser.add_argument("--tag", default=None, help="Release tag recorded next to the date with --mark-released")
    args = parser.parse_args()

    if args.changes_file and len(args.devices) != 1:
        parser.error("--changes-file takes exactly one device")

    triage_path = args.triage or default_triage_path()
    if not triage_path.exists():
        sys.stderr.write(f"[community_release_notes] no triage file at {triage_path}; no community items added\n")
        sys.exit(1)

    for device in args.devices:
        items = release_items(triage_path, device)
        print(f"=== Community release items: {device} ({triage_path}) ===")
        if not items:
            print("No release items for this device.")
            continue
        notes = ["Community Fixes & Enhancements:"]
        notes += [f"  - [{i['category']}] {i['summary']} (Reported by {i['reporter']})" for i in items]
        print("\n".join(notes[1:]))
        if args.changes_file:
            with open(args.changes_file, "a", encoding="utf-8") as f:
                f.write("\n" + "\n".join(notes) + "\n")
            print(f"Appended {len(items)} items to {args.changes_file}")

    if args.mark_released:
        marked = mark_released(triage_path, args.devices, args.tag)
        print(f"Marked RELEASED in {triage_path}: {', '.join(marked) if marked else 'nothing'}")


if __name__ == "__main__":
    main()
