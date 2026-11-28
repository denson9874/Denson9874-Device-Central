#!/usr/bin/env python3
"""Offline unit tests for expressiveos-cheetah/sources/eos-org-organize.py.

Every subprocess call enforces an explicit timeout and uses a mock gh binary via EOS_GH_BIN.
"""

import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
SOURCES_DIR = TESTS_DIR.parent
ORG_SCRIPT = SOURCES_DIR / "eos-org-organize.py"


def load_module():
    spec = importlib.util.spec_from_file_location("eos_org_organize", ORG_SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestEosOrgOrganize(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="test-eos-org-")
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def run_cli(self, *args, env=None):
        full_env = os.environ.copy()
        if env:
            full_env.update(env)
        return subprocess.run(
            [sys.executable, str(ORG_SCRIPT), *args],
            env=full_env,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def test_catalog_integrity_and_counts(self):
        cat = self.mod.REPO_CATALOG
        self.assertEqual(len(cat), 127)

        counts = {}
        for name, spec in cat.items():
            org = spec["target_org"]
            counts[org] = counts.get(org, 0) + 1
            self.assertIn(org, self.mod.ORGS)
            self.assertIn(spec["function"], self.mod.FUNCTION_LABELS)
            self.assertTrue(spec["description"].strip(), f"blank desc for {name}")
            for t in spec["topics"]:
                self.assertRegex(t, self.mod.TOPIC_RE, f"invalid GitHub topic {t!r} on {name}")
            if org == "ExpressiveOS-Legacy":
                self.assertTrue(spec["archive"], f"legacy repo {name} must be archived")
            else:
                self.assertFalse(spec["archive"], f"active repo {name} must not be archived")
                self.assertNotIn("Evolution X 17", spec["description"], f"stale branding on {name}")

        self.assertEqual(counts, {
            "ExpressiveOS": 60,
            "ExpressiveOS-ASB": 34,
            "ExpressiveOS-Devices": 15,
            "ExpressiveOS-Legacy": 18,
        })
        # Git LFS backing store must remain in ExpressiveOS because .lfsconfig hardcodes ExpressiveOS/blobs
        self.assertEqual(cat["blobs"]["target_org"], "ExpressiveOS")
        self.assertEqual(cat["manifest"]["target_org"], "ExpressiveOS")

    def test_render_profile_pre_and_post_transfer(self):
        # Pre-transfer live view: all 127 repos currently in ExpressiveOS
        fake_live = {
            name: {
                "org": "ExpressiveOS",
                "name": name,
                "description": spec["description"],
                "archived": spec["archive"],
                "topics": spec["topics"],
            }
            for name, spec in self.mod.REPO_CATALOG.items()
        }
        pre_md = self.mod.render_profile_readme("ExpressiveOS", live_repos=fake_live, target_view=False)
        self.assertIn("(127 total)", pre_md)
        self.assertIn("Upstream AOSP Security Bulletin (ASB) Forks (34)", pre_md)
        self.assertIn("Archived / Legacy EOS 1.x (18)", pre_md)
        self.assertIn("https://github.com/ExpressiveOS/frameworks_base", pre_md)

        # Post-transfer target views across all 4 orgs
        post_main = self.mod.render_profile_readme("ExpressiveOS", target_view=True)
        post_asb = self.mod.render_profile_readme("ExpressiveOS-ASB", target_view=True)
        post_dev = self.mod.render_profile_readme("ExpressiveOS-Devices", target_view=True)
        post_leg = self.mod.render_profile_readme("ExpressiveOS-Legacy", target_view=True)
        self.assertIn("(60 total)", post_main)
        self.assertIn("(34 total)", post_asb)
        self.assertIn("(15 total)", post_dev)
        self.assertIn("(18 total)", post_leg)

    def test_rewrite_manifest_roundtrip_and_lint(self):
        sha = "b" * 40
        in_xml = self.tmp / "default.xml"
        out_xml = self.tmp / "out.xml"
        in_xml.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            "<manifest>\n"
            '  <remote name="aosp" fetch="https://android.googlesource.com" />\n'
            '  <remote name="expressiveos" fetch="https://github.com/ExpressiveOS" revision="expressiveos-2.0" />\n'
            '  <default revision="refs/tags/android-17.0.0_r1" remote="aosp" sync-j="4" />\n'
            f'  <project path="frameworks/base" name="frameworks_base" remote="expressiveos" revision="{sha}" />\n'
            f'  <project path="external/libpng" name="external_libpng" remote="expressiveos" revision="{sha}" />\n'
            f'  <project path="device/google/kodiak" name="device_google_kodiak" remote="expressiveos" revision="{sha}" />\n'
            f'  <project path="vendor/google/husky" name="vendor_google_husky" remote="expressiveos" revision="{sha}" />\n'
            f'  <project path="external/zlib" name="platform/external/zlib" remote="aosp" revision="{sha}" />\n'
            "</manifest>\n",
            encoding="utf-8",
        )
        res = self.run_cli("rewrite-manifest", "--in", str(in_xml), "--out", str(out_xml))
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("REWRITE_MANIFEST=OK", res.stdout)

        tree = ET.parse(str(out_xml))
        root = tree.getroot()
        remotes = {r.get("name"): r.get("fetch") for r in root.findall("remote")}
        self.assertEqual(remotes["expressiveos-asb"], "https://github.com/ExpressiveOS-ASB")
        self.assertEqual(remotes["expressiveos-devices"], "https://github.com/ExpressiveOS-Devices")

        projs = {p.get("name"): p.get("remote") for p in root.findall("project")}
        self.assertEqual(projs["frameworks_base"], "expressiveos")
        self.assertEqual(projs["external_libpng"], "expressiveos-asb")
        self.assertEqual(projs["device_google_kodiak"], "expressiveos-devices")
        self.assertEqual(projs["vendor_google_husky"], "expressiveos-devices")
        self.assertEqual(projs["platform/external/zlib"], "aosp")

        # Idempotent on second run
        out_xml2 = self.tmp / "out2.xml"
        res2 = self.run_cli("rewrite-manifest", "--in", str(out_xml), "--out", str(out_xml2))
        self.assertEqual(res2.returncode, 0, res2.stdout + res2.stderr)
        self.assertIn("Projects moved to new remotes: 0", res2.stdout)

    def test_mocked_transfer_handles_archived_legacy_and_missing_org_guard(self):
        state_file = self.tmp / "gh_state.json"
        state = {
            "orgs": ["ExpressiveOS"],
            "repos": {
                "ExpressiveOS": {
                    "external_libpng": {"archived": False, "description": "", "topics": []},
                    "device_google_kodiak": {"archived": False, "description": "", "topics": []},
                    "OTA": {"archived": True, "description": "", "topics": []},
                },
            },
            "log": [],
        }
        state_file.write_text(json.dumps(state), encoding="utf-8")

        mock_gh = self.tmp / "mock-gh"
        mock_gh.write_text(
            f"""#!/usr/bin/env python3
import json, sys
from pathlib import Path

sf = Path({str(state_file)!r})
st = json.loads(sf.read_text(encoding="utf-8"))
args = sys.argv[1:]
st["log"].append(" ".join(args))

def save():
    sf.write_text(json.dumps(st), encoding="utf-8")

if args[:2] == ["repo", "list"]:
    org = args[2]
    out = []
    for name, r in st["repos"].get(org, {{}}).items():
        out.append({{
            "name": name,
            "description": r["description"],
            "isArchived": r["archived"],
            "repositoryTopics": [{{"name": t}} for t in r["topics"]],
            "defaultBranchRef": {{"name": "expressiveos-2.0"}},
            "visibility": "PUBLIC",
            "diskUsage": 100,
        }})
    save()
    print(json.dumps(out))
    sys.exit(0)

if args[0] == "api":
    method = "GET"
    endpoint = args[1]
    if args[1] == "-X":
        method = args[2]
        endpoint = args[3]
    body = json.loads(sys.stdin.read()) if "--input" in args else {{}}
    if method == "GET" and endpoint.startswith("orgs/"):
        org = endpoint.split("/", 1)[1]
        save()
        sys.exit(0 if org in st["orgs"] else 1)
    if method == "GET" and endpoint.startswith("repos/"):
        _, org, repo = endpoint.split("/", 2)
        save()
        sys.exit(0 if repo in st["repos"].get(org, {{}}) else 1)
    if method == "PATCH" and endpoint.startswith("repos/"):
        _, org, repo = endpoint.split("/", 2)
        if "archived" in body:
            st["repos"][org][repo]["archived"] = body["archived"]
        if "description" in body:
            st["repos"][org][repo]["description"] = body["description"]
        save()
        sys.exit(0)
    if method == "POST" and endpoint.endswith("/transfer"):
        _, src_org, repo, _ = endpoint.split("/", 3)
        dest_org = body["new_owner"]
        r = st["repos"][src_org][repo]
        if r["archived"]:
            print("cannot transfer archived repo", file=sys.stderr)
            sys.exit(1)
        del st["repos"][src_org][repo]
        st["repos"].setdefault(dest_org, {{}})[repo] = r
        save()
        sys.exit(0)
save()
sys.exit(1)
""",
            encoding="utf-8",
        )
        mock_gh.chmod(mock_gh.stat().st_mode | stat.S_IXUSR)
        gh_env = {"EOS_GH_BIN": str(mock_gh)}

        # Missing target orgs must fail fast with exit code 2
        res_missing = self.run_cli("transfer", "--apply", "--skip-profile-refresh", env=gh_env)
        self.assertEqual(res_missing.returncode, 2)
        self.assertIn("do not exist yet", res_missing.stderr)

        # Create the 3 target orgs in mock state and execute transfer
        st = json.loads(state_file.read_text(encoding="utf-8"))
        st["orgs"] += ["ExpressiveOS-ASB", "ExpressiveOS-Devices", "ExpressiveOS-Legacy"]
        state_file.write_text(json.dumps(st), encoding="utf-8")

        res_tr = self.run_cli("transfer", "--apply", "--skip-profile-refresh", env=gh_env)
        self.assertEqual(res_tr.returncode, 0, res_tr.stdout + res_tr.stderr)
        self.assertIn("TRANSFER=OK (transferred=3)", res_tr.stdout)

        final_st = json.loads(state_file.read_text(encoding="utf-8"))
        self.assertIn("external_libpng", final_st["repos"]["ExpressiveOS-ASB"])
        self.assertIn("device_google_kodiak", final_st["repos"]["ExpressiveOS-Devices"])
        self.assertIn("OTA", final_st["repos"]["ExpressiveOS-Legacy"])
        # Legacy repo must have been unarchived for transfer and re-archived at destination
        self.assertTrue(final_st["repos"]["ExpressiveOS-Legacy"]["OTA"]["archived"])


if __name__ == "__main__":
    unittest.main()
