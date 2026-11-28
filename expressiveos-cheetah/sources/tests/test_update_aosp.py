#!/usr/bin/env python3
"""Offline unit tests for expressiveos-cheetah/sources/update-aosp.py.

Uses local bare git repositories (file://) and a mock gh CLI script via EOS_GH_BIN.
Every subprocess call enforces an explicit timeout.
"""

import base64
import http.server
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
SOURCES_DIR = TESTS_DIR.parent
UPDATE_SCRIPT = SOURCES_DIR / "update-aosp.py"
UPDATE_SH = SOURCES_DIR / "update.sh"

TEST_ENV_BASE = {
    "GIT_AUTHOR_NAME": "Test Author",
    "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test Author",
    "GIT_COMMITTER_EMAIL": "test@example.com",
    "GIT_CONFIG_NOSYSTEM": "1",
}


def run(cmd, cwd=None, env=None, check=True, timeout=30):
    full_env = os.environ.copy()
    full_env.update(TEST_ENV_BASE)
    if env:
        full_env.update(env)
    proc = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=full_env,
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    if check and proc.returncode != 0:
        raise AssertionError(
            f"command failed ({proc.returncode}): {' '.join(cmd)}\n"
            f"STDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )
    return proc


def init_bare(path):
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True)
    run(["git", "init", "--bare", str(path)])
    # Match Gerrit/GitHub behavior for fetching pinned 40-hex commit SHAs
    run(["git", "--git-dir", str(path), "config", "uploadpack.allowAnySHA1InWant", "true"])
    return path


def commit_files(repo_dir, files, msg):
    repo_dir = Path(repo_dir)
    for rel, content in files.items():
        p = repo_dir / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
        run(["git", "add", rel], cwd=repo_dir)
    run(["git", "commit", "-m", msg], cwd=repo_dir)
    return run(["git", "rev-parse", "HEAD"], cwd=repo_dir).stdout.strip()


def make_eos_manifest(projects, eos_org_url, aosp_base_url):
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<manifest>",
        f'  <remote name="aosp" fetch="{aosp_base_url}" />',
        f'  <remote name="expressiveos" fetch="{eos_org_url}" />',
        '  <default remote="aosp" revision="expressiveos-2.0" sync-j="4" />',
    ]
    for p in projects:
        attrs = [
            f'path="{p["path"]}"',
            f'name="{p["name"]}"',
            f'remote="{p["remote"]}"',
            f'revision="{p["revision"]}"',
        ]
        lines.append(f"  <project {' '.join(attrs)} />")
    lines.append("</manifest>\n")
    return "\n".join(lines)


def make_aosp_manifest(projects, default_rev):
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<manifest>",
        '  <remote name="aosp" fetch=".." />',
        f'  <default remote="aosp" revision="{default_rev}" />',
    ]
    for p in projects:
        rev_attr = f' revision="{p["revision"]}"' if "revision" in p else ""
        lines.append(f'  <project path="{p["path"]}" name="{p["name"]}"{rev_attr} />')
    lines.append("</manifest>\n")
    return "\n".join(lines)


