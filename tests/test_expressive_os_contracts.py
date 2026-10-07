#!/usr/bin/env python3
"""
Unit and Contract Verification Suite for ExpressiveOS (Android 17 / Pixel 11 Pro/XL)
"""

import os
import unittest
import xml.etree.ElementTree as ET

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

class TestExpressiveOSManifests(unittest.TestCase):

    def test_default_manifest_xml(self):
        manifest_path = os.path.join(REPO_ROOT, "manifests", "default.xml")
        self.assertTrue(os.path.exists(manifest_path), f"{manifest_path} must exist")
        tree = ET.parse(manifest_path)
        root = tree.getroot()
        self.assertEqual(root.tag, "manifest")
        
        projects = {p.attrib.get("name"): p.attrib.get("path") for p in root.findall("project")}
        self.assertIn("ExpressiveLauncher", projects)
        self.assertIn("ExpressiveOS-ExpressiveHub", projects)
        self.assertIn("ExpressiveOS-frameworks_base", projects)

    def test_pixel11_manifest_xml(self):
        pixel_manifest = os.path.join(REPO_ROOT, "manifests", "pixel11.xml")
        self.assertTrue(os.path.exists(pixel_manifest), f"{pixel_manifest} must exist")
        tree = ET.parse(pixel_manifest)
        root = tree.getroot()
        self.assertEqual(root.tag, "manifest")
        
        paths = [p.attrib.get("path") for p in root.findall("project")]
        self.assertIn("device/google/pixel11", paths)
        self.assertIn("vendor/google/pixel11", paths)
        self.assertIn("hardware/google/camera", paths)


class TestExpressiveLauncherPrivilegedIntegration(unittest.TestCase):

    def test_privileged_permissions_whitelist(self):
        perm_path = os.path.join(REPO_ROOT, "packages", "apps", "ExpressiveLauncher", "privileged-permissions-expressive.xml")
        self.assertTrue(os.path.exists(perm_path), f"{perm_path} must exist")
        tree = ET.parse(perm_path)
        root = tree.getroot()
        
        privapp = root.find("privapp-permissions")
        self.assertIsNotNone(privapp)
        self.assertEqual(privapp.attrib.get("package"), "dev.launcher.expressive.l3")
        
        perms = {p.attrib.get("name") for p in privapp.findall("permission")}
        required_perms = {
            "android.permission.MANAGE_ACTIVITY_TASKS",
            "android.permission.STATUS_BAR_SERVICE",
            "android.permission.STOP_APP_SWITCHES",
            "android.permission.SET_ORIENTATION",
            "android.permission.READ_FRAME_BUFFER",
            "android.permission.WRITE_SECURE_SETTINGS"
        }
        for req in required_perms:
            self.assertIn(req, perms, f"Missing required privileged permission: {req}")

    def test_sysconfig_xml(self):
        sysconfig_path = os.path.join(REPO_ROOT, "packages", "apps", "ExpressiveLauncher", "sysconfig-expressive.xml")
        self.assertTrue(os.path.exists(sysconfig_path), f"{sysconfig_path} must exist")
        tree = ET.parse(sysconfig_path)
        root = tree.getroot()
        self.assertEqual(root.tag, "config")
        power_save = root.find("allow-in-power-save")
        self.assertIsNotNone(power_save)
        self.assertEqual(power_save.attrib.get("package"), "dev.launcher.expressive.l3")


class TestExpressiveHubConfiguration(unittest.TestCase):

    def test_preferences_xml(self):
        pref_path = os.path.join(REPO_ROOT, "packages", "apps", "ExpressiveHub", "res", "xml", "expressive_hub_preferences.xml")
        self.assertTrue(os.path.exists(pref_path), f"{pref_path} must exist")
        tree = ET.parse(pref_path)
        root = tree.getroot()
        self.assertEqual(root.tag, "PreferenceScreen")

    def test_strings_xml(self):
        strings_path = os.path.join(REPO_ROOT, "packages", "apps", "ExpressiveHub", "res", "values", "strings.xml")
        self.assertTrue(os.path.exists(strings_path), f"{strings_path} must exist")
        tree = ET.parse(strings_path)
        root = tree.getroot()
        strings = {s.attrib.get("name"): s.text for s in root.findall("string")}
        self.assertIn("expressive_hub_title", strings)
        self.assertIn("category_quick_settings", strings)


class TestDeviceAndBuildConfiguration(unittest.TestCase):

    def test_product_makefile(self):
        mk_path = os.path.join(REPO_ROOT, "device", "google", "pixel11", "expressive_pixel11.mk")
        self.assertTrue(os.path.exists(mk_path), f"{mk_path} must exist")
        with open(mk_path, "r") as f:
            content = f.read()
        self.assertIn("PRODUCT_NAME := expressive_pixel11", content)
        self.assertIn("ExpressiveLauncherQuickstep", content)
        self.assertIn("ExpressiveHub", content)
        self.assertIn("GoogleCamera", content)
        self.assertIn("ro.expressive.version=1.0.0", content)

    def test_flash_all_script_executable(self):
        script_path = os.path.join(REPO_ROOT, "tools", "flash_all", "flash-all.sh")
        self.assertTrue(os.path.exists(script_path), f"{script_path} must exist")
        self.assertTrue(os.access(script_path, os.X_OK), "flash-all.sh must be executable")

    def test_envsetup_script_executable(self):
        script_path = os.path.join(REPO_ROOT, "build", "envsetup_expressive.sh")
        self.assertTrue(os.path.exists(script_path), f"{script_path} must exist")
        self.assertTrue(os.access(script_path, os.X_OK), "envsetup_expressive.sh must be executable")

if __name__ == "__main__":
    unittest.main()
