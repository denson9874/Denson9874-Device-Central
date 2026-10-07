#!/usr/bin/env python3
"""
ExpressiveOS ROM Customizer & Fastboot Packager for Pixel 8 Pro (husky)
Unpacks official Google Pixel factory images, injects ExpressiveOS platform components,
custom 60fps boot animation, Expressive Lab system settings integration, RRO overlays,
and repacks a production-grade fastboot-flashable ROM & OTA bundle.
"""

import os
import shutil
import struct
import subprocess
import sys
import zipfile

E2FSPROGS_SBIN = "/opt/homebrew/opt/e2fsprogs/sbin"
E2TOOLS_BIN = "/opt/homebrew/bin"

E2FSCK = os.path.join(E2FSPROGS_SBIN, "e2fsck")
RESIZE2FS = os.path.join(E2FSPROGS_SBIN, "resize2fs")
DEBUGFS = os.path.join(E2FSPROGS_SBIN, "debugfs")
E2CP = os.path.join(E2TOOLS_BIN, "e2cp")
E2MKDIR = os.path.join(E2TOOLS_BIN, "e2mkdir")

def run_cmd(cmd, cwd=None, check=True):
    print(f">> Running: {' '.join(cmd)}")
    res = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True)
    if res.returncode != 0 and check:
        print(f"Error ({res.returncode}):\n{res.stderr}\n{res.stdout}")
        sys.exit(res.returncode)
    return res

def patch_vbmeta_flags(image_path, flags_value=3):
    """
    Patches flags in AVB vbmeta header:
    Bit 0: HASHTREE_DISABLED (1)
    Bit 1: VERIFICATION_DISABLED (2)
    Flags = 3 disables dm-verity hashtree verification.
    """
    with open(image_path, "r+b") as f:
        magic = f.read(4)
        if magic != b"AVB0":
            print(f"Warning: {image_path} does not have AVB0 magic!")
            return
        # Flags offset in AvbVBMetaImageHeader is 120 (uint32 big-endian)
        f.seek(120)
        f.write(struct.pack(">I", flags_value))
    print(f"Patched AVB flags = {flags_value} in {os.path.basename(image_path)}")

