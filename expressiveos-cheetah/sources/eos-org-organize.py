#!/usr/bin/env python3
"""ExpressiveOS multi-organization repository catalog, metadata manager, and migrator.

Organizes ExpressiveOS repositories across four functional GitHub organizations:
  - ExpressiveOS          (remote="expressiveos")          Core ROM, platform, apps, vendor, manifest, blobs
  - ExpressiveOS-ASB      (remote="expressiveos-asb")      Pure upstream AOSP monthly ASB security forks
  - ExpressiveOS-Devices  (remote="expressiveos-devices")  Pixel device trees, vendor blobs, Pixel HALs & sepolicy
  - ExpressiveOS-Legacy   (archived, read-only)            EOS 1.x-only forks and unused legacy repos

Subcommands:
  audit               Compare live GitHub org state against the canonical catalog.
  apply-metadata      Idempotently apply standardized topics, descriptions, and archive legacy repos.
  render-profile      Render categorized org profile README markdown for one or all orgs.
  publish-profile     Create <org>/.github if needed and publish profile/README.md.
  transfer            Safely transfer repos from ExpressiveOS to target orgs (unarchives/re-archives legacy).
  rewrite-manifest    Deterministically rewrite default.xml to use multi-org remotes and lint-check it.
"""

import argparse
import base64
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

ORGS = {
    "ExpressiveOS": {
        "remote": "expressiveos",
        "title": "ExpressiveOS",
        "tagline": "Pure AOSP Android 17 ROM (ExpressiveOS 2.0) — Core Platform, Frameworks, Apps, Vendor & Manifest",
    },
    "ExpressiveOS-ASB": {
        "remote": "expressiveos-asb",
        "title": "ExpressiveOS — AOSP Security Bulletin (ASB) Forks",
        "tagline": "Upstream AOSP Android 17 repositories carrying monthly Android Security Bulletin (ASB) cherry-picks with no ExpressiveOS feature divergence.",
    },
    "ExpressiveOS-Devices": {
        "remote": "expressiveos-devices",
        "title": "ExpressiveOS — Pixel Device Trees, Vendor Blobs & Hardware",
        "tagline": "Google Pixel device trees, proprietary vendor blobs, Pixel HAL interfaces, and Pixel SELinux policy for ExpressiveOS 2.0.",
    },
    "ExpressiveOS-Legacy": {
        "remote": None,
        "title": "ExpressiveOS — Legacy 1.x Archive",
        "tagline": "Read-only archive of ExpressiveOS 1.x (Evolution X / LineageOS-era) repositories kept intact so historical 1.x manifests remain syncable.",
    },
}

FUNCTION_SECTIONS = [
    ("infra", "Manifest & Infrastructure", "fn-infra"),
    ("core-build", "Core Runtime & Build System", "fn-core-build"),
    ("frameworks", "Android Frameworks", "fn-frameworks"),
    ("system", "System Daemons & SEPolicy", "fn-system"),
    ("hardware", "Hardware & HAL Interfaces", "fn-hardware"),
    ("apps", "Apps", "fn-apps"),
    ("modules", "Mainline Modules", "fn-modules"),
    ("services", "System Services", "fn-services"),
    ("providers", "Content Providers", "fn-providers"),
    ("external", "External Libraries", "fn-external"),
    ("devices", "Device Trees", "fn-devices"),
    ("vendor", "Vendor, GMS, Themes & Overlays", "fn-vendor"),
    ("kernel", "Kernel Configs", "fn-kernel"),
    ("sdk", "Legacy SDK", "fn-sdk"),
]

FUNCTION_LABELS = {k: label for k, label, _ in FUNCTION_SECTIONS}
TOPIC_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,49}$")


def infer_function_for_repo(name):
    """Deterministically infer parent-function category from an ExpressiveOS repo name."""
    if name in ("manifest", "blobs", "OTA", ".github"):
        return "infra"
    if name in ("art", "bionic", "bootable_recovery", "build", "build_soong", "trusty_user_base"):
        return "core-build"
    if name.startswith("frameworks_"):
        return "frameworks"
    if name.startswith("system_"):
        return "system"
    if name.startswith("hardware_"):
        return "hardware"
    if name.startswith("packages_apps_"):
        return "apps"
    if name.startswith("packages_modules_"):
        return "modules"
    if name.startswith("packages_services_"):
        return "services"
    if name.startswith("packages_providers_"):
        return "providers"
    if name.startswith("packages_resources_"):
        return "apps"
    if name.startswith("external_"):
        return "external"
    if name.startswith("device_"):
        return "devices"
    if name.startswith("vendor_"):
        return "vendor"
    if name.startswith("kernel_"):
        return "kernel"
    if name == "lineage-sdk":
        return "sdk"
    return "core-build"


def _entry(org, fn, track, bucket, description, archive=False):
    return {
        "target_org": org,
        "function": fn,
        "track": track,
        "bucket": bucket,
        "archive": archive,
        "description": description,
        "topics": ["expressiveos", track, f"fn-{fn}", bucket],
    }


def _core(fn, desc, track="eos-2-0"):
    return _entry("ExpressiveOS", fn, track, "eos-core", desc, archive=False)


def _asb(fn, aosp_path):
    return _entry(
        "ExpressiveOS-ASB",
        fn,
        "eos-2-0",
        "eos-asb-patch",
        f"AOSP {aosp_path} carrying monthly Android Security Bulletin (ASB) patches for ExpressiveOS 2.0",
        archive=False,
    )


def _dev(fn, desc):
    return _entry("ExpressiveOS-Devices", fn, "eos-2-0", "eos-devices", desc, archive=False)


def _legacy(fn, desc):
    return _entry("ExpressiveOS-Legacy", fn, "eos-legacy-1x", "eos-archived", desc, archive=True)


