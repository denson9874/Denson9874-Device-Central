#!/usr/bin/env python3
"""Offline unit tests for tools/brand-check.py (EOS 2.0 Option B keybox & branding checks)."""
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile

TOOLS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND_CHECK = os.path.join(TOOLS_DIR, "brand-check.py")
LEGACY_URL = b"https://ota-mirror.daryldenson-apps.workers.dev/expressiveos/keybox.xml"
REPO_URL = b"https://keybox.kowx712.cc/"


def _write_zip(path, entries):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with zipfile.ZipFile(path, "w") as zf:
        for name, data in entries.items():
            zf.writestr(name, data)


class BrandCheckOptionBTest(unittest.TestCase):
    def _make_out(
        self,
        root,
        *,
        services_dex=b"EosIntegrityService MANUAL_IMPORT_REQUIRED",
        settings_dex=b"TrickyStore " + REPO_URL,
        arsc=b"ExpressiveOS Settings",
        build_prop="ro.expressiveos.device=kodiak\nro.build.type=user\n",
        tombstone=b"ExpressiveOS Version: '2.0'",
    ):
        _write_zip(
            os.path.join(root, "system_ext/priv-app/SettingsGoogle/SettingsGoogle.apk"),
            {
                "AndroidManifest.xml": b"manifest",
                "resources.arsc": arsc,
                "classes.dex": settings_dex,
            },
        )
        _write_zip(os.path.join(root, "system/framework/framework.jar"), {"classes.dex": b"framework"})
        _write_zip(os.path.join(root, "system/framework/services.jar"), {"classes.dex": services_dex})
        bp = os.path.join(root, "system/build.prop")
        os.makedirs(os.path.dirname(bp), exist_ok=True)
        with open(bp, "w", encoding="utf-8") as f:
            f.write(build_prop)
        tb = os.path.join(root, "system/bin/pbtombstone")
        os.makedirs(os.path.dirname(tb), exist_ok=True)
        with open(tb, "wb") as f:
            f.write(tombstone)

    def _run(self, out_dir):
        return subprocess.run(
            [sys.executable, "-I", BRAND_CHECK, out_dir],
            capture_output=True,
            text=True,
            timeout=15,
        )

    def test_clean_option_b_tree_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._make_out(tmp)
            res = self._run(tmp)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertIn("BRAND_CHECK=OK", res.stdout)

    def test_missing_repo_url_in_settings_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._make_out(tmp, settings_dex=b"TrickyStore without repo url")
            res = self._run(tmp)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("Settings/SettingsGoogle does not contain EOS_KEYBOX_REPO_URL", res.stdout)
            self.assertIn("BRAND_CHECK=FAIL", res.stdout)

    def test_legacy_keybox_url_in_services_or_settings_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._make_out(
                tmp,
                services_dex=b"MANUAL_IMPORT_REQUIRED " + LEGACY_URL,
                settings_dex=REPO_URL + b" " + LEGACY_URL,
            )
            res = self._run(tmp)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("services.jar still contains legacy background EOS_KEYBOX_URL", res.stdout)
            self.assertIn("Settings/SettingsGoogle still contains legacy background EOS_KEYBOX_URL", res.stdout)

    def test_missing_manual_import_in_services_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._make_out(tmp, services_dex=b"EosIntegrityService without guard")
            res = self._run(tmp)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("services.jar lacks MANUAL_IMPORT_REQUIRED", res.stdout)

    def test_evolution_branding_in_arsc_or_prop_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._make_out(
                tmp,
                arsc=b"Welcome to Evolution X",
                build_prop="ro.expressiveos.device=kodiak\nro.extra.brand=EvolutionX\n",
            )
            res = self._run(tmp)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("Evolution X", res.stdout)
            self.assertIn("ro.extra.brand='EvolutionX'", res.stdout)
            self.assertIn("BRAND_CHECK=FAIL", res.stdout)


if __name__ == "__main__":
    unittest.main()
