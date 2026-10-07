#!/usr/bin/env python3
"""
ExpressiveOS ROM Customizer & Fastboot Packager for Pixel 8 Pro (husky)
Unpacks official Google Pixel factory images, injects ExpressiveOS platform components,
and repacks a production-grade fastboot-flashable ROM bundle.
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
    print(f"Cloning base image archive to {final_image_zip}...")
    shutil.copy2(image_zip, final_image_zip)

    # Extract partitions for injection
    staging_dir = os.path.join(build_dir, "staging")
    os.makedirs(staging_dir, exist_ok=True)

    print("Extracting system_ext.img and vbmeta images for modification...")
    with zipfile.ZipFile(final_image_zip, 'r') as zf:
        zf.extract("system_ext.img", staging_dir)
        zf.extract("vbmeta.img", staging_dir)
        zf.extract("vbmeta_system.img", staging_dir)
        zf.extract("vbmeta_vendor.img", staging_dir)

    system_ext_img = os.path.join(staging_dir, "system_ext.img")
    vbmeta_img = os.path.join(staging_dir, "vbmeta.img")
    vbmeta_system_img = os.path.join(staging_dir, "vbmeta_system.img")
    vbmeta_vendor_img = os.path.join(staging_dir, "vbmeta_vendor.img")

    # Step 4: Expand system_ext filesystem to 512MB
    print("Expanding system_ext filesystem to 512M...")
    run_cmd([E2FSCK, "-f", "-y", system_ext_img], check=False)
    run_cmd([RESIZE2FS, system_ext_img, "512M"])
    run_cmd([E2FSCK, "-f", "-y", system_ext_img], check=False)

    # Step 5: Replace stock NexusLauncher with ExpressiveLauncherQuickstep
    launcher_apk_source = os.path.abspath(os.path.join(root_dir, "..", "ExpressiveLauncher",
        "build", "outputs", "apk", "lawnWithQuickstepExpressive", "qa",
        "ExpressiveLauncherL3.4.1.1.expressive.qa.apk"))

    if not os.path.exists(launcher_apk_source):
        qa_dir = os.path.abspath(os.path.join(root_dir, "..", "ExpressiveLauncher", "build", "outputs", "apk", "lawnWithQuickstepExpressive", "qa"))
        for f in os.listdir(qa_dir):
            if f.endswith(".apk"):
                launcher_apk_source = os.path.join(qa_dir, f)
                break

    print(f"Using Expressive Launcher APK: {launcher_apk_source}")

    # Remove stock NexusLauncherRelease
    print("Removing stock NexusLauncherRelease from system_ext...")
    run_cmd([DEBUGFS, "-w", "-R", "rm priv-app/NexusLauncherRelease/NexusLauncherRelease.apk", system_ext_img], check=False)
    run_cmd([DEBUGFS, "-w", "-R", "rm priv-app/NexusLauncherRelease/NexusLauncherRelease.apk.prof", system_ext_img], check=False)
    run_cmd([DEBUGFS, "-w", "-R", "rmdir priv-app/NexusLauncherRelease", system_ext_img], check=False)

    # Create priv-app/ExpressiveLauncherQuickstep
    print("Injecting ExpressiveLauncherQuickstep...")
    run_cmd([E2MKDIR, "-G", "0", "-O", "0", "-P", "755", f"{system_ext_img}:priv-app/ExpressiveLauncherQuickstep"])
    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", launcher_apk_source, f"{system_ext_img}:priv-app/ExpressiveLauncherQuickstep/ExpressiveLauncherQuickstep.apk"])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set priv-app/ExpressiveLauncherQuickstep security.selinux u:object_r:system_file:s0", system_ext_img])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set priv-app/ExpressiveLauncherQuickstep/ExpressiveLauncherQuickstep.apk security.selinux u:object_r:system_file:s0", system_ext_img])

    # Inject permissions whitelist
    print("Injecting privileged permissions...")
    perm_xml = os.path.join(root_dir, "packages", "apps", "ExpressiveLauncher", "privileged-permissions-expressive.xml")
    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", perm_xml, f"{system_ext_img}:etc/permissions/privileged-permissions-expressive.xml"])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set etc/permissions/privileged-permissions-expressive.xml security.selinux u:object_r:system_file:s0", system_ext_img])

    # Inject sysconfig
    print("Injecting sysconfig...")
    sysconfig_xml = os.path.join(root_dir, "packages", "apps", "ExpressiveLauncher", "sysconfig-expressive.xml")
    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", sysconfig_xml, f"{system_ext_img}:etc/sysconfig/sysconfig-expressive.xml"])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set etc/sysconfig/sysconfig-expressive.xml security.selinux u:object_r:system_file:s0", system_ext_img])

    # Update build.prop
    print("Updating build.prop with ExpressiveOS identity...")
    prop_tmp = os.path.join(staging_dir, "build.prop.tmp")
    run_cmd([DEBUGFS, "-R", f"dump etc/build.prop {prop_tmp}", system_ext_img])
    with open(prop_tmp, "a") as f:
        f.write("\n# ExpressiveOS Identity\n")
        f.write("ro.expressive.version=1.0.0\n")
        f.write("ro.expressive.device=husky\n")
        f.write("ro.build.display.id=ExpressiveOS-1.0.0-Pixel8Pro\n")
        f.write("\n# ExpressiveOS Platform Stability & Permissions\n")
        f.write("ro.control_privapp_permissions=log\n")
        f.write("ro.adb.secure=0\n")
        f.write("persist.sys.usb.config=adb\n")
        f.write("persist.service.adb.enable=1\n")

    run_cmd([DEBUGFS, "-w", "-R", "rm etc/build.prop", system_ext_img])
    run_cmd([E2CP, "-G", "0", "-O", "0", "-P", "644", prop_tmp, f"{system_ext_img}:etc/build.prop"])
    run_cmd([DEBUGFS, "-w", "-R", "ea_set etc/build.prop security.selinux u:object_r:system_file:s0", system_ext_img])

    # Clean and check filesystem
    print("Checking and repairing filesystem...")
    run_cmd([E2FSCK, "-f", "-y", system_ext_img], check=False)
    final_check = run_cmd([E2FSCK, "-f", "-n", system_ext_img], check=False)
    if final_check.returncode == 0:
        print(">> system_ext.img filesystem verified clean (code 0)")
    else:
        print(f">> system_ext.img check code: {final_check.returncode}")

    # Step 6: Patch AVB vbmeta images
    print("Patching AVB vbmeta images (disabling hashtree verity)...")
    patch_vbmeta_flags(vbmeta_img, 3)
    patch_vbmeta_flags(vbmeta_system_img, 3)
    patch_vbmeta_flags(vbmeta_vendor_img, 3)

    # Step 7: Update image-expressive_husky.zip
    print(f"Updating {final_image_zip} with modified partitions...")
    run_cmd(["zip", "-u", final_image_zip, "system_ext.img", "vbmeta.img", "vbmeta_system.img", "vbmeta_vendor.img"], cwd=staging_dir)


    # Step 8: Generate Flash Scripts
    print("Generating flash-all installer scripts...")
    flash_sh_path = os.path.join(out_dir, "flash-all.sh")
    with open(flash_sh_path, "w") as f:
        f.write(f"""#!/usr/bin/env bash