# Canonical 127-repository catalog for ExpressiveOS.
REPO_CATALOG = {
    # -------------------------------------------------------------------------
    # ExpressiveOS (Core ROM — 60 repos)
    # -------------------------------------------------------------------------
    # Manifest & Infrastructure (2)
    "manifest": _core("infra", "ExpressiveOS repo manifest (expressiveos-2.0 pure AOSP android-17.0.0_r1 + ASB pins)", track="eos-infra"),
    "blobs": _core("infra", "Git LFS object store for ExpressiveOS vendor_gms, vendor_google_cheetah, and vendor_google_husky", track="eos-infra"),

    # Core Runtime & Build System (5)
    "art": _core("core-build", "Android Runtime (ART) for ExpressiveOS 2.0"),
    "bionic": _core("core-build", "Bionic C library and linker with ExpressiveOS 2.0 compatibility patches"),
    "bootable_recovery": _core("core-build", "Android Recovery and fastbootd for ExpressiveOS 2.0"),
    "build": _core("core-build", "AOSP Make build system and releasetools (build/make) for ExpressiveOS 2.0"),
    "build_soong": _core("core-build", "Soong build system (build/soong) for ExpressiveOS 2.0"),

    # Frameworks (6)
    "frameworks_av": _core("frameworks", "Android multimedia/audio frameworks (frameworks/av) with ViPER4Android hooks"),
    "frameworks_base": _core("frameworks", "Core Android framework, SystemUI, and Material 3 Expressive UX for ExpressiveOS 2.0"),
    "frameworks_hardware_interfaces": _core("frameworks", "Android framework hardware AIDL/HIDL interfaces (stats V3 for CP3A/CP4A Pixel vendor)"),
    "frameworks_libs_systemui": _core("frameworks", "Shared SystemUI/Monet libraries (frameworks/libs/systemui) with EXPRESSIVE defaults"),
    "frameworks_native": _core("frameworks", "Native Android framework services (SurfaceFlinger, InputFlinger, Binder) for ExpressiveOS 2.0"),
    "frameworks_opt_telephony": _core("frameworks", "Android telephony framework (frameworks/opt/telephony) for ExpressiveOS 2.0"),

    # System (4)
    "system_core": _core("system", "Android init, libcutils, adb/fastboot core utilities (system/core) for ExpressiveOS 2.0"),
    "system_fs_fs_mgr": _core("system", "Filesystem mount and dynamic partition manager (system/fs/fs_mgr) for ExpressiveOS 2.0"),
    "system_sepolicy": _core("system", "Platform SELinux policies (system/sepolicy) for ExpressiveOS 2.0"),
    "system_update_engine": _core("system", "A/B seamless OTA update engine (system/update_engine) with performance mode"),

    # Hardware (2)
    "hardware_expressiveos_interfaces": _core("hardware", "ExpressiveOS vendor AIDL HAL interfaces (health, powershare, touch)"),
    "hardware_interfaces": _core("hardware", "AOSP HAL interface definitions (hardware/interfaces) for ExpressiveOS 2.0"),

    # Apps (16)
    "packages_apps_AppLocker": _core("apps", "Per-app biometric AppLocker app for ExpressiveOS 2.0"),
    "packages_apps_BtHelper": _core("apps", "Bluetooth Devices Helper (battery/anc companion) for ExpressiveOS 2.0"),
    "packages_apps_ColumbusService": _core("apps", "Quick Tap (Columbus) back-tap gesture service for ExpressiveOS 2.0"),
    "packages_apps_EvoEgg": _core("apps", "ExpressiveOS Easter Egg showcase app"),
    "packages_apps_Evolver": _core("apps", "Expressive Studio customization hub integrated into Settings"),
    "packages_apps_GameSpace": _core("apps", "GameSpace gaming overlay and performance manager for ExpressiveOS 2.0"),
    "packages_apps_LMOFreeform": _core("apps", "LMO Freeform floating-window app for ExpressiveOS 2.0"),
    "packages_apps_ManagedProvisioning": _core("apps", "AOSP ManagedProvisioning with ExpressiveOS 2.0 DayNight GlifV4 theming"),
    "packages_apps_OmniStyle": _core("apps", "Header packs and curated wallpaper collections (OmniStyle) for ExpressiveOS 2.0"),
    "packages_apps_Sandbox": _core("apps", "App sandboxing and privacy isolation UI for ExpressiveOS 2.0"),
    "packages_apps_Settings": _core("apps", "Android Settings app with Material 3 Expressive UX and Expressive Studio integration"),
    "packages_apps_SystemUIClocks": _core("apps", "Custom lockscreen clock faces (SystemUIClocks) for ExpressiveOS 2.0"),
    "packages_apps_ThemePicker": _core("apps", "Wallpaper & Style ThemePicker with EXPRESSIVE defaults for ExpressiveOS 2.0"),
    "packages_apps_ThemeStore": _core("apps", "ExpressiveOS Theme Store app for icon, font, and style packs"),
    "packages_apps_Updater": _core("apps", "ExpressiveOS A/B OTA system updater app"),
    "packages_apps_WallpaperPicker2": _core("apps", "AOSP WallpaperPicker2 with downloadable Pixel live wallpaper support"),

    # Mainline Modules (4)
    "packages_modules_Bluetooth": _core("modules", "Bluetooth stack module (packages/modules/Bluetooth) for ExpressiveOS 2.0"),
    "packages_modules_Connectivity": _core("modules", "Connectivity and per-app firewall module (packages/modules/Connectivity)"),
    "packages_modules_Wifi": _core("modules", "Wi-Fi module with Wi-Fi timeout controls (packages/modules/Wifi)"),
    "packages_modules_common": _core("modules", "Shared mainline module utilities (packages/modules/common)"),

    # Providers (3)
    "packages_providers_ContactsProvider": _core("providers", "ContactsProvider with sourceid lookup collision and ASB fixes"),
    "packages_providers_MediaProvider": _core("providers", "MediaProvider with ASB security patches for ExpressiveOS 2.0"),
    "packages_providers_TelephonyProvider": _core("providers", "TelephonyProvider with MMS subscription guards and ASB fixes"),

    # Services (4)
    "packages_services_AxQuickLook": _core("services", "At a Glance / QuickLook weather & status service for ExpressiveOS 2.0"),
    "packages_services_OmniJaws": _core("services", "OmniJaws weather provider service for ExpressiveOS 2.0"),
    "packages_services_Telecomm": _core("services", "Android Telecom call management service (packages/services/Telecomm)"),
    "packages_services_Telephony": _core("services", "Android Telephony phone service (packages/services/Telephony)"),

    # External Libraries (6)
    "external_FadingEdgeLayout": _core("external", "FadingEdgeLayout UI library with Soong blueprint support"),
    "external_bouncycastle": _core("external", "BouncyCastle crypto provider extensions for ExpressiveOS 2.0"),
    "external_json-c": _core("external", "json-c vendor library for Pixel Shannon modem daemon (cbd)"),
    "external_pffft": _core("external", "PFFFT fast Fourier transform library for audio effects & spatial audio"),
    "external_steam-audio": _core("external", "Steam Audio (Phonon) spatial audio library for ExpressiveOS 2.0"),
    "external_toybox": _core("external", "AOSP external/toybox with pkill signal pattern and ASB fixes"),

    # Vendor, GMS, Themes & Overlays (8)
    "vendor_expressiveos": _core("vendor", "ExpressiveOS 2.0 pure-AOSP platform config, release flags, overlays, and SELinux policy"),
    "vendor_extras": _core("vendor", "Shared Compose/M3 Expressive UI components, fonts, and ROM extras (vendor/extras)"),
    "vendor_gms": _core("vendor", "Pixel Google Mobile Services (GMS) prebuilts and RROs (Git LFS via ExpressiveOS/blobs)"),
    "vendor_gms-mosey": _core("vendor", "Pixel Mosey prebuilt companion module for ExpressiveOS 2.0"),
    "vendor_packages_SettingsGoogle": _core("vendor", "Pixel SettingsGoogle overlays, updater routing, and ExpressiveOS branding"),
    "vendor_packages_SystemUIGoogle": _core("vendor", "Pixel SystemUIGoogle Smartspace Monet tokens and ExpressiveOS integration"),
    "vendor_pixel-style": _core("vendor", "Pixel audio, charger assets, and Material You / GMS RRO overlays"),
    "vendor_themes": _core("vendor", "ExpressiveOS 2.0 theme catalog manifests and style overlays"),

    # -------------------------------------------------------------------------
    # ExpressiveOS-ASB (Pure AOSP Monthly Security-Patch Forks — 34 repos)
    # -------------------------------------------------------------------------
    "external_aac": _asb("external", "external/aac"),
    "external_avb": _asb("external", "external/avb"),
    "external_exfatprogs": _asb("external", "external/exfatprogs"),
    "external_freetype": _asb("external", "external/freetype"),
    "external_hplip": _asb("external", "external/hplip"),
    "external_libcupsfilters": _asb("external", "external/libcupsfilters"),
    "external_libhevc": _asb("external", "external/libhevc"),
    "external_libjxl": _asb("external", "external/libjxl"),
    "external_libopenapv": _asb("external", "external/libopenapv"),
    "external_libpng": _asb("external", "external/libpng"),
    "external_libppd": _asb("external", "external/libppd"),
    "external_tremolo": _asb("external", "external/tremolo"),
    "external_wpa_supplicant_8": _asb("external", "external/wpa_supplicant_8"),
    "hardware_nxp_nfc": _asb("hardware", "hardware/nxp/nfc"),
    "hardware_nxp_secure_element": _asb("hardware", "hardware/nxp/secure_element"),
    "hardware_st_nfc": _asb("hardware", "hardware/st/nfc"),
    "packages_apps_Contacts": _asb("apps", "packages/apps/Contacts"),
    "packages_apps_ContactsPicker": _asb("apps", "packages/apps/ContactsPicker"),
    "packages_modules_IntentResolver": _asb("modules", "packages/modules/IntentResolver"),
    "packages_modules_NeuralNetworks": _asb("modules", "packages/modules/NeuralNetworks"),
    "packages_modules_Nfc": _asb("modules", "packages/modules/Nfc"),
    "packages_modules_Profiling": _asb("modules", "packages/modules/Profiling"),
    "packages_modules_Telephony": _asb("modules", "packages/modules/Telephony"),
    "packages_modules_Uwb": _asb("modules", "packages/modules/Uwb"),
    "packages_modules_adb": _asb("modules", "packages/modules/adb"),
    "packages_providers_DownloadProvider": _asb("providers", "packages/providers/DownloadProvider"),
    "packages_services_BuiltInPrintService": _asb("services", "packages/services/BuiltInPrintService"),
    "packages_services_Iwlan": _asb("services", "packages/services/Iwlan"),
    "packages_services_Mms": _asb("services", "packages/services/Mms"),
    "system_gsid": _asb("system", "system/gsid"),
    "system_libfmq": _asb("system", "system/libfmq"),
    "system_libufdt": _asb("system", "system/libufdt"),
    "system_netd": _asb("system", "system/netd"),
    "trusty_user_base": _asb("core-build", "trusty/user/base"),

    # -------------------------------------------------------------------------
    # ExpressiveOS-Devices (Pixel Device Trees, Vendor Blobs & HALs — 15 repos)
    # -------------------------------------------------------------------------
    "device_google_cubs": _dev("devices", "ExpressiveOS 2.0 device tree for Google Pixel 11 (cubs)"),
    "device_google_grizzly": _dev("devices", "ExpressiveOS 2.0 device tree for Google Pixel 11 Pro (grizzly)"),
    "device_google_gs201": _dev("devices", "ExpressiveOS 2.0 common board tree for Google Tensor G2 (gs201)"),
    "device_google_husky": _dev("devices", "ExpressiveOS 2.0 device tree for Google Pixel 8 Pro (husky)"),
    "device_google_kodiak": _dev("devices", "ExpressiveOS 2.0 device tree for Google Pixel 11 Pro XL (kodiak)"),
    "device_google_pantah": _dev("devices", "ExpressiveOS 2.0 common device tree for Google Pixel 7 & 7 Pro (pantah/cheetah)"),
    "device_google_shusky": _dev("devices", "ExpressiveOS 2.0 common device tree for Google Pixel 8 & 8 Pro (shusky)"),
    "device_google_yogi": _dev("devices", "ExpressiveOS 2.0 device tree for Google Pixel 11 Pro Fold (yogi)"),
    "device_google_zuma": _dev("devices", "ExpressiveOS 2.0 common board tree for Google Tensor G3 (zuma)"),
    "hardware_google_camera": _dev("hardware", "Google Pixel camera HAL (hardware/google/camera) with Soong namespace guards"),
    "hardware_google_interfaces": _dev("hardware", "Google Pixel vendor AIDL/HIDL HAL interfaces (display V24)"),
    "hardware_google_pixel": _dev("hardware", "Google Pixel hardware HALs (health, thermal, power, vibrator) for ExpressiveOS 2.0"),
    "hardware_google_pixel-sepolicy": _dev("hardware", "ExpressiveOS 2.0 Pixel SELinux policy (de-Lineaged AOSP + ExpressiveOS HALs)"),
    "vendor_google_cheetah": _dev("vendor", "ExpressiveOS 2.0 proprietary vendor blobs for Google Pixel 7 Pro (cheetah)"),
    "vendor_google_husky": _dev("vendor", "ExpressiveOS 2.0 proprietary vendor blobs for Google Pixel 8 Pro (husky)"),

    # -------------------------------------------------------------------------
    # ExpressiveOS-Legacy (EOS 1.x-Only / Unused Repos — 18 repos, archived)
    # -------------------------------------------------------------------------
    "OTA": _legacy("infra", "[Legacy] Archived Evolution X OTA repo (live EOS OTA feed: denson9874/expressiveos_ota)"),
    "device_evolution_sepolicy": _legacy("devices", "[Legacy EOS 1.x] Archived Evolution/Lineage SELinux policy (replaced by vendor_expressiveos)"),
    "external_piex": _legacy("external", "[Legacy EOS 1.x] Archived external/piex fork (unmodified AOSP used in EOS 2.0)"),
    "frameworks_opt_net_wifi": _legacy("frameworks", "[Legacy EOS 1.x] Archived frameworks/opt/net/wifi fork (dropped in EOS 2.0)"),
    "hardware_qcom_display": _legacy("hardware", "[Legacy EOS 1.x] Archived Qualcomm sm8150 display HAL fork (unused on Pixel/EOS 2.0)"),
    "kernel_configs": _legacy("kernel", "[Legacy EOS 1.x] Archived kernel/configs fork (unmodified AOSP used in EOS 2.0)"),
    "lineage-sdk": _legacy("sdk", "[Legacy EOS 1.x] Archived Lineage SDK fork (removed in pure-AOSP EOS 2.0)"),
    "packages_apps_FaceUnlock": _legacy("apps", "[Legacy EOS 1.x] Archived FaceUnlock app fork (dropped in EOS 2.0)"),
    "packages_apps_LineageParts": _legacy("apps", "[Legacy EOS 1.x] Archived LineageParts app fork (removed in pure-AOSP EOS 2.0)"),
    "packages_apps_SetupWizard": _legacy("apps", "[Legacy EOS 1.x] Archived Lineage SetupWizard fork (replaced by Google SUW in EOS 2.0)"),
    "packages_apps_Stk": _legacy("apps", "[Legacy EOS 1.x] Archived SIM Toolkit fork (unmodified AOSP used in EOS 2.0)"),
    "packages_modules_Permission": _legacy("modules", "[Legacy EOS 1.x] Archived Permission module fork (unmodified AOSP used in EOS 2.0)"),
    "packages_resources_apps": _legacy("apps", "[Legacy EOS 1.x] Archived packages/resources/apps fork (dropped in EOS 2.0)"),
    "system_libhwbinder": _legacy("system", "[Legacy EOS 1.x] Archived system/libhwbinder fork (unmodified AOSP used in EOS 2.0)"),
    "system_media": _legacy("system", "[Legacy EOS 1.x] Archived system/media fork (unmodified AOSP used in EOS 2.0)"),
    "system_memory_libmeminfo": _legacy("system", "[Legacy EOS 1.x] Archived system/memory/libmeminfo fork (unmodified AOSP used in EOS 2.0)"),
    "system_vold": _legacy("system", "[Legacy EOS 1.x] Archived system/vold fork (unmodified AOSP used in EOS 2.0)"),
    "vendor_evolution": _legacy("vendor", "[Legacy EOS 1.x] Archived vendor/lineage base (replaced by vendor_expressiveos in EOS 2.0)"),
}