class MockASBWorld:
    """Self-contained local AOSP + ExpressiveOS git fixture."""

    def __init__(self, root):
        self.root = Path(root)
        self.aosp_dir = self.root / "aosp"
        self.eos_dir = self.root / "eos"
        self.work_dir = self.root / "work"
        self.scratch = self.root / "build"
        self.aosp_dir.mkdir(parents=True)
        self.eos_dir.mkdir(parents=True)
        self.work_dir.mkdir(parents=True)
        self.scratch.mkdir(parents=True)

        self.aosp_base_url = f"file://{self.aosp_dir}"
        self.eos_org_url = f"file://{self.eos_dir}"
        self.aosp_manifest_bare = init_bare(self.aosp_dir / "platform" / "manifest")
        self.eos_manifest_bare = init_bare(self.eos_dir / "manifest")

        # 1. Existing EOS fork: frameworks/base -> ExpressiveOS/frameworks_base (will apply CLEAN)
        self.fb_aosp_bare = init_bare(self.aosp_dir / "platform" / "frameworks" / "base")
        self.fb_eos_bare = init_bare(self.eos_dir / "frameworks_base")
        fb_w = self.scratch / "fb"
        fb_w.mkdir()
        run(["git", "init", "-b", "main"], cwd=fb_w)
        fb_r1 = commit_files(fb_w, {"core.txt": "line1\nline2\n", "eos.txt": "base\n"}, "AOSP r1 base")
        run(["git", "push", str(self.fb_aosp_bare), "HEAD:refs/tags/android-security-17.0.0_r1"], cwd=fb_w)

        # EOS fork adds a custom commit on a different file -> ASB commit on core.txt cherry-picks cleanly
        run(["git", "checkout", "-b", "expressiveos-2.0", fb_r1], cwd=fb_w)
        self.fb_eos_head = commit_files(fb_w, {"eos.txt": "eos-feature\n"}, "EOS custom feature")
        run(["git", "push", str(self.fb_eos_bare), "HEAD:refs/heads/expressiveos-2.0"], cwd=fb_w)

        # AOSP r2 adds an ASB fix AND a merge commit (merge must be ignored by --no-merges)
        run(["git", "checkout", "-b", "asb-r2", fb_r1], cwd=fb_w)
        self.fb_asb_commit = commit_files(fb_w, {"core.txt": "line1\nline2-asb-fix\n"}, "CVE-2026-0001 fix")
        run(["git", "checkout", "-b", "side-branch", fb_r1], cwd=fb_w)
        commit_files(fb_w, {"side.txt": "side-note\n"}, "side commit")
        run(["git", "checkout", "asb-r2"], cwd=fb_w)
        run(["git", "merge", "--no-ff", "side-branch", "-m", "Merge side into r2"], cwd=fb_w)
        fb_r2 = run(["git", "rev-parse", "HEAD"], cwd=fb_w).stdout.strip()
        run(["git", "push", str(self.fb_aosp_bare), "HEAD:refs/tags/android-security-17.0.0_r2"], cwd=fb_w)

        # 2. Existing EOS fork: packages/apps/Settings -> ExpressiveOS/packages_apps_Settings (will CONFLICT)
        self.set_aosp_bare = init_bare(self.aosp_dir / "platform" / "packages" / "apps" / "Settings")
        self.set_eos_bare = init_bare(self.eos_dir / "packages_apps_Settings")
        set_w = self.scratch / "settings"
        set_w.mkdir()
        run(["git", "init", "-b", "main"], cwd=set_w)
        set_r1 = commit_files(set_w, {"Settings.java": "int x = 1;\n"}, "AOSP settings r1")
        run(["git", "push", str(self.set_aosp_bare), "HEAD:refs/tags/android-security-17.0.0_r1"], cwd=set_w)

        run(["git", "checkout", "-b", "expressiveos-2.0", set_r1], cwd=set_w)
        self.set_eos_head = commit_files(set_w, {"Settings.java": "int x = 100; // EOS\n"}, "EOS settings override")
        run(["git", "push", str(self.set_eos_bare), "HEAD:refs/heads/expressiveos-2.0"], cwd=set_w)

        run(["git", "checkout", "-b", "asb-r2", set_r1], cwd=set_w)
        set_r2 = commit_files(set_w, {"Settings.java": "int x = 2; // CVE fix\n"}, "CVE-2026-0002 settings fix")
        run(["git", "push", str(self.set_aosp_bare), "HEAD:refs/tags/android-security-17.0.0_r2"], cwd=set_w)

        # Generate a clean resolution patch for Settings (base=set_eos_head -> resolved)
        run(["git", "checkout", "-b", "resolved-settings", self.set_eos_head], cwd=set_w)
        commit_files(set_w, {"Settings.java": "int x = 102; // EOS + CVE fix\n"}, "Resolve CVE-2026-0002 on EOS Settings")
        self.settings_resolution_patch = run(
            ["git", "format-patch", "--stdout", f"{self.set_eos_head}..HEAD"], cwd=set_w
        ).stdout

        # 3. Unforked AOSP repo: packages/modules/Bluetooth (will trigger NEW_FORK_NEEDED)
        self.bt_aosp_bare = init_bare(self.aosp_dir / "platform" / "packages" / "modules" / "Bluetooth")
        bt_w = self.scratch / "bt"
        bt_w.mkdir()
        run(["git", "init", "-b", "main"], cwd=bt_w)
        self.bt_r1 = commit_files(bt_w, {"bt.c": "int bt = 0;\n"}, "AOSP bt r1")
        run(["git", "push", str(self.bt_aosp_bare), "HEAD:refs/tags/android-security-17.0.0_r1"], cwd=bt_w)
        bt_r2 = commit_files(bt_w, {"bt.c": "int bt = 1; // security fix\n"}, "CVE-2026-0003 bt fix")
        run(["git", "push", str(self.bt_aosp_bare), "HEAD:refs/tags/android-security-17.0.0_r2"], cwd=bt_w)

        # 4. Unchanged AOSP repo: external/zlib (same SHA at r1 and r2, using tag default)
        self.zlib_aosp_bare = init_bare(self.aosp_dir / "platform" / "external" / "zlib")
        z_w = self.scratch / "zlib"
        z_w.mkdir()
        run(["git", "init", "-b", "main"], cwd=z_w)
        self.zlib_r1 = commit_files(z_w, {"zlib.h": "/* v1 */\n"}, "AOSP zlib r1")
        run(["git", "push", str(self.zlib_aosp_bare), "HEAD:refs/tags/android-security-17.0.0_r1"], cwd=z_w)
        run(["git", "push", str(self.zlib_aosp_bare), "HEAD:refs/tags/android-security-17.0.0_r2"], cwd=z_w)

        # 5. vendor/expressiveos repo (carries RELEASE_PLATFORM_SECURITY_PATCH.textproto)
        self.ve_eos_bare = init_bare(self.eos_dir / "vendor_expressiveos")
        ve_w = self.scratch / "ve"
        ve_w.mkdir()
        run(["git", "init", "-b", "expressiveos-2.0"], cwd=ve_w)
        self.ve_head = commit_files(
            ve_w,
            {
                "release/flag_values/cp2a/RELEASE_PLATFORM_SECURITY_PATCH.textproto": (
                    'name: "RELEASE_PLATFORM_SECURITY_PATCH"\n'
                    "value: {\n"
                    '  string_value: "2026-06-05"\n'
                    "}\n"
                )
            },
            "Initial EOS 2.0 SPL 2026-06-05",
        )
        run(["git", "push", str(self.ve_eos_bare), "HEAD:refs/heads/expressiveos-2.0"], cwd=ve_w)

        # Populate AOSP platform/manifest with android-security-17.0.0_r1 and _r2 tags
        am_w = self.scratch / "aosp-mf"
        am_w.mkdir()
        run(["git", "init", "-b", "main"], cwd=am_w)
        aosp_projects_r1 = [
            {"path": "frameworks/base", "name": "platform/frameworks/base", "revision": fb_r1},
            {"path": "packages/apps/Settings", "name": "platform/packages/apps/Settings", "revision": set_r1},
            {"path": "packages/modules/Bluetooth", "name": "platform/packages/modules/Bluetooth", "revision": self.bt_r1},
            {"path": "external/zlib", "name": "platform/external/zlib"},
        ]
        commit_files(
            am_w,
            {"default.xml": make_aosp_manifest(aosp_projects_r1, "refs/tags/android-security-17.0.0_r1")},
            "AOSP security r1",
        )
        run(["git", "push", str(self.aosp_manifest_bare), "HEAD:refs/tags/android-security-17.0.0_r1"], cwd=am_w)

        aosp_projects_r2 = [
            {"path": "frameworks/base", "name": "platform/frameworks/base", "revision": fb_r2},
            {"path": "packages/apps/Settings", "name": "platform/packages/apps/Settings", "revision": set_r2},
            {"path": "packages/modules/Bluetooth", "name": "platform/packages/modules/Bluetooth", "revision": bt_r2},
            {"path": "external/zlib", "name": "platform/external/zlib"},
        ]
        commit_files(
            am_w,
            {"default.xml": make_aosp_manifest(aosp_projects_r2, "refs/tags/android-security-17.0.0_r2")},
            "AOSP security r2",
        )
        run(["git", "push", str(self.aosp_manifest_bare), "HEAD:refs/tags/android-security-17.0.0_r2"], cwd=am_w)

        # Populate ExpressiveOS/manifest on expressiveos-2.0
        self.eos_mf_checkout = self.scratch / "eos-mf"
        self.eos_mf_checkout.mkdir()
        run(["git", "init", "-b", "expressiveos-2.0"], cwd=self.eos_mf_checkout)
        eos_projects = [
            {"path": "frameworks/base", "name": "frameworks_base", "remote": "expressiveos", "revision": self.fb_eos_head},
            {"path": "packages/apps/Settings", "name": "packages_apps_Settings", "remote": "expressiveos", "revision": self.set_eos_head},
            {"path": "packages/modules/Bluetooth", "name": "platform/packages/modules/Bluetooth", "remote": "aosp", "revision": self.bt_r1},
            {"path": "external/zlib", "name": "platform/external/zlib", "remote": "aosp", "revision": self.zlib_r1},
            {"path": "vendor/expressiveos", "name": "vendor_expressiveos", "remote": "expressiveos", "revision": self.ve_head},
        ]
        commit_files(
            self.eos_mf_checkout,
            {
                "default.xml": make_eos_manifest(eos_projects, self.eos_org_url, self.aosp_base_url),
                "last-update.conf": (
                    "UPDATE=2026-06\n"
                    "AOSP_BASE_TAG=android-17.0.0_r1\n"
                    "AOSP_SEC_TAG=android-security-17.0.0_r1\n"
                    "SPL=2026-06-05\n"
                ),
            },
            "Initial EOS 2.0 manifest",
        )
        run(["git", "push", str(self.eos_manifest_bare), "HEAD:refs/heads/expressiveos-2.0"], cwd=self.eos_mf_checkout)

    def manifest_file(self):
        return self.eos_mf_checkout / "default.xml"

    def common_args(self):
        return [
            "--work", str(self.work_dir),
            "--manifest", str(self.manifest_file()),
            "--aosp-manifest-url", f"file://{self.aosp_manifest_bare}",
            "--aosp-base-url", self.aosp_base_url,
            "--eos-org-base", self.eos_org_url,
        ]


