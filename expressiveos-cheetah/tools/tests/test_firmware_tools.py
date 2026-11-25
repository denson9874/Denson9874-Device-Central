#!/usr/bin/env python3
"""Offline unit tests for lib.sh newest_factory_image_zip and tools/fetch-firmware.sh."""

import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
KIT_DIR = TESTS_DIR.parent.parent


def run_cmd(cmd, env=None, check=True, timeout=30):
    merged = os.environ.copy()
    if env:
        merged.update(env)
    proc = subprocess.run(cmd, env=merged, text=True, capture_output=True, timeout=timeout)
    if check and proc.returncode != 0:
        raise AssertionError(f"failed ({proc.returncode}): {cmd}\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}")
    return proc


class FirmwareToolsTest(unittest.TestCase):
    def setUp(self):
        self.tmp_ctx = tempfile.TemporaryDirectory(prefix="eos-fw-test-")
        self.tmp = Path(self.tmp_ctx.name)
        self.fw_root = self.tmp / "firmware"
        self.fw_root.mkdir(parents=True)

    def tearDown(self):
        self.tmp_ctx.cleanup()

    def test_newest_factory_image_zip_sorts_by_yymmdd_not_branch_prefix(self):
        # Populate zips where December branch prefixes ('cd2a', 'bp1a') sort alphabetically BEFORE 'cp4a'
        for bid in ("cd1a.261005.003", "cp4a.261105.040.d1", "cd2a.261205.001"):
            (self.fw_root / f"image-kodiak-{bid}.zip").write_bytes(b"PK\x05\x06" + b"\x00" * 18)

        res1 = run_cmd(
            ["bash", "-c", 'source "$1/lib.sh" && newest_factory_image_zip kodiak', "_", str(KIT_DIR)],
            env={"EOS_FIRMWARE_ROOT": str(self.fw_root)},
        )
        self.assertEqual(Path(res1.stdout.strip()).name, "image-kodiak-cd2a.261205.001.zip")

        # Same-day higher sequence ('005' > '001') wins even if prefix 'bp1a' < 'cd2a'
        (self.fw_root / "image-kodiak-bp1a.261205.005.a1.zip").write_bytes(b"PK\x05\x06" + b"\x00" * 18)
        res2 = run_cmd(
            ["bash", "-c", 'source "$1/lib.sh" && newest_factory_image_zip kodiak', "_", str(KIT_DIR)],
            env={"EOS_FIRMWARE_ROOT": str(self.fw_root)},
        )
        self.assertEqual(Path(res2.stdout.strip()).name, "image-kodiak-bp1a.261205.005.a1.zip")

    def test_fetch_firmware_pixel11_check_verify_extract_and_sha_mismatch(self):
        kit_copy = self.tmp / "kit"
        shutil.copytree(KIT_DIR / "firmware", kit_copy / "firmware")
        shutil.copytree(KIT_DIR / "tools", kit_copy / "tools", ignore=shutil.ignore_patterns("__pycache__", "tests"))
        fetch_sh = kit_copy / "tools" / "fetch-firmware.sh"

        # 1. --check on unpinned kodiak reports cached state cleanly offline
        (self.fw_root / "image-kodiak-cp4a.261105.040.d1.zip").write_bytes(b"old")
        chk_unpinned = run_cmd(
            ["bash", str(fetch_sh), "--check", "kodiak"],
            env={"EOS_FIRMWARE_ROOT": str(self.fw_root)},
        )
        self.assertIn("cached: cp4a.261105.040.d1", chk_unpinned.stdout)

        # 2. Build a synthetic December factory zip for kodiak (cd2a.261205.001)
        dec_build = "cd2a.261205.001"
        inner_zip = self.tmp / f"image-kodiak-{dec_build}.zip"
        with zipfile.ZipFile(inner_zip, "w") as izf:
            izf.writestr("android-info.txt", "require board=kodiak\nrequire version-bootloader=spacecraft-17.5-99999999\n")
            izf.writestr("super_empty.img", b"SUPER_EMPTY")

        outer_src = self.tmp / f"kodiak-{dec_build}-factory-1234abcd.zip"
        with zipfile.ZipFile(outer_src, "w") as ozf:
            ozf.writestr(f"kodiak-{dec_build}/bootloader-kodiak-spacecraft-17.5-99999999.img", b"BOOTLOADER")
            ozf.writestr(f"kodiak-{dec_build}/radio-kodiak-modem-99999999.img", b"RADIO")
            ozf.write(inner_zip, arcname=f"kodiak-{dec_build}/image-kodiak-{dec_build}.zip")
        good_sha = hashlib.sha256(outer_src.read_bytes()).hexdigest()

        # 3. Wrong SHA-256 fails fast and writes nothing
        (kit_copy / "firmware" / "kodiak.conf").write_text(
            f"url=file://{outer_src}\nsha256={'0' * 64}\n",
            encoding="utf-8",
        )
        bad_res = run_cmd(
            ["bash", str(fetch_sh), "kodiak"],
            env={"EOS_FIRMWARE_ROOT": str(self.fw_root), "EOS_ALLOW_LOCAL_FIRMWARE_URL": "1"},
            check=False,
        )
        self.assertNotEqual(bad_res.returncode, 0)
        self.assertIn("SHA-256 mismatch", bad_res.stderr)
        self.assertFalse((self.fw_root / f"image-kodiak-{dec_build}.zip").exists())

        # 4. Valid SHA-256 extracts image-kodiak-<build>.zip + bootloader/radio dir, deletes outer zip, updates CURRENT
        (kit_copy / "firmware" / "kodiak.conf").write_text(
            f"url=file://{outer_src}\nsha256={good_sha}\n",
            encoding="utf-8",
        )
        ok_res = run_cmd(
            ["bash", str(fetch_sh), "kodiak"],
            env={"EOS_FIRMWARE_ROOT": str(self.fw_root), "EOS_ALLOW_LOCAL_FIRMWARE_URL": "1"},
        )
        self.assertIn(f"FIRMWARE_OK {dec_build}: image-kodiak-{dec_build}.zip", ok_res.stdout)
        self.assertTrue((self.fw_root / f"image-kodiak-{dec_build}.zip").is_file())
        self.assertTrue(
            (self.fw_root / f"kodiak-{dec_build}-bootloader-radio" / "bootloader-kodiak-spacecraft-17.5-99999999.img").is_file()
        )
        self.assertEqual((self.fw_root / "kodiak" / "CURRENT").read_text(encoding="utf-8").strip(), dec_build)

        # 5. Re-run is idempotent
        idem_res = run_cmd(
            ["bash", str(fetch_sh), "kodiak"],
            env={"EOS_FIRMWARE_ROOT": str(self.fw_root), "EOS_ALLOW_LOCAL_FIRMWARE_URL": "1"},
        )
        self.assertIn(f"already cached: {dec_build}", idem_res.stdout)


if __name__ == "__main__":
    unittest.main()