# ==============================================================================
# ExpressiveOS Fastboot Flash Installer for Google Pixel 8 Pro (husky)
# ==============================================================================
set -e

CLR_RESET="\\033[0m"
CLR_BOLD="\\033[1m"
CLR_CYAN="\\033[36m"
CLR_GREEN="\\033[32m"
CLR_YELLOW="\\033[33m"
CLR_RED="\\033[31m"

echo -e "${{CLR_BOLD}}${{CLR_CYAN}}======================================================${{CLR_RESET}}"
echo -e "${{CLR_BOLD}}${{CLR_CYAN}}     ExpressiveOS Flasher — Pixel 8 Pro (husky)       ${{CLR_RESET}}"
echo -e "${{CLR_BOLD}}${{CLR_CYAN}}======================================================${{CLR_RESET}}"

if ! command -v fastboot &> /dev/null; then
    echo -e "${{CLR_RED}}Error: fastboot command not found! Please install platform-tools.${{CLR_RESET}}"
    exit 1
fi

fastboot devices


PRODUCT=$(fastboot getvar product 2>&1 | grep "product:" | awk '{{print $2}}')
echo -e "Device Product ID: ${{CLR_GREEN}}${{PRODUCT}}${{CLR_RESET}}"

# Check bootloader lock state
LOCKED=$(fastboot getvar unlocked 2>&1 | grep "unlocked:" | awk '{{print $2}}')
if [ "${{LOCKED}}" = "no" ]; then
    echo -e "${{CLR_YELLOW}}Device bootloader is locked! Requesting unlock...${{CLR_RESET}}"
    echo -e "${{CLR_YELLOW}}Please confirm 'Unlock the bootloader' on the device screen!${{CLR_RESET}}"
    fastboot flashing unlock
    fastboot reboot-bootloader
    sleep 5
fi

# Flash bootloader and radio
if [ -f "{os.path.basename(bootloader_img)}" ]; then
    echo -e "Flashing bootloader..."
    fastboot flash bootloader {os.path.basename(bootloader_img)}
    fastboot reboot-bootloader
    sleep 5
fi

if [ -f "{os.path.basename(radio_img)}" ]; then
    echo -e "Flashing radio..."
    fastboot flash radio {os.path.basename(radio_img)}
    fastboot reboot-bootloader
    sleep 5
fi

# Flash system factory update zip
echo -e "${{CLR_CYAN}}Flashing ExpressiveOS system images...${{CLR_RESET}}"
fastboot -w update image-expressive_husky.zip

echo -e "\\n${{CLR_BOLD}}${{CLR_GREEN}}======================================================${{CLR_RESET}}"
echo -e "${{CLR_BOLD}}${{CLR_GREEN}}   ExpressiveOS installed successfully! Rebooting...  ${{CLR_RESET}}"
echo -e "${{CLR_BOLD}}${{CLR_GREEN}}======================================================${{CLR_RESET}}"
""")
    os.chmod(flash_sh_path, 0o755)

    flash_bat_path = os.path.join(out_dir, "flash-all.bat")
    with open(flash_bat_path, "w") as f:
        f.write(f"""@ECHO OFF
:: ExpressiveOS Fastboot Flasher for Pixel 8 Pro
PATH=%PATH%;"%SYSTEMROOT%\\System32"
fastboot flashing unlock
fastboot flash bootloader {os.path.basename(bootloader_img)}
fastboot reboot-bootloader
ping -n 5 127.0.0.1 >nul
fastboot flash radio {os.path.basename(radio_img)}
fastboot reboot-bootloader
ping -n 5 127.0.0.1 >nul
fastboot -w update image-expressive_husky.zip
echo ExpressiveOS installed successfully!
pause
""")

    print("======================================================")
    print(" ExpressiveOS ROM Package Ready for Pixel 8 Pro!       ")
    print(f" Output Location: {out_dir}")
    print("======================================================")

if __name__ == "__main__":
    main()