def run_gh(args, input_json=None, ok=(0,), timeout=60):
    gh_bin = os.environ.get("EOS_GH_BIN", "gh")
    cmd = [gh_bin] + list(args)
    stdin_data = json.dumps(input_json) if input_json is not None else None
    proc = subprocess.run(
        cmd,
        input=stdin_data,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if proc.returncode not in ok:
        err = (proc.stderr or proc.stdout or "").strip()[-400:]
        raise RuntimeError(f"gh {' '.join(args[:4])} failed (rc={proc.returncode}): {err}")
    return proc


def org_exists(org):
    proc = run_gh(["api", f"orgs/{org}"], ok=(0, 1), timeout=30)
    return proc.returncode == 0


def list_org_repos(org):
    proc = run_gh(
        [
            "repo", "list", org, "--limit", "500", "--json",
            "name,description,isArchived,repositoryTopics,defaultBranchRef,visibility,diskUsage",
        ],
        timeout=60,
    )
    data = json.loads(proc.stdout or "[]")
    out = {}
    for r in data:
        topics = sorted(t["name"] for t in (r.get("repositoryTopics") or []))
        out[r["name"]] = {
            "org": org,
            "name": r["name"],
            "description": (r.get("description") or "").strip(),
            "archived": bool(r.get("isArchived")),
            "topics": topics,
            "default_branch": (r.get("defaultBranchRef") or {}).get("name", ""),
            "visibility": r.get("visibility", ""),
            "disk_kb": r.get("diskUsage", 0),
        }
    return out


def fetch_all_live_repos(orgs=None):
    """Return (existing_orgs, repos_by_name_map, org_repos_map)."""
    target_orgs = orgs or list(ORGS.keys())
    existing_orgs = []
    by_name = {}
    by_org = {}
    for org in target_orgs:
        if not org_exists(org):
            continue
        existing_orgs.append(org)
        repos = list_org_repos(org)
        by_org[org] = repos
        for name, info in repos.items():
            if name == ".github":
                continue
            by_name[name] = info
    return existing_orgs, by_name, by_org


def catalog_entry_for(name):
    if name in REPO_CATALOG:
        return REPO_CATALOG[name]
    fn = infer_function_for_repo(name)
    return _asb(fn, name.replace("_", "/"))


def cmd_audit(args):
    existing_orgs, live, _ = fetch_all_live_repos()
    print(f"Existing GitHub organizations: {', '.join(existing_orgs)}")
    missing_orgs = [o for o in ORGS if o not in existing_orgs]
    if missing_orgs:
        print(f"Not yet created: {', '.join(missing_orgs)}")

    uncataloged = sorted(set(live) - set(REPO_CATALOG))
    missing_live = sorted(set(REPO_CATALOG) - set(live))
    print(f"Cataloged repos: {len(REPO_CATALOG)} | Live repos (excl. .github): {len(live)}")
    if uncataloged:
        print(f"  Uncataloged live repos ({len(uncataloged)}): {', '.join(uncataloged)}")
    if missing_live:
        print(f"  Catalog repos missing live ({len(missing_live)}): {', '.join(missing_live)}")

    need_topics = 0
    need_desc = 0
    need_archive = 0
    need_transfer = defaultdict(int)
    for name, info in sorted(live.items()):
        spec = catalog_entry_for(name)
        if sorted(info["topics"]) != sorted(spec["topics"]):
            need_topics += 1
        if info["description"] != spec["description"]:
            need_desc += 1
        if info["archived"] != spec["archive"]:
            need_archive += 1
        if info["org"] != spec["target_org"]:
            need_transfer[f"{info['org']} -> {spec['target_org']}"] += 1

    print(f"Metadata drift: topics={need_topics}, descriptions={need_desc}, archive_state={need_archive}")
    if need_transfer:
        print("Pending transfers:")
        for k, v in sorted(need_transfer.items()):
            print(f"  {k}: {v}")
    else:
        print("Pending transfers: 0 (all repos in target organizations)")
    return 0


def set_repo_archived(org, name, archived, dry_run=False):
    if dry_run:
        print(f"  [dry-run] {org}/{name}: archived={archived}")
        return
    run_gh(
        ["api", "-X", "PATCH", f"repos/{org}/{name}", "--input", "-"],
        input_json={"archived": bool(archived)},
        timeout=30,
    )


def _apply_one_repo_metadata(item, skip_archive, unarchive_to_edit, dry_run):
    name, info = item
    org = info["org"]
    spec = catalog_entry_for(name)
    want_desc = spec["description"]
    want_topics = sorted(spec["topics"])
    want_archive = spec["archive"] and not skip_archive

    need_desc = info["description"] != want_desc
    need_topics = sorted(info["topics"]) != want_topics
    need_archive = info["archived"] != want_archive

    res = {"desc": 0, "topics": 0, "archived": 0, "skipped_archived": 0, "logs": []}
    if not (need_desc or need_topics or need_archive):
        return res

    temporarily_unarchived = False
    if info["archived"] and (need_desc or need_topics):
        if not unarchive_to_edit:
            res["logs"].append(f"  [skip-archived] {org}/{name} (pass --unarchive-to-edit to update metadata)")
            res["skipped_archived"] = 1
            return res
        set_repo_archived(org, name, False, dry_run=dry_run)
        temporarily_unarchived = True

    if need_desc:
        if dry_run:
            res["logs"].append(f"  [dry-run] desc   {org}/{name}: {want_desc}")
        else:
            run_gh(
                ["api", "-X", "PATCH", f"repos/{org}/{name}", "--input", "-"],
                input_json={"description": want_desc},
                timeout=30,
            )
        res["desc"] = 1

    if need_topics:
        if dry_run:
            res["logs"].append(f"  [dry-run] topics {org}/{name}: {', '.join(want_topics)}")
        else:
            run_gh(
                ["api", "-X", "PUT", f"repos/{org}/{name}/topics", "--input", "-"],
                input_json={"names": want_topics},
                timeout=30,
            )
        res["topics"] = 1

    if want_archive and (not info["archived"] or temporarily_unarchived):
        set_repo_archived(org, name, True, dry_run=dry_run)
        res["archived"] = 1
    elif not want_archive and info["archived"] and not skip_archive:
        set_repo_archived(org, name, False, dry_run=dry_run)

    return res


def cmd_apply_metadata(args):
    existing_orgs, live, _ = fetch_all_live_repos()
    print(f"Scanning {len(live)} repos across {', '.join(existing_orgs)} (dry_run={args.dry_run})")

    items = sorted(live.items())
    workers = 1 if args.dry_run else max(1, min(args.jobs, 8))
    updated_desc = 0
    updated_topics = 0
    archived_now = 0
    skipped_archived = 0

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [
            ex.submit(_apply_one_repo_metadata, it, args.skip_archive, args.unarchive_to_edit, args.dry_run)
            for it in items
        ]
        for fut in futs:
            r = fut.result()
            for line in r["logs"]:
                print(line)
            updated_desc += r["desc"]
            updated_topics += r["topics"]
            archived_now += r["archived"]
            skipped_archived += r["skipped_archived"]

    print(
        f"APPLY_METADATA=OK (desc={updated_desc}, topics={updated_topics}, "
        f"archived={archived_now}, skipped_archived={skipped_archived}, dry_run={args.dry_run})"
    )
    return 0


def render_profile_readme(org, live_repos=None, target_view=False):
    """Render categorized profile/README.md for an ExpressiveOS GitHub organization.

    If live_repos is provided (dict name -> info with 'org'), only repos currently in `org`
    are listed (with links pointing to their actual current org). Otherwise, renders the
    planned target state for `org`.
    """
    meta = ORGS[org]
    if live_repos is not None and not target_view:
        org_repos = {n: info for n, info in live_repos.items() if info["org"] == org}
    else:
        org_repos = {
            n: {
                "org": spec["target_org"],
                "name": n,
                "description": spec["description"],
                "archived": spec["archive"],
                "topics": spec["topics"],
            }
            for n, spec in REPO_CATALOG.items()
            if spec["target_org"] == org
        }

    lines = [
        f"# {meta['title']}",
        "",
        meta["tagline"],
        "",
    ]

    if org == "ExpressiveOS":
        lines += [
            "## Quick Links",
            "",
            "- **ROM Manifest (`expressiveos-2.0`, AOSP `android-17.0.0_r1` + monthly ASB):** [`ExpressiveOS/manifest`](https://github.com/ExpressiveOS/manifest)",
            "- **Build Kit, Release Tools & Web Flasher:** [`denson9874/Denson9874-Device-Central`](https://github.com/denson9874/Denson9874-Device-Central)",
            "- **Expressive Launcher:** [`denson9874/ExpressiveLauncher`](https://github.com/denson9874/ExpressiveLauncher)",
            "- **Live OTA Feed:** [`denson9874/expressiveos_ota`](https://github.com/denson9874/expressiveos_ota)",
            "",
            "## Organization Structure",
            "",
            "| Organization | Purpose |",
            "|---|---|",
            "| [`ExpressiveOS`](https://github.com/ExpressiveOS) | Core ROM platform, frameworks, custom apps, vendor/UI, manifest & Git LFS store |",
            "| [`ExpressiveOS-Devices`](https://github.com/ExpressiveOS-Devices) | Google Pixel device trees (`cheetah`, `husky`, `kodiak`, `grizzly`, `cubs`, `yogi`), vendor blobs & Pixel HALs |",
            "| [`ExpressiveOS-ASB`](https://github.com/ExpressiveOS-ASB) | Pure upstream AOSP repositories carrying monthly Android Security Bulletin (ASB) cherry-picks |",
            "| [`ExpressiveOS-Legacy`](https://github.com/ExpressiveOS-Legacy) | Archived read-only ExpressiveOS 1.x repositories |",
            "",
        ]

    # Quick-filter topic links
    present_buckets = set()
    present_fns = set()
    for n in org_repos:
        spec = catalog_entry_for(n)
        present_buckets.add(spec["bucket"])
        present_fns.add(spec["function"])

    filter_links = []
    for fn_key, fn_label, fn_topic in FUNCTION_SECTIONS:
        if fn_key in present_fns:
            filter_links.append(
                f"[{fn_label}](https://github.com/orgs/{org}/repositories?q=topic%3A{fn_topic})"
            )
    if filter_links:
        lines += [
            "## Filter by Parent Function",
            "",
            " · ".join(filter_links),
            "",
        ]

    # Partition repos into primary active, ASB-only (collapsible if still in main org), and archived legacy (collapsible if in main org)
    primary = {}
    asb_inline = {}
    legacy_inline = {}
    for n, info in sorted(org_repos.items()):
        spec = catalog_entry_for(n)
        if org == "ExpressiveOS" and spec["target_org"] == "ExpressiveOS-ASB":
            asb_inline[n] = (info, spec)
        elif org == "ExpressiveOS" and spec["target_org"] == "ExpressiveOS-Legacy":
            legacy_inline[n] = (info, spec)
        else:
            primary[n] = (info, spec)

    by_fn = defaultdict(list)
    for n, (info, spec) in primary.items():
        by_fn[spec["function"]].append((n, info, spec))

    lines += [
        f"## Repositories by Parent Function ({len(org_repos)} total)",
        "",
    ]

    for fn_key, fn_label, fn_topic in FUNCTION_SECTIONS:
        items = sorted(by_fn.get(fn_key, []), key=lambda x: x[0])
        if not items:
            continue
        lines += [
            f"### {fn_label} ({len(items)}) — [`topic:{fn_topic}`](https://github.com/orgs/{org}/repositories?q=topic%3A{fn_topic})",
            "",
            "| Repository | Role / Description |",
            "|---|---|",
        ]
        for n, info, spec in items:
            desc = (info.get("description") or spec["description"]).replace("|", "\\|")
            badge = " *(Devices)*" if (org == "ExpressiveOS" and spec["target_org"] == "ExpressiveOS-Devices") else ""
            lines.append(f"| [`{n}`](https://github.com/{org}/{n}){badge} | {desc} |")
        lines.append("")

    if asb_inline:
        lines += [
            f"### Upstream AOSP Security Bulletin (ASB) Forks ({len(asb_inline)}) — [`topic:eos-asb-patch`](https://github.com/orgs/{org}/repositories?q=topic%3Aeos-asb-patch)",
            "",
            "<details>",
            f"<summary>Show all {len(asb_inline)} pure-AOSP monthly ASB security forks (scheduled for <code>ExpressiveOS-ASB</code>)</summary>",
            "",
            "| Repository | Parent Function | Description |",
            "|---|---|---|",
        ]
        for n, (info, spec) in sorted(asb_inline.items()):
            desc = (info.get("description") or spec["description"]).replace("|", "\\|")
            fn_label = FUNCTION_LABELS.get(spec["function"], spec["function"])
            lines.append(f"| [`{n}`](https://github.com/{org}/{n}) | {fn_label} | {desc} |")
        lines += ["", "</details>", ""]

    if legacy_inline:
        lines += [
            f"### Archived / Legacy EOS 1.x ({len(legacy_inline)}) — [`topic:eos-legacy-1x`](https://github.com/orgs/{org}/repositories?q=topic%3Aeos-legacy-1x)",
            "",
            "<details>",
            f"<summary>Show all {len(legacy_inline)} archived EOS 1.x repositories (scheduled for <code>ExpressiveOS-Legacy</code>)</summary>",
            "",
            "| Repository | Parent Function | Description |",
            "|---|---|---|",
        ]
        for n, (info, spec) in sorted(legacy_inline.items()):
            desc = (info.get("description") or spec["description"]).replace("|", "\\|")
            fn_label = FUNCTION_LABELS.get(spec["function"], spec["function"])
            lines.append(f"| [`{n}`](https://github.com/{org}/{n}) | {fn_label} | {desc} |")
        lines += ["", "</details>", ""]

    lines += [
        "---",
        "*This directory is generated by `expressiveos-cheetah/sources/eos-org-organize.py` in `denson9874/Denson9874-Device-Central`.*",
        "",
    ]
    return "\n".join(lines)


def cmd_render_profile(args):
    live = None
    if args.live:
        _, live, _ = fetch_all_live_repos()
    md = render_profile_readme(args.org, live_repos=live, target_view=args.target_view)
    if args.out:
        Path(args.out).write_text(md, encoding="utf-8")
        print(f"Wrote {args.out} ({len(md)} bytes)")
    else:
        print(md)
    return 0


def publish_org_profile(org, content, dry_run=False):
    if not org_exists(org):
        print(f"  [skip] org {org} does not exist yet")
        return False
    check = run_gh(["api", f"repos/{org}/.github"], ok=(0, 1), timeout=30)
    if check.returncode != 0:
        if dry_run:
            print(f"  [dry-run] create {org}/.github (public)")
        else:
            run_gh(
                ["api", "-X", "POST", f"orgs/{org}/repos", "--input", "-"],
                input_json={
                    "name": ".github",
                    "description": f"Organization profile and community metadata for {org}",
                    "private": False,
                    "auto_init": True,
                },
                timeout=60,
            )
            time.sleep(2)

    existing_sha = None
    existing_text = None
    get_file = run_gh(["api", f"repos/{org}/.github/contents/profile/README.md"], ok=(0, 1), timeout=30)
    if get_file.returncode == 0:
        doc = json.loads(get_file.stdout)
        existing_sha = doc.get("sha")
        raw = doc.get("content", "")
        if raw:
            existing_text = base64.b64decode(raw).decode("utf-8", errors="replace")

    if existing_text == content:
        print(f"  unchanged: {org}/.github profile/README.md")
        return True

    if dry_run:
        print(f"  [dry-run] publish {org}/.github profile/README.md ({len(content)} bytes)")
        return True

    payload = {
        "message": f"profile: update {org} categorized repository index",
        "content": base64.b64encode(content.encode("utf-8")).decode("ascii"),
    }
    if existing_sha:
        payload["sha"] = existing_sha
    run_gh(
        ["api", "-X", "PUT", f"repos/{org}/.github/contents/profile/README.md", "--input", "-"],
        input_json=payload,
        timeout=60,
    )
    print(f"  published: {org}/.github profile/README.md")
    return True


def cmd_publish_profile(args):
    existing_orgs, live, _ = fetch_all_live_repos()
    targets = existing_orgs if args.org == "all" else [args.org]
    for org in targets:
        if org not in ORGS:
            raise RuntimeError(f"unknown org {org!r}")
        md = render_profile_readme(org, live_repos=live, target_view=False)
        publish_org_profile(org, md, dry_run=args.dry_run)
    print("PUBLISH_PROFILE=OK")
    return 0


def wait_for_transfer(target_org, repo, timeout_secs=60):
    deadline = time.monotonic() + timeout_secs
    while time.monotonic() < deadline:
        res = run_gh(["api", f"repos/{target_org}/{repo}"], ok=(0, 1), timeout=20)
        if res.returncode == 0:
            return True
        time.sleep(2)
    return False


def cmd_transfer(args):
    target_filter = set(args.orgs.split(",")) if args.orgs else {
        "ExpressiveOS-ASB", "ExpressiveOS-Devices", "ExpressiveOS-Legacy"
    }
    unknown = target_filter - set(ORGS)
    if unknown:
        raise RuntimeError(f"unknown target org(s): {', '.join(sorted(unknown))}")

    # Preflight: confirm every selected target org exists
    missing = [o for o in sorted(target_filter) if not org_exists(o)]
    if missing:
        print(f"FAIL: target GitHub organization(s) do not exist yet: {', '.join(missing)}", file=sys.stderr)
        print("Create them at https://github.com/account/organizations/new?plan=free first.", file=sys.stderr)
        return 2

    existing_orgs, live, by_org = fetch_all_live_repos()
    moves = []
    for name, spec in sorted(REPO_CATALOG.items()):
        dest = spec["target_org"]
        if dest not in target_filter:
            continue
        info = live.get(name)
        if info is None:
            print(f"  [warn] {name} not found in any ExpressiveOS org; skipping", file=sys.stderr)
            continue
        if info["org"] == dest:
            continue
        if name in by_org.get(dest, {}):
            raise RuntimeError(f"collision: {dest}/{name} already exists while {info['org']}/{name} is also present")
        moves.append((info["org"], dest, name, info["archived"], spec["archive"]))

    print(f"Planned repo transfers: {len(moves)} (apply={args.apply})")
    for src, dest, name, cur_arch, want_arch in moves:
        note = " (unarchive -> transfer -> re-archive)" if cur_arch and want_arch else ""
        print(f"  {src}/{name} -> {dest}/{name}{note}")

    if not args.apply:
        print("TRANSFER=DRY_RUN (pass --apply to execute transfers)")
        return 0

    transferred = 0
    for src, dest, name, cur_arch, want_arch in moves:
        if cur_arch:
            set_repo_archived(src, name, False, dry_run=False)
        run_gh(
            ["api", "-X", "POST", f"repos/{src}/{name}/transfer", "--input", "-"],
            input_json={"new_owner": dest},
            timeout=60,
        )
        if not wait_for_transfer(dest, name, timeout_secs=90):
            raise RuntimeError(f"timed out waiting for {dest}/{name} to appear after transfer")
        if want_arch:
            set_repo_archived(dest, name, True, dry_run=False)
        print(f"  transferred: {src}/{name} -> {dest}/{name}")
        transferred += 1

    if not args.skip_profile_refresh:
        _, live_after, _ = fetch_all_live_repos()
        for org in existing_orgs:
            md = render_profile_readme(org, live_repos=live_after, target_view=False)
            publish_org_profile(org, md, dry_run=False)

    print(f"TRANSFER=OK (transferred={transferred})")
    return 0


def rewrite_manifest_xml(in_path, out_path, branch="expressiveos-2.0", remotes_to_split=None):
    """Rewrite default.xml to route ASB and Device projects to their dedicated remotes.

    Preserves all 40-hex commit SHAs, paths, linkfiles, copyfiles, and annotations verbatim.
    Returns dict of counts per remote.
    """
    split_orgs = set(remotes_to_split or ("ExpressiveOS-ASB", "ExpressiveOS-Devices"))
    tree = ET.parse(str(in_path))
    root = tree.getroot()

    existing_remotes = {r.get("name"): r for r in root.findall("remote")}
    # Insert missing remotes immediately after remote="expressiveos"
    insert_idx = 0
    for idx, child in enumerate(list(root)):
        if child.tag == "remote":
            insert_idx = idx + 1

    add_specs = [
        ("ExpressiveOS-ASB", "expressiveos-asb", "https://github.com/ExpressiveOS-ASB"),
        ("ExpressiveOS-Devices", "expressiveos-devices", "https://github.com/ExpressiveOS-Devices"),
    ]
    for org_name, rname, fetch_url in add_specs:
        if org_name not in split_orgs:
            continue
        if rname not in existing_remotes:
            elem = ET.Element("remote", {
                "name": rname,
                "fetch": fetch_url,
                "revision": branch,
            })
            root.insert(insert_idx, elem)
            insert_idx += 1
            existing_remotes[rname] = elem

    counts = defaultdict(int)
    moved = []
    for proj in root.findall("project"):
        rem = proj.get("remote") or ""
        name = proj.get("name") or ""
        if rem in ("expressiveos", "expressiveos-asb", "expressiveos-devices"):
            spec = REPO_CATALOG.get(name)
            if spec and spec["target_org"] in split_orgs:
                target_rem = ORGS[spec["target_org"]]["remote"]
                if target_rem and rem != target_rem:
                    proj.set("remote", target_rem)
                    moved.append((name, rem, target_rem))
                counts[proj.get("remote")] += 1
            else:
                counts[rem] += 1

    ET.indent(tree, space="  ")
    tree.write(str(out_path), encoding="utf-8", xml_declaration=True)
    with open(out_path, "a", encoding="utf-8") as fh:
        fh.write("\n")
    return dict(counts), moved


def cmd_rewrite_manifest(args):
    split_orgs = set(args.orgs.split(",")) if args.orgs else {"ExpressiveOS-ASB", "ExpressiveOS-Devices"}
    counts, moved = rewrite_manifest_xml(
        args.manifest_in,
        args.manifest_out,
        branch=args.branch,
        remotes_to_split=split_orgs,
    )
    # Validate via sibling update-aosp.py lint
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import importlib.util
    spec = importlib.util.spec_from_file_location("update_aosp", Path(__file__).resolve().parent / "update-aosp.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    errs = mod.lint_manifest_data(Path(args.manifest_out))
    if errs:
        for e in errs:
            print(f"  LINT_ERR: {e}", file=sys.stderr)
        print(f"REWRITE_MANIFEST=FAIL (lint_errors={len(errs)})")
        return 1

    print(f"Manifest remotes summary: {json.dumps(counts, sort_keys=True)}")
    print(f"Projects moved to new remotes: {len(moved)}")
    print("REWRITE_MANIFEST=OK")
    return 0


def build_parser():
    ap = argparse.ArgumentParser(description="ExpressiveOS repository catalog & multi-org organizer")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("audit", help="audit live GitHub org state vs catalog")

    p_meta = sub.add_parser("apply-metadata", help="apply standardized topics, descriptions, and archive legacy repos")
    p_meta.add_argument("--dry-run", action="store_true")
    p_meta.add_argument("--skip-archive", action="store_true")
    p_meta.add_argument("--unarchive-to-edit", action="store_true")
    p_meta.add_argument("--jobs", type=int, default=6, help="parallel API workers (1-8, default 6)")

    p_ren = sub.add_parser("render-profile", help="render categorized profile/README.md for an org")
    p_ren.add_argument("--org", default="ExpressiveOS", choices=list(ORGS.keys()))
    p_ren.add_argument("--live", action="store_true", help="reflect repos currently in the org on GitHub")
    p_ren.add_argument("--target-view", action="store_true", help="render post-transfer target state")
    p_ren.add_argument("--out", help="output markdown path (stdout if omitted)")

    p_pub = sub.add_parser("publish-profile", help="publish profile/README.md into <org>/.github")
    p_pub.add_argument("--org", default="all", help="org name or 'all'")
    p_pub.add_argument("--dry-run", action="store_true")

    p_tr = sub.add_parser("transfer", help="transfer repos from ExpressiveOS into target orgs")
    p_tr.add_argument("--orgs", help="comma-separated subset of target orgs (default: ExpressiveOS-ASB,ExpressiveOS-Devices,ExpressiveOS-Legacy)")
    p_tr.add_argument("--apply", action="store_true", help="actually execute GitHub API transfers (default is dry-run)")
    p_tr.add_argument("--skip-profile-refresh", action="store_true")

    p_rw = sub.add_parser("rewrite-manifest", help="rewrite default.xml for multi-org remotes and lint it")
    p_rw.add_argument("--in", dest="manifest_in", required=True, help="input default.xml")
    p_rw.add_argument("--out", dest="manifest_out", required=True, help="output default.xml")
    p_rw.add_argument("--branch", default="expressiveos-2.0")
    p_rw.add_argument("--orgs", help="comma-separated split orgs (default: ExpressiveOS-ASB,ExpressiveOS-Devices)")

    return ap


def main(argv=None):
    args = build_parser().parse_args(argv)
    handlers = {
        "audit": cmd_audit,
        "apply-metadata": cmd_apply_metadata,
        "render-profile": cmd_render_profile,
        "publish-profile": cmd_publish_profile,
        "transfer": cmd_transfer,
        "rewrite-manifest": cmd_rewrite_manifest,
    }
    try:
        sys.exit(handlers[args.cmd](args))
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