class TestUpdateAosp(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="test-update-aosp-")
        self.tmp = Path(self._tmp.name)
        self.world = MockASBWorld(self.tmp)

    def tearDown(self):
        self._tmp.cleanup()

    def run_cli(self, *cli_args, env=None, check=False):
        cmd = [sys.executable, str(UPDATE_SCRIPT), *cli_args]
        return run(cmd, env=env, check=check, timeout=30)

    def test_check_clean_conflict_and_new_fork(self):
        res = self.run_cli("check", *self.world.common_args())
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("[CLEAN] frameworks/base", res.stdout)
        self.assertIn("[CONFLICTS] packages/apps/Settings", res.stdout)
        self.assertIn("[NEW_FORK_NEEDED] packages/modules/Bluetooth", res.stdout)
        # Unchanged external/zlib must be skipped cleanly
        self.assertNotIn("external/zlib", res.stdout)
        self.assertIn("UPDATE_CHECK=OK (clean=1, conflicts=1, new_forks=1, problems=0)", res.stdout)

    def test_plan_conflict_then_resolution_patch_and_spl_bump(self):
        updates_dir = self.tmp / "updates"
        upd_2026_07 = updates_dir / "2026-07"
        upd_2026_07.mkdir(parents=True)
        (upd_2026_07 / "update.conf").write_text(
            "AOSP_SEC_TAG=android-security-17.0.0_r1\n"
            "TARGET_SEC_TAG=android-security-17.0.0_r2\n"
            "TARGET_SPL=2026-07-05\n",
            encoding="utf-8",
        )

        # Without resolution patch -> CONFLICTS (exit 2)
        res_conf = self.run_cli(
            "plan", "2026-07",
            *self.world.common_args(),
            "--updates-dir", str(updates_dir),
        )
        self.assertEqual(res_conf.returncode, 2, res_conf.stdout + res_conf.stderr)
        self.assertIn("UPDATE_PLAN=CONFLICTS", res_conf.stdout)
        self.assertIn("conflicts=1", res_conf.stdout)

        # Provide resolutions/packages_apps_Settings.patch -> READY (exit 0)
        res_dir = upd_2026_07 / "resolutions"
        res_dir.mkdir(parents=True)
        (res_dir / "packages_apps_Settings.patch").write_text(
            self.world.settings_resolution_patch, encoding="utf-8"
        )

        res_ok = self.run_cli(
            "plan", "2026-07",
            *self.world.common_args(),
            "--updates-dir", str(updates_dir),
        )
        self.assertEqual(res_ok.returncode, 0, res_ok.stdout + res_ok.stderr)
        self.assertIn("UPDATE_PLAN=READY", res_ok.stdout)
        self.assertIn("spl=2026-07-05", res_ok.stdout)

        # Inspect generated plan.json, default.xml, last-update.conf, and SPL textproto
        plan_dir = self.world.work_dir / "2026-07"
        plan = json.loads((plan_dir / "plan.json").read_text(encoding="utf-8"))
        self.assertEqual(plan["conflicts"], [])
        self.assertEqual(plan["new_repos"], ["packages_modules_Bluetooth"])
        self.assertEqual(plan["target_spl"], "2026-07-05")
        self.assertIn("vendor/expressiveos", plan["updates"])
        self.assertIn("frameworks/base", plan["updates"])
        self.assertIn("packages/apps/Settings", plan["updates"])
        self.assertIn("packages/modules/Bluetooth", plan["updates"])

        spl_file = Path(plan["updates"]["vendor/expressiveos"]["scratch_dir"]) / (
            "release/flag_values/cp2a/RELEASE_PLATFORM_SECURITY_PATCH.textproto"
        )
        self.assertIn('string_value: "2026-07-05"', spl_file.read_text(encoding="utf-8"))

        # Lint generated manifest + SPL file must pass, and last-update.conf must preserve AOSP_BASE_TAG
        last_upd_txt = (plan_dir / "last-update.conf").read_text(encoding="utf-8")
        self.assertIn("AOSP_BASE_TAG=android-17.0.0_r1", last_upd_txt)
        lint_res = self.run_cli("lint", str(plan_dir / "default.xml"), "--spl-file", str(spl_file))
        self.assertEqual(lint_res.returncode, 0, lint_res.stdout + lint_res.stderr)
        self.assertIn("MANIFEST_LINT=OK", lint_res.stdout)

    def test_create_repos_push_verify_and_non_ff_rejection(self):
        # Stage a ready plan with resolution patch
        updates_dir = self.tmp / "updates"
        res_dir = updates_dir / "2026-07" / "resolutions"
        res_dir.mkdir(parents=True)
        (updates_dir / "2026-07" / "update.conf").write_text(
            "AOSP_SEC_TAG=android-security-17.0.0_r1\n"
            "TARGET_SEC_TAG=android-security-17.0.0_r2\n"
            "TARGET_SPL=2026-07-05\n",
            encoding="utf-8",
        )
        (res_dir / "packages_apps_Settings.patch").write_text(
            self.world.settings_resolution_patch, encoding="utf-8"
        )
        res_plan = self.run_cli(
            "plan", "2026-07",
            *self.world.common_args(),
            "--branch", "expressiveos-2.0",
            "--updates-dir", str(updates_dir),
        )
        self.assertEqual(res_plan.returncode, 0, res_plan.stderr)

        # Build mock gh binary that initializes bare repos under self.world.eos_dir on POST
        gh_log = self.tmp / "gh.log"
        mock_gh = self.tmp / "mock-gh"
        mock_gh.write_text(
            f"""#!/usr/bin/env python3
import os, subprocess, sys
from pathlib import Path

args = sys.argv[1:]
with open({str(gh_log)!r}, "a", encoding="utf-8") as fh:
    fh.write(" ".join(args) + "\\n")

eos_dir = Path({str(self.world.eos_dir)!r})
if len(args) >= 4 and args[0] == "api" and args[1] == "-X":
    method = args[2]
    endpoint = args[3]
    if method == "GET" and endpoint.startswith("repos/"):
        repo = endpoint.split("/")[-1]
        sys.exit(0 if (eos_dir / repo).exists() else 1)
    if method == "POST" and endpoint.endswith("/repos"):
        name = None
        for i, a in enumerate(args):
            if a == "-f" and i + 1 < len(args) and args[i + 1].startswith("name="):
                name = args[i + 1].split("=", 1)[1]
        if not name:
            sys.exit(1)
        bare = eos_dir / name
        bare.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", "--bare", str(bare)], check=True, timeout=15)
        subprocess.run(["git", "--git-dir", str(bare), "config", "uploadpack.allowAnySHA1InWant", "true"], check=True, timeout=15)
        sys.exit(0)
sys.exit(1)
""",
            encoding="utf-8",
        )
        mock_gh.chmod(mock_gh.stat().st_mode | stat.S_IXUSR)
        gh_env = {"EOS_GH_BIN": str(mock_gh)}

        # Dry-run create-repos must NOT create bare repo yet
        res_dry = self.run_cli("create-repos", "2026-07", "--work", str(self.world.work_dir), "--dry-run", env=gh_env)
        self.assertEqual(res_dry.returncode, 0, res_dry.stderr)
        self.assertIn("CREATE_REPOS=OK (created=1, existing=0, dry_run=True)", res_dry.stdout)
        self.assertFalse((self.world.eos_dir / "packages_modules_Bluetooth").exists())

        # Real create-repos creates packages_modules_Bluetooth
        res_cr = self.run_cli("create-repos", "2026-07", "--work", str(self.world.work_dir), env=gh_env)
        self.assertEqual(res_cr.returncode, 0, res_cr.stderr)
        self.assertIn("CREATE_REPOS=OK (created=1, existing=0, dry_run=False)", res_cr.stdout)
        self.assertTrue((self.world.eos_dir / "packages_modules_Bluetooth").exists())

        # Second call must be idempotent (existing=1, created=0)
        res_cr2 = self.run_cli("create-repos", "2026-07", "--work", str(self.world.work_dir), env=gh_env)
        self.assertEqual(res_cr2.returncode, 0, res_cr2.stderr)
        self.assertIn("CREATE_REPOS=OK (created=0, existing=1, dry_run=False)", res_cr2.stdout)

        # Push forks + manifest PR branch update/2026-07
        res_push = self.run_cli(
            "push", "2026-07",
            "--work", str(self.world.work_dir),
            "--eos-org-base", self.world.eos_org_url,
            "--manifest-url", f"file://{self.world.eos_manifest_bare}",
        )
        self.assertEqual(res_push.returncode, 0, res_push.stdout + res_push.stderr)
        self.assertIn("UPDATE_PUSH=OK (forks_pushed=4, manifest_branch=update/2026-07)", res_push.stdout)

        # Idempotent re-run when update/2026-07 already exists on manifest remote must succeed (0 forks pushed)
        res_push_rerun = self.run_cli(
            "push", "2026-07",
            "--work", str(self.world.work_dir),
            "--eos-org-base", self.world.eos_org_url,
            "--manifest-url", f"file://{self.world.eos_manifest_bare}",
        )
        self.assertEqual(res_push_rerun.returncode, 0, res_push_rerun.stdout + res_push_rerun.stderr)
        self.assertIn("already pushed: manifest @ update/2026-07", res_push_rerun.stdout)
        self.assertIn("UPDATE_PUSH=OK (forks_pushed=0, manifest_branch=update/2026-07)", res_push_rerun.stdout)

        # HTTPS GitHub push without EOS_PUSH_TOKEN must fail fast before any git network call
        res_no_tok = self.run_cli(
            "push", "2026-07",
            "--work", str(self.world.work_dir),
            "--eos-org-base", "https://github.com/ExpressiveOS",
            "--manifest-url", "https://github.com/ExpressiveOS/manifest",
            env={"EOS_PUSH_TOKEN": ""},
        )
        self.assertNotEqual(res_no_tok.returncode, 0)
        self.assertIn("EOS_PUSH_TOKEN is empty", res_no_tok.stderr)
        self.assertIn("UPDATE_PUSH=FAILED", res_no_tok.stdout)

        # Non-GitHub HTTPS remote must be refused so EOS_PUSH_TOKEN never leaks off github.com
        res_off_gh = self.run_cli(
            "push", "2026-07",
            "--work", str(self.world.work_dir),
            "--eos-org-base", "https://evil.example/ExpressiveOS",
            "--manifest-url", "https://evil.example/ExpressiveOS/manifest",
            env={"EOS_PUSH_TOKEN": "github_pat_dummy"},
        )
        self.assertNotEqual(res_off_gh.returncode, 0)
        self.assertIn("not on GitHub", res_off_gh.stderr)
        self.assertIn("UPDATE_PUSH=FAILED", res_off_gh.stdout)

        # Verify BEFORE merging update/2026-07 into expressiveos-2.0 -> DIFFERS
        res_ver_pre = self.run_cli(
            "verify", "2026-07",
            "--work", str(self.world.work_dir),
            "--eos-org-base", self.world.eos_org_url,
            "--manifest-url", f"file://{self.world.eos_manifest_bare}",
        )
        self.assertEqual(res_ver_pre.returncode, 1)
        self.assertIn("UPDATE_VERIFY=DIFFERS", res_ver_pre.stdout)

        # Simulate PR merge: fast-forward expressiveos-2.0 to update/2026-07 in manifest repo
        pr_sha = run(
            ["git", "--git-dir", str(self.world.eos_manifest_bare), "rev-parse", "refs/heads/update/2026-07"]
        ).stdout.strip()
        run(
            ["git", "--git-dir", str(self.world.eos_manifest_bare), "update-ref", "refs/heads/expressiveos-2.0", pr_sha]
        )

        # Verify AFTER merge -> OK
        res_ver_ok = self.run_cli(
            "verify", "2026-07",
            "--work", str(self.world.work_dir),
            "--eos-org-base", self.world.eos_org_url,
            "--manifest-url", f"file://{self.world.eos_manifest_bare}",
        )
        self.assertEqual(res_ver_ok.returncode, 0, res_ver_ok.stdout + res_ver_ok.stderr)
        self.assertIn("UPDATE_VERIFY=OK (verified=4, spl=2026-07-05)", res_ver_ok.stdout)

        # Non-fast-forward protection: advance remote frameworks_base with a divergent commit and verify push refuses
        div_w = self.tmp / "divergent"
        div_w.mkdir()
        run(["git", "clone", "-b", "expressiveos-2.0", str(self.world.fb_eos_bare), str(div_w)])
        commit_files(div_w, {"divergent.txt": "surprise\n"}, "Divergent remote commit")
        run(["git", "push", "origin", "expressiveos-2.0"], cwd=div_w)

        res_nff = self.run_cli(
            "push", "2026-07",
            "--work", str(self.world.work_dir),
            "--eos-org-base", self.world.eos_org_url,
            "--manifest-url", f"file://{self.world.eos_manifest_bare}",
        )
        self.assertNotEqual(res_nff.returncode, 0)
        self.assertIn("refusing non-fast-forward push", res_nff.stderr)
        self.assertIn("UPDATE_PUSH=FAILED", res_nff.stdout)

    def test_lint_strict_rules(self):
        good_xml = self.tmp / "good.xml"
        sha = "a" * 40
        good_xml.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            "<manifest>\n"
            '  <remote name="aosp" fetch="https://android.googlesource.com/" />\n'
            '  <remote name="expressiveos" fetch="https://github.com/ExpressiveOS" />\n'
            '  <default remote="aosp" revision="expressiveos-2.0" />\n'
            f'  <project path="frameworks/base" name="frameworks_base" remote="expressiveos" revision="{sha}" />\n'
            f'  <project path="external/zlib" name="platform/external/zlib" remote="aosp" revision="{sha}" />\n'
            "</manifest>\n",
            encoding="utf-8",
        )
        good_spl = self.tmp / "good_spl.textproto"
        good_spl.write_text('name: "RELEASE_PLATFORM_SECURITY_PATCH"\nvalue: {\n  string_value: "2026-07-05"\n}\n')
        res = self.run_cli("lint", str(good_xml), "--spl-file", str(good_spl))
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("MANIFEST_LINT=OK", res.stdout)

        # Reject forbidden include, lineage remote, LineageOS/ name, lineage-sdk path, non-40-hex rev, duplicate path, bad SPL
        bad_xml = self.tmp / "bad.xml"
        bad_xml.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            "<manifest>\n"
            '  <remote name="lineage" fetch="https://github.com/LineageOS" />\n'
            '  <remote name="github" fetch="https://github.com/" />\n'
            '  <include name="snippets/lineage.xml" />\n'
            '  <project path="lineage-sdk" name="LineageOS/android_lineage-sdk" remote="lineage" revision="lineage-23.2" />\n'
            f'  <project path="dup/path" name="repo_a" remote="github" revision="{sha}" />\n'
            f'  <project path="dup/path" name="repo_b" remote="github" revision="not-a-sha" />\n'
            "</manifest>\n",
            encoding="utf-8",
        )
        bad_spl = self.tmp / "bad_spl.textproto"
        bad_spl.write_text('string_value: "not-a-date"\n')
        res_bad = self.run_cli("lint", str(bad_xml), "--spl-file", str(bad_spl))
        self.assertEqual(res_bad.returncode, 1)
        self.assertIn("MANIFEST_LINT=FAIL", res_bad.stdout)
        for expected in (
            "forbidden manifest element <include>",
            "forbidden remote name 'lineage'",
            "forbidden remote name 'github'",
            "references LineageOS",
            "forbidden LineageOS project path 'lineage-sdk'",
            "is not a 40-hex commit SHA",
            "duplicate project path 'dup/path'",
            "RELEASE_PLATFORM_SECURITY_PATCH",
        ):
            self.assertIn(expected, res_bad.stderr)

        # Remote ref lint: default branch, explicit branch, pull/<n> ref, and bad ref rejection
        mf_url = f"file://{self.world.eos_manifest_bare}"
        res_def = self.run_cli("lint", "--manifest-url", mf_url, "--work", str(self.tmp / "lint-work"))
        self.assertEqual(res_def.returncode, 0, res_def.stdout + res_def.stderr)
        self.assertIn("MANIFEST_LINT=OK", res_def.stdout)

        run(["git", "push", str(self.world.eos_manifest_bare), "HEAD:refs/pull/42/head"], cwd=self.world.eos_mf_checkout)
        res_pr = self.run_cli("lint", "pull/42", "--manifest-url", mf_url, "--work", str(self.tmp / "lint-work"))
        self.assertEqual(res_pr.returncode, 0, res_pr.stdout + res_pr.stderr)
        self.assertIn("MANIFEST_LINT=OK", res_pr.stdout)

        res_bad_ref = self.run_cli("lint", "bad..ref", "--manifest-url", mf_url, "--work", str(self.tmp / "lint-work"))
        self.assertNotEqual(res_bad_ref.returncode, 0)
        self.assertIn("MANIFEST_LINT=FAIL", res_bad_ref.stdout)

        # QPR tag notice when a new android-17.0.0_r2 tag appears beyond AOSP_BASE_TAG
        run(["git", "--git-dir", str(self.world.aosp_manifest_bare), "tag", "android-17.0.0_r2", "refs/tags/android-security-17.0.0_r2"])
        res_qpr = self.run_cli("check", *self.world.common_args())
        self.assertEqual(res_qpr.returncode, 0, res_qpr.stderr)
        self.assertIn("NOTE: new AOSP release tag(s) beyond AOSP_BASE_TAG (android-17.0.0_r1): android-17.0.0_r2", res_qpr.stdout)

    def test_token_subcommand_and_update_sh_wrapper(self):
        # Empty token fails fast via update.sh token (matching kodiak-build.yml expressiveos-update)
        empty_proc = run(
            ["bash", str(UPDATE_SH), "token"],
            env={"EOS_PUSH_TOKEN": "", "EOS_UPDATE_WORK": str(self.tmp / "upd-work")},
            check=False,
            timeout=15,
        )
        self.assertNotEqual(empty_proc.returncode, 0)
        self.assertIn("EOS_PUSH_TOKEN is empty", empty_proc.stderr)
        self.assertIn("TOKEN_CHECK=FAIL", empty_proc.stdout)

        # Mock receive-pack server verifying Basic x-access-token:<token>
        expected_auth = "Basic " + base64.b64encode(b"x-access-token:github_pat_test123").decode("ascii")
        deny_repo = {"name": None}

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):
                return

            def do_GET(self):
                auth = self.headers.get("Authorization")
                if not auth:
                    self.send_response(401)
                    self.end_headers()
                    return
                if auth != expected_auth:
                    self.send_response(401)
                    self.end_headers()
                    return
                if deny_repo["name"] and f"/{deny_repo['name']}.git/" in self.path:
                    self.send_response(403)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/x-git-receive-pack-advertisement")
                self.end_headers()
                self.wfile.write(b"001f# service=git-receive-pack\n0000")

        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        srv.daemon_threads = True
        t = threading.Thread(target=srv.serve_forever, daemon=True)
        t.start()
        try:
            base_url = f"http://127.0.0.1:{srv.server_port}/ExpressiveOS"
            ok_res = self.run_cli(
                "token",
                "--work", str(self.tmp / "tok-work"),
                "--manifest", str(self.world.manifest_file()),
                "--eos-org-base", base_url,
                "--manifest-url", f"{base_url}/manifest",
                env={
                    "EOS_PUSH_TOKEN": "github_pat_test123",
                    "EOS_ALLOW_LOCAL_TOKEN_TEST": "1",
                },
            )
            self.assertEqual(ok_res.returncode, 0, ok_res.stdout + ok_res.stderr)
            self.assertIn("TOKEN_CHECK=OK", ok_res.stdout)

            # 403 on one repo fails with TOKEN_CHECK=FAIL
            deny_repo["name"] = "frameworks_base"
            bad_res = self.run_cli(
                "token",
                "--work", str(self.tmp / "tok-work"),
                "--manifest", str(self.world.manifest_file()),
                "--eos-org-base", base_url,
                "--manifest-url", f"{base_url}/manifest",
                env={
                    "EOS_PUSH_TOKEN": "github_pat_test123",
                    "EOS_ALLOW_LOCAL_TOKEN_TEST": "1",
                },
            )
            self.assertEqual(bad_res.returncode, 1)
            self.assertIn("no push access", bad_res.stderr)
            self.assertIn("TOKEN_CHECK=FAIL", bad_res.stdout)
        finally:
            srv.shutdown()
            srv.server_close()

    def test_shallow_local_dir_and_deterministic_replan_after_partial_push(self):
        # Add a clone-depth="1" AOSP repo whose base_rev on android-17.0.0_r1 is 2 commits
        # ahead of the merge-base with the diverged android-security-17.0.0_r* branch.
        wv_aosp_bare = init_bare(self.world.aosp_dir / "platform" / "external" / "chromium-webview")
        wv_w = self.world.scratch / "wv"
        wv_w.mkdir()
        run(["git", "init", "-b", "main"], cwd=wv_w)
        commit_files(wv_w, {"wv.txt": "v0\n"}, "wv base")
        run(["git", "checkout", "-b", "r1-branch"], cwd=wv_w)
        commit_files(wv_w, {"r1_a.txt": "a\n"}, "r1 commit 1")
        wv_base = commit_files(wv_w, {"r1_b.txt": "b\n"}, "r1 commit 2")
        run(["git", "push", str(wv_aosp_bare), "HEAD:refs/tags/android-17.0.0_r1"], cwd=wv_w)

        run(["git", "checkout", "-b", "sec-branch", "main"], cwd=wv_w)
        wv_sec1 = commit_files(wv_w, {"sec1.txt": "s1\n"}, "sec r1")
        run(["git", "push", str(wv_aosp_bare), "HEAD:refs/tags/android-security-17.0.0_r1"], cwd=wv_w)
        wv_sec2 = commit_files(wv_w, {"wv.txt": "v0-patched\n"}, "CVE-2026-9999 webview fix")
        run(["git", "push", str(wv_aosp_bare), "HEAD:refs/tags/android-security-17.0.0_r2"], cwd=wv_w)

        # Update AOSP manifests at r1 and r2 to include external/chromium-webview
        aosp_mf_w = self.world.scratch / "aosp-mf-wv"
        run(["git", "clone", str(self.world.aosp_manifest_bare), str(aosp_mf_w)])
        for tag, wv_rev in (("android-security-17.0.0_r1", wv_sec1), ("android-security-17.0.0_r2", wv_sec2)):
            run(["git", "checkout", "-B", f"edit-{tag}", f"refs/tags/{tag}"], cwd=aosp_mf_w)
            xml_txt = (aosp_mf_w / "default.xml").read_text(encoding="utf-8").replace(
                "</manifest>",
                f'  <project path="external/chromium-webview" name="platform/external/chromium-webview" revision="{wv_rev}" />\n</manifest>',
            )
            commit_files(aosp_mf_w, {"default.xml": xml_txt}, f"add wv to {tag}")
            run(["git", "tag", "-f", tag], cwd=aosp_mf_w)
            run(["git", "push", "-f", "origin", f"refs/tags/{tag}:refs/tags/{tag}"], cwd=aosp_mf_w)

        # Add external/chromium-webview with clone-depth="1" to EOS manifest
        mf_path = self.world.manifest_file()
        mf_xml = mf_path.read_text(encoding="utf-8").replace(
            "</manifest>",
            f'  <project path="external/chromium-webview" name="platform/external/chromium-webview" remote="aosp" revision="{wv_base}" clone-depth="1" />\n</manifest>',
        )
        commit_files(self.world.eos_mf_checkout, {"default.xml": mf_xml}, "add shallow chromium-webview")
        run(["git", "push", str(self.world.eos_manifest_bare), "HEAD:refs/heads/expressiveos-2.0"], cwd=self.world.eos_mf_checkout)

        # Populate a --top tree containing a shallow (depth=1) checkout at external/chromium-webview
        fake_top = self.tmp / "fake-top"
        shallow_wv = fake_top / "external" / "chromium-webview"
        shallow_wv.mkdir(parents=True)
        run(["git", "init"], cwd=shallow_wv)
        run(["git", "fetch", "--depth=1", f"file://{wv_aosp_bare}", wv_base], cwd=shallow_wv)
        run(["git", "checkout", "--detach", "FETCH_HEAD"], cwd=shallow_wv)
        self.assertEqual(
            run(["git", "rev-parse", "--is-shallow-repository"], cwd=shallow_wv).stdout.strip(),
            "true",
        )

        # Configure update.conf WITHOUT AOSP_SEC_TAG so plan exercises last-update.conf fallback
        upd_root = self.tmp / "updates2"
        u07 = upd_root / "2026-07"
        (u07 / "resolutions").mkdir(parents=True)
        (u07 / "update.conf").write_text(
            "TARGET_SEC_TAG=android-security-17.0.0_r2\nTARGET_SPL=2026-07-05\n",
            encoding="utf-8",
        )
        (u07 / "resolutions" / "packages_apps_Settings.patch").write_text(
            self.world.settings_resolution_patch, encoding="utf-8"
        )

        plan1 = self.run_cli(
            "plan", "2026-07",
            *self.world.common_args(),
            "--top", str(fake_top),
            "--updates-dir", str(upd_root),
        )
        self.assertEqual(plan1.returncode, 0, plan1.stdout + plan1.stderr)
        self.assertIn("UPDATE_PLAN=READY", plan1.stdout)
        p1_doc = json.loads((self.world.work_dir / "2026-07" / "plan.json").read_text(encoding="utf-8"))
        out_xml_txt = Path(p1_doc["manifest_out"]).read_text(encoding="utf-8")
        self.assertNotIn('clone-depth="1"', out_xml_txt)

        # Simulate partial push: create external_chromium-webview (with strict receive.fsckObjects=true)
        # but NOT packages_modules_Bluetooth yet, so push advances external_chromium-webview +
        # frameworks_base + packages_apps_Settings and fails when hitting missing Bluetooth.
        wv_eos = init_bare(self.world.eos_dir / "external_chromium-webview")
        run(["git", "--git-dir", str(wv_eos), "config", "receive.fsckObjects", "true"])
        partial_push = self.run_cli(
            "push", "2026-07",
            "--work", str(self.world.work_dir),
            "--eos-org-base", self.world.eos_org_url,
            "--manifest-url", f"file://{self.world.eos_manifest_bare}",
        )
        self.assertNotEqual(partial_push.returncode, 0)
        self.assertIn("pushed: external_chromium-webview -> expressiveos-2.0", partial_push.stdout)
        self.assertIn("pushed: frameworks_base -> expressiveos-2.0", partial_push.stdout)

        # Re-run plan (at a later wall-clock moment) and verify all planned commit SHAs are 100% deterministic!
        plan2 = self.run_cli(
            "plan", "2026-07",
            *self.world.common_args(),
            "--top", str(fake_top),
            "--updates-dir", str(upd_root),
        )
        self.assertEqual(plan2.returncode, 0, plan2.stdout + plan2.stderr)
        p2_doc = json.loads((self.world.work_dir / "2026-07" / "plan.json").read_text(encoding="utf-8"))
        for repo_path, upd1 in p1_doc["updates"].items():
            self.assertEqual(upd1["new_head"], p2_doc["updates"][repo_path]["new_head"], repo_path)

        # Create remaining repo with strict receive.fsckObjects=true and complete push!
        bt_eos = init_bare(self.world.eos_dir / "packages_modules_Bluetooth")
        run(["git", "--git-dir", str(bt_eos), "config", "receive.fsckObjects", "true"])
        full_push = self.run_cli(
            "push", "2026-07",
            "--work", str(self.world.work_dir),
            "--eos-org-base", self.world.eos_org_url,
            "--manifest-url", f"file://{self.world.eos_manifest_bare}",
        )
        self.assertEqual(full_push.returncode, 0, full_push.stdout + full_push.stderr)
        self.assertIn("already pushed: external_chromium-webview", full_push.stdout)
        self.assertIn("already pushed: frameworks_base", full_push.stdout)
        self.assertIn("pushed: packages_modules_Bluetooth -> expressiveos-2.0", full_push.stdout)
        self.assertIn("UPDATE_PUSH=OK", full_push.stdout)

    def test_multi_org_remotes_plan_create_token_push_verify(self):
        """Multi-org Option B flow: NEW_FORK_NEEDED routes to expressiveos-asb with topics and per-org tokens."""
        asb_dir = self.tmp / "eos-asb"
        dev_dir = self.tmp / "eos-devices"
        asb_dir.mkdir(parents=True)
        dev_dir.mkdir(parents=True)
        asb_url = f"file://{asb_dir}"
        dev_url = f"file://{dev_dir}"

        # Rewrite world manifest to declare expressiveos-asb and expressiveos-devices remotes
        mf_path = self.world.manifest_file()
        mf_xml = mf_path.read_text(encoding="utf-8").replace(
            f'  <remote name="expressiveos" fetch="{self.world.eos_org_url}" />\n',
            f'  <remote name="expressiveos" fetch="{self.world.eos_org_url}" />\n'
            f'  <remote name="expressiveos-asb" fetch="{asb_url}" />\n'
            f'  <remote name="expressiveos-devices" fetch="{dev_url}" />\n',
        )
        commit_files(self.world.eos_mf_checkout, {"default.xml": mf_xml}, "enable multi-org remotes")
        run(["git", "push", str(self.world.eos_manifest_bare), "HEAD:refs/heads/expressiveos-2.0"], cwd=self.world.eos_mf_checkout)

        # Lint must accept multi-org remotes and reject undeclared remote references
        lint_ok = self.run_cli("lint", str(mf_path))
        self.assertEqual(lint_ok.returncode, 0, lint_ok.stdout + lint_ok.stderr)
        self.assertIn("MANIFEST_LINT=OK", lint_ok.stdout)

        bad_undecl = self.tmp / "undecl.xml"
        bad_undecl.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            "<manifest>\n"
            '  <remote name="aosp" fetch="https://android.googlesource.com" />\n'
            '  <default remote="aosp" revision="expressiveos-2.0" />\n'
            f'  <project path="external/aac" name="external_aac" remote="expressiveos-asb" revision="{"a" * 40}" />\n'
            "</manifest>\n",
            encoding="utf-8",
        )
        lint_bad = self.run_cli("lint", str(bad_undecl))
        self.assertEqual(lint_bad.returncode, 1)
        self.assertIn("undeclared remote 'expressiveos-asb'", lint_bad.stderr)

        # Stage update with Settings resolution patch -> Bluetooth NEW_FORK routes to expressiveos-asb
        updates_dir = self.tmp / "updates-multi"
        res_dir = updates_dir / "2026-08" / "resolutions"
        res_dir.mkdir(parents=True)
        (updates_dir / "2026-08" / "update.conf").write_text(
            "AOSP_SEC_TAG=android-security-17.0.0_r1\n"
            "TARGET_SEC_TAG=android-security-17.0.0_r2\n"
            "TARGET_SPL=2026-08-05\n",
            encoding="utf-8",
        )
        (res_dir / "packages_apps_Settings.patch").write_text(
            self.world.settings_resolution_patch, encoding="utf-8"
        )
        res_plan = self.run_cli(
            "plan", "2026-08",
            *self.world.common_args(),
            "--eos-asb-org-base", asb_url,
            "--eos-devices-org-base", dev_url,
            "--updates-dir", str(updates_dir),
        )
        self.assertEqual(res_plan.returncode, 0, res_plan.stdout + res_plan.stderr)
        plan_doc = json.loads((self.world.work_dir / "2026-08" / "plan.json").read_text(encoding="utf-8"))
        self.assertEqual(plan_doc["new_fork_remote"], "expressiveos-asb")
        self.assertEqual(plan_doc["updates"]["packages/modules/Bluetooth"]["remote"], "expressiveos-asb")
        self.assertEqual(plan_doc["updates"]["packages/modules/Bluetooth"]["org"], "ExpressiveOS-ASB")
        self.assertEqual(plan_doc["updates"]["frameworks/base"]["remote"], "expressiveos")
        out_xml = Path(plan_doc["manifest_out"]).read_text(encoding="utf-8")
        self.assertIn('name="packages_modules_Bluetooth"', out_xml)
        self.assertIn('remote="expressiveos-asb"', out_xml)

        # Mock gh verifying POST targets orgs/ExpressiveOS-ASB/repos AND PUT topics runs
        topic_log = self.tmp / "topics.json"
        mock_gh = self.tmp / "mock-gh-multi"
        mock_gh.write_text(
            f"""#!/usr/bin/env python3
import json, subprocess, sys
from pathlib import Path

args = sys.argv[1:]
asb_dir = Path({str(asb_dir)!r})
topic_log = Path({str(topic_log)!r})
if len(args) >= 4 and args[0] == "api" and args[1] == "-X":
    method, endpoint = args[2], args[3]
    if method == "GET" and endpoint.startswith("repos/ExpressiveOS-ASB/"):
        repo = endpoint.split("/")[-1]
        sys.exit(0 if (asb_dir / repo).exists() else 1)
    if method == "POST" and endpoint == "orgs/ExpressiveOS-ASB/repos":
        name = None
        for i, a in enumerate(args):
            if a == "-f" and i + 1 < len(args) and args[i + 1].startswith("name="):
                name = args[i + 1].split("=", 1)[1]
        bare = asb_dir / name
        bare.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", "--bare", str(bare)], check=True, timeout=15)
        subprocess.run(["git", "--git-dir", str(bare), "config", "uploadpack.allowAnySHA1InWant", "true"], check=True, timeout=15)
        sys.exit(0)
    if method == "PUT" and endpoint == "repos/ExpressiveOS-ASB/packages_modules_Bluetooth/topics":
        topic_log.write_text(sys.stdin.read(), encoding="utf-8")
        sys.exit(0)
sys.exit(1)
""",
            encoding="utf-8",
        )
        mock_gh.chmod(mock_gh.stat().st_mode | stat.S_IXUSR)
        res_cr = self.run_cli(
            "create-repos", "2026-08",
            "--work", str(self.world.work_dir),
            env={"EOS_GH_BIN": str(mock_gh)},
        )
        self.assertEqual(res_cr.returncode, 0, res_cr.stdout + res_cr.stderr)
        self.assertTrue((asb_dir / "packages_modules_Bluetooth").exists())
        topics_sent = json.loads(topic_log.read_text(encoding="utf-8"))["names"]
        self.assertEqual(topics_sent, ["expressiveos", "eos-2-0", "fn-modules", "eos-asb-patch"])

        # Push & verify across both orgs
        res_push = self.run_cli(
            "push", "2026-08",
            "--work", str(self.world.work_dir),
            "--eos-org-base", self.world.eos_org_url,
            "--eos-asb-org-base", asb_url,
            "--manifest-url", f"file://{self.world.eos_manifest_bare}",
        )
        self.assertEqual(res_push.returncode, 0, res_push.stdout + res_push.stderr)
        self.assertIn("UPDATE_PUSH=OK (forks_pushed=4, manifest_branch=update/2026-08)", res_push.stdout)

        # Merge manifest PR & verify
        pr_sha = run(
            ["git", "--git-dir", str(self.world.eos_manifest_bare), "rev-parse", "refs/heads/update/2026-08"]
        ).stdout.strip()
        run(
            ["git", "--git-dir", str(self.world.eos_manifest_bare), "update-ref", "refs/heads/expressiveos-2.0", pr_sha]
        )
        res_ver = self.run_cli(
            "verify", "2026-08",
            "--work", str(self.world.work_dir),
            "--eos-org-base", self.world.eos_org_url,
            "--eos-asb-org-base", asb_url,
            "--manifest-url", f"file://{self.world.eos_manifest_bare}",
        )
        self.assertEqual(res_ver.returncode, 0, res_ver.stdout + res_ver.stderr)
        self.assertIn("UPDATE_VERIFY=OK (verified=4, spl=2026-08-05)", res_ver.stdout)

        # Per-org token check: ExpressiveOS gets EOS_PUSH_TOKEN, ExpressiveOS-ASB gets EOS_ASB_PUSH_TOKEN
        auth_main = "Basic " + base64.b64encode(b"x-access-token:pat_main").decode("ascii")
        auth_asb = "Basic " + base64.b64encode(b"x-access-token:pat_asb").decode("ascii")

        class MultiOrgHandler(http.server.BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):
                return

            def do_GET(self):
                auth = self.headers.get("Authorization")
                if not auth:
                    self.send_response(401)
                    self.end_headers()
                    return
                expected = auth_asb if self.path.startswith("/ExpressiveOS-ASB/") else auth_main
                if auth != expected:
                    self.send_response(403)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/x-git-receive-pack-advertisement")
                self.end_headers()
                self.wfile.write(b"001f# service=git-receive-pack\n0000")

        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), MultiOrgHandler)
        srv.daemon_threads = True
        t = threading.Thread(target=srv.serve_forever, daemon=True)
        t.start()
        try:
            res_tok = self.run_cli(
                "token",
                "--work", str(self.tmp / "tok-multi"),
                "--manifest", str(plan_doc["manifest_out"]),
                "--eos-org-base", f"http://127.0.0.1:{srv.server_port}/ExpressiveOS",
                "--eos-asb-org-base", f"http://127.0.0.1:{srv.server_port}/ExpressiveOS-ASB",
                "--manifest-url", f"http://127.0.0.1:{srv.server_port}/ExpressiveOS/manifest",
                env={
                    "EOS_PUSH_TOKEN": "pat_main",
                    "EOS_ASB_PUSH_TOKEN": "pat_asb",
                    "EOS_ALLOW_LOCAL_TOKEN_TEST": "1",
                },
            )
            self.assertEqual(res_tok.returncode, 0, res_tok.stdout + res_tok.stderr)
            self.assertIn("TOKEN_CHECK=OK", res_tok.stdout)
        finally:
            srv.shutdown()
            srv.server_close()


if __name__ == "__main__":
    unittest.main()