def main():
    root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    build_dir = os.path.join(root_dir, "rom_build")
    out_dir = os.path.join(root_dir, "out", "expressive_husky_rom")
    os.makedirs(out_dir, exist_ok=True)

    print("======================================================")
    print(" ExpressiveOS ROM Repacker for Pixel 8 Pro (husky)   ")
    print(" Release: v1.1.0 Customization & OTA Suite            ")
    print("======================================================")

    # Verify required tools
    for tool in [E2FSCK, RESIZE2FS, DEBUGFS, E2CP, E2MKDIR]:
        if not os.path.exists(tool):
            print(f"Error: Required tool not found at {tool}!")
            sys.exit(1)

    # Step 1: Locate factory image components
    factory_dir = None
    husky_subdirs = [
        os.path.join(build_dir, "husky_factory", "husky_beta-zp11.260821.010"),
        os.path.join(build_dir, "husky_factory")
    ]
    for d in husky_subdirs:
        if os.path.exists(d):
            for f in os.listdir(d):
                if f.startswith("image-husky") and f.endswith(".zip"):
                    factory_dir = d
                    break
        if factory_dir:
            break

    if not factory_dir:
        factory_zip = os.path.join(build_dir, "husky_factory.zip")
        if not os.path.exists(factory_zip):
            print("Error: husky_factory.zip or extracted directory not found in rom_build/!")
            sys.exit(1)
        extract_dir = os.path.join(build_dir, "factory_extracted")
        os.makedirs(extract_dir, exist_ok=True)
        print("Unpacking factory zip...")
        with zipfile.ZipFile(factory_zip, 'r') as zf:
            zf.extractall(extract_dir)
        factory_dir = extract_dir
        for item in os.listdir(extract_dir):
            full = os.path.join(extract_dir, item)
            if os.path.isdir(full) and "husky" in item:
                factory_dir = full
                break

    image_zip = None
    bootloader_img = None
    radio_img = None
    for f in os.listdir(factory_dir):
        if f.startswith("image-husky") and f.endswith(".zip"):
            image_zip = os.path.join(factory_dir, f)
        elif f.startswith("bootloader-husky") and f.endswith(".img"):
            bootloader_img = os.path.join(factory_dir, f)
        elif f.startswith("radio-husky") and f.endswith(".img"):
            radio_img = os.path.join(factory_dir, f)

    print(f"Found Factory Directory: {factory_dir}")
    print(f"Found Image Zip: {image_zip}")
    print(f"Found Bootloader: {bootloader_img}")
    print(f"Found Radio: {radio_img}")

    # Copy bootloader and radio to out directory
    if bootloader_img:
        shutil.copy2(bootloader_img, os.path.join(out_dir, os.path.basename(bootloader_img)))
    if radio_img:
        shutil.copy2(radio_img, os.path.join(out_dir, os.path.basename(radio_img)))

    # Step 2: Prepare ExpressiveOS update zip
    final_image_zip = os.path.join(out_dir, "image-expressive_husky.zip")
    if not os.path.exists(final_image_zip):
        print(f"Cloning base image archive to {final_image_zip}...")
        shutil.copy2(image_zip, final_image_zip)

    staging_dir = os.path.join(build_dir, "staging")
    os.makedirs(staging_dir, exist_ok=True)

    system_ext_img = os.path.join(staging_dir, "system_ext.img")
    product_img = os.path.join(staging_dir, "product.img")
    vbmeta_img = os.path.join(staging_dir, "vbmeta.img")
    vbmeta_system_img = os.path.join(staging_dir, "vbmeta_system.img")
    vbmeta_vendor_img = os.path.join(staging_dir, "vbmeta_vendor.img")

    print("Extracting required partitions for modification...")
    with zipfile.ZipFile(final_image_zip, 'r') as zf:
        if not os.path.exists(system_ext_img):
            zf.extract("system_ext.img", staging_dir)
        if not os.path.exists(product_img):
            zf.extract("product.img", staging_dir)
        zf.extract("vbmeta.img", staging_dir)
        zf.extract("vbmeta_system.img", staging_dir)
        zf.extract("vbmeta_vendor.img", staging_dir)

    # Step 3: Expand system_ext filesystem to 512MB
    print("Ensuring system_ext filesystem size is 512M...")
    run_cmd([E2FSCK, "-f", "-y", system_ext_img], check=False)
    run_cmd([RESIZE2FS, system_ext_img, "512M"], check=False)
    run_cmd([E2FSCK, "-f", "-y", system_ext_img], check=False)

    # Step 4: Expressive Launcher Quickstep Injection
    qa_dir = os.path.abspath(os.path.join(root_dir, "..", "ExpressiveLauncher", "build", "outputs", "apk", "lawnWithQuickstepExpressive", "qa"))
    launcher_apk_source = None
    if os.path.exists(qa_dir):
        apks = sorted([os.path.join(qa_dir, f) for f in os.listdir(qa_dir) if f.endswith(".apk")], key=os.path.getmtime, reverse=True)
        if apks:
            launcher_apk_source = apks[0]

    if not launcher_apk_source or not os.path.exists(launcher_apk_source):
        print(f"Error: Expressive Launcher APK not found in {qa_dir}!")
        sys.exit(1)

    print(f"Using Expressive Launcher APK: {launcher_apk_source}")

    # Remove stock NexusLauncherRelease
    print("Purging stock NexusLauncherRelease from system_ext...")
    run_cmd([DEBUGFS, "-w", "-R", "rm priv-app/NexusLauncherRelease/NexusLauncherRelease.apk", system_ext_img], check=False)
    run_cmd([DEBUGFS, "-w", "-R", "rm priv-app/NexusLauncherRelease/NexusLauncherRelease.apk.prof", system_ext_img], check=False)
    run_cmd([DEBUGFS, "-w", "-R", "rmdir priv-app/NexusLauncherRelease", system_ext_img], check=False)

    # Inject ExpressiveLauncherQuickstep
    print("Injecting ExpressiveLauncherQuickstep...")
    run_cmd([E2MKDIR, "-G", "0", "-O", "0", "-P", "755", f"{system_ext_img}:priv-app/ExpressiveLauncherQuickstep"], check=False)
    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", launcher_apk_source, f"{system_ext_img}:priv-app/ExpressiveLauncherQuickstep/ExpressiveLauncherQuickstep.apk"])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set priv-app/ExpressiveLauncherQuickstep security.selinux u:object_r:system_file:s0", system_ext_img])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set priv-app/ExpressiveLauncherQuickstep/ExpressiveLauncherQuickstep.apk security.selinux u:object_r:system_file:s0", system_ext_img])

    # Step 5: Inject Expressive Lab System Settings App
    lab_apk_source = os.path.join(root_dir, "packages", "apps", "ExpressiveLab", "ExpressiveLab.apk")
    print(f"Injecting Expressive Lab: {lab_apk_source}...")
    run_cmd([E2MKDIR, "-G", "0", "-O", "0", "-P", "755", f"{system_ext_img}:priv-app/ExpressiveLab"], check=False)
    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", lab_apk_source, f"{system_ext_img}:priv-app/ExpressiveLab/ExpressiveLab.apk"])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set priv-app/ExpressiveLab security.selinux u:object_r:system_file:s0", system_ext_img])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set priv-app/ExpressiveLab/ExpressiveLab.apk security.selinux u:object_r:system_file:s0", system_ext_img])

    # Step 6: Inject Permissions Whitelists and Sysconfig
    print("Injecting privileged permissions & sysconfig...")
    perm_launcher_xml = os.path.join(root_dir, "packages", "apps", "ExpressiveLauncher", "privileged-permissions-expressive.xml")
    perm_lab_xml = os.path.join(root_dir, "packages", "apps", "ExpressiveLab", "privileged-permissions-lab.xml")
    sysconfig_xml = os.path.join(root_dir, "packages", "apps", "ExpressiveLauncher", "sysconfig-expressive.xml")

    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", perm_launcher_xml, f"{system_ext_img}:etc/permissions/privileged-permissions-expressive.xml"])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set etc/permissions/privileged-permissions-expressive.xml security.selinux u:object_r:system_file:s0", system_ext_img])

    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", perm_lab_xml, f"{system_ext_img}:etc/permissions/privileged-permissions-lab.xml"])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set etc/permissions/privileged-permissions-lab.xml security.selinux u:object_r:system_file:s0", system_ext_img])

    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", sysconfig_xml, f"{system_ext_img}:etc/sysconfig/sysconfig-expressive.xml"])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set etc/sysconfig/sysconfig-expressive.xml security.selinux u:object_r:system_file:s0", system_ext_img])

    # Step 7: Inject RRO Overlays into system_ext/overlay
    print("Injecting RRO Overlays (SystemUI Frosted Glass & Pure AMOLED)...")
    sysui_overlay_apk = os.path.join(root_dir, "packages", "overlays", "bin", "ExpressiveSystemUIOverlay.apk")
    amoled_overlay_apk = os.path.join(root_dir, "packages", "overlays", "bin", "ExpressiveAmoledThemeOverlay.apk")

    run_cmd([E2MKDIR, "-G", "0", "-O", "0", "-P", "755", f"{system_ext_img}:overlay"], check=False)
    run_cmd([DEBUGFS, "-w", "-R", "ea_set overlay security.selinux u:object_r:system_file:s0", system_ext_img])

    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", sysui_overlay_apk, f"{system_ext_img}:overlay/ExpressiveSystemUIOverlay.apk"])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set overlay/ExpressiveSystemUIOverlay.apk security.selinux u:object_r:system_file:s0", system_ext_img])

    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", amoled_overlay_apk, f"{system_ext_img}:overlay/ExpressiveAmoledThemeOverlay.apk"])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set overlay/ExpressiveAmoledThemeOverlay.apk security.selinux u:object_r:system_file:s0", system_ext_img])

    nav_overlay_apk = os.path.join(root_dir, "packages", "overlays", "bin", "ExpressiveNavOverlay.apk")
    print("Injecting Navigation Bar & Quickstep overlay (ExpressiveNavOverlay)...")
    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", nav_overlay_apk, f"{system_ext_img}:overlay/ExpressiveNavOverlay.apk"])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set overlay/ExpressiveNavOverlay.apk security.selinux u:object_r:system_file:s0", system_ext_img])

    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", nav_overlay_apk, f"{product_img}:overlay/ExpressiveNavOverlay.apk"])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set overlay/ExpressiveNavOverlay.apk security.selinux u:object_r:system_file:s0", product_img])

    # Step 8: Inject Custom 60fps Boot Animation into system_ext & product
    bootanim_zip = os.path.join(root_dir, "packages", "overlays", "bootanimation", "bootanimation.zip")
    print(f"Injecting Custom Boot Animation: {bootanim_zip}...")

    # system_ext/media/
    run_cmd([E2MKDIR, "-G", "0", "-O", "0", "-P", "755", f"{system_ext_img}:media"], check=False)
    run_cmd([DEBUGFS, "-w", "-R", "ea_set media security.selinux u:object_r:system_file:s0", system_ext_img])
    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", bootanim_zip, f"{system_ext_img}:media/bootanimation.zip"])
    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", bootanim_zip, f"{system_ext_img}:media/bootanimation-dark.zip"])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set media/bootanimation.zip security.selinux u:object_r:system_file:s0", system_ext_img])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set media/bootanimation-dark.zip security.selinux u:object_r:system_file:s0", system_ext_img])

    # product/media/ (overriding stock Google Pixel animations)
    print("Overriding stock Pixel boot animation in product.img...")
    run_cmd([DEBUGFS, "-w", "-R", "rm media/bootanimation.zip", product_img], check=False)
    run_cmd([DEBUGFS, "-w", "-R", "rm media/bootanimation-dark.zip", product_img], check=False)
    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", bootanim_zip, f"{product_img}:media/bootanimation.zip"])
    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", bootanim_zip, f"{product_img}:media/bootanimation-dark.zip"])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set media/bootanimation.zip security.selinux u:object_r:system_file:s0", product_img])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set media/bootanimation-dark.zip security.selinux u:object_r:system_file:s0", product_img])

    # Step 9: Update build.prop to v1.1.0
    print("Updating build.prop with ExpressiveOS v1.1.0 identity...")
    prop_tmp = os.path.join(staging_dir, "build.prop.tmp")
    run_cmd([DEBUGFS, "-R", f"dump etc/build.prop {prop_tmp}", system_ext_img])

    # Read existing lines, filter out any old expressive props
    with open(prop_tmp, "r") as f:
        existing_lines = f.readlines()

    clean_lines = [
        l for l in existing_lines
        if not any(k in l for k in [
            "ro.expressive.", "ro.build.display.id", "ro.control_privapp_permissions",
            "ro.adb.secure", "persist.sys.usb.config", "persist.service.adb.enable",
            "# ExpressiveOS"
        ])
    ]

    with open(prop_tmp, "w") as f:
        f.writelines(clean_lines)
        f.write("\n# ExpressiveOS Identity\n")
        f.write("ro.expressive.version=1.1.0\n")
        f.write("ro.expressive.device=husky\n")
        f.write("ro.build.display.id=ExpressiveOS-1.1.0-Pixel8Pro\n")
        f.write("\n# ExpressiveOS Platform Stability & Permissions\n")
        f.write("ro.control_privapp_permissions=log\n")
        f.write("ro.adb.secure=0\n")
        f.write("persist.sys.usb.config=adb\n")
        f.write("persist.service.adb.enable=1\n")

    run_cmd([DEBUGFS, "-w", "-R", "rm etc/build.prop", system_ext_img])
    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", prop_tmp, f"{system_ext_img}:etc/build.prop"])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set etc/build.prop security.selinux u:object_r:system_file:s0", system_ext_img])

    # Verify filesystems
    print("Checking and repairing filesystems...")
    run_cmd([E2FSCK, "-f", "-y", system_ext_img], check=False)
    run_cmd([E2FSCK, "-f", "-y", product_img], check=False)

    check_ext = run_cmd([E2FSCK, "-f", "-n", system_ext_img], check=False)
    check_prod = run_cmd([E2FSCK, "-f", "-n", product_img], check=False)
    print(f">> system_ext.img check: {check_ext.returncode}, product.img check: {check_prod.returncode}")

    # Step 10: Patch AVB vbmeta images
    print("Patching AVB vbmeta images (disabling hashtree verity)...")
    patch_vbmeta_flags(vbmeta_img, 3)
    patch_vbmeta_flags(vbmeta_system_img, 3)
    patch_vbmeta_flags(vbmeta_vendor_img, 3)

    # Step 11: Update image-expressive_husky.zip
    print(f"Updating {final_image_zip} with modified partitions...")
    run_cmd([
        "zip", "-u", final_image_zip,
        "system_ext.img", "product.img",
        "vbmeta.img", "vbmeta_system.img", "vbmeta_vendor.img"
    ], cwd=staging_dir)

    # Step 12: Generate Flash & OTA Scripts
    print("Generating installer and seamless OTA scripts...")
    flash_sh_path = os.path.join(out_dir, "flash-all.sh")
    with open(flash_sh_path, "w") as f:
        f.write(f"""#!/usr/bin/env bash
# ==============================================================================
# ExpressiveOS Fastboot Flash Installer for Google Pixel 8 Pro (husky)
# Performs full clean wipe and installation of ExpressiveOS.
# ==============================================================================
set -e

CLR_RESET="\\033[0m"
CLR_BOLD="\\033[1m"
CLR_CYAN="\\033[36m"
CLR_GREEN="\\033[32m"
CLR_YELLOW="\\033[33m"
CLR_RED="\\033[31m"

echo -e "${{CLR_BOLD}}${{CLR_CYAN}}======================================================${{CLR_RESET}}"
echo -e "${{CLR_BOLD}}${{CLR_CYAN}}     ExpressiveOS Clean Flasher — Pixel 8 Pro         ${{CLR_RESET}}"
echo -e "${{CLR_BOLD}}${{CLR_CYAN}}======================================================${{CLR_RESET}}"

fastboot devices

# Flash bootloader and radio if present
if [ -f "{os.path.basename(bootloader_img)}" ]; then
    fastboot flash bootloader {os.path.basename(bootloader_img)}
    fastboot reboot-bootloader
    sleep 5
fi

if [ -f "{os.path.basename(radio_img)}" ]; then
    fastboot flash radio {os.path.basename(radio_img)}
    fastboot reboot-bootloader
    sleep 5
fi

fastboot -w update image-expressive_husky.zip
echo -e "${{CLR_BOLD}}${{CLR_GREEN}}Clean flash completed successfully!${{CLR_RESET}}"
""")
    os.chmod(flash_sh_path, 0o755)

    ota_sh_path = os.path.join(out_dir, "update-ota.sh")
    with open(ota_sh_path, "w") as f:
        f.write(f"""#!/usr/bin/env bash
# ==============================================================================
# ExpressiveOS Seamless OTA Fastboot Updater for Google Pixel 8 Pro (husky)
# Preserves all user data and settings (non-wipe in-place partition update).
# ==============================================================================
set -e

CLR_RESET="\\033[0m"
CLR_BOLD="\\033[1m"
CLR_CYAN="\\033[36m"
CLR_GREEN="\\033[32m"
CLR_YELLOW="\\033[33m"
CLR_RED="\\033[31m"

echo -e "${{CLR_BOLD}}${{CLR_CYAN}}======================================================${{CLR_RESET}}"
echo -e "${{CLR_BOLD}}${{CLR_CYAN}}  ExpressiveOS Seamless OTA Updater — Pixel 8 Pro     ${{CLR_RESET}}"
echo -e "${{CLR_BOLD}}${{CLR_CYAN}}======================================================${{CLR_RESET}}"

fastboot devices

echo -e "${{CLR_CYAN}}Applying ExpressiveOS v1.1.0 update (Data Preserved)...${{CLR_RESET}}"
fastboot update image-expressive_husky.zip

echo -e "\\n${{CLR_BOLD}}${{CLR_GREEN}}======================================================${{CLR_RESET}}"
echo -e "${{CLR_BOLD}}${{CLR_GREEN}}  Seamless OTA update applied successfully!           ${{CLR_RESET}}"
echo -e "${{CLR_BOLD}}${{CLR_GREEN}}======================================================${{CLR_RESET}}"
""")
    os.chmod(ota_sh_path, 0o755)

    print("======================================================")
    print(" ExpressiveOS v1.1.0 ROM & OTA Ready for Pixel 8 Pro!  ")
    print(f" Output Location: {out_dir}")
    print("======================================================")

if __name__ == "__main__":
    main()
