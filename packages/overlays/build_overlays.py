#!/usr/bin/env python3
"""
Compiles and signs ExpressiveOS Runtime Resource Overlays (RRO).
"""

import os
import subprocess
import sys

AAPT2 = "/Users/daryldenson/Library/Android/sdk/build-tools/36.0.0/aapt2"
ZIPALIGN = "/Users/daryldenson/Library/Android/sdk/build-tools/36.0.0/zipalign"
APKSIGNER = "/Users/daryldenson/Library/Android/sdk/build-tools/36.0.0/apksigner"
ANDROID_JAR = "/Users/daryldenson/Library/Android/sdk/platforms/android-37/android.jar"
KEYSTORE = "/Users/daryldenson/Developer/ExpressiveOS/tools/keys/expressive_platform.keystore"

def run_cmd(cmd, cwd=None):
    print(f">> Running: {' '.join(cmd)}")
    subprocess.run(cmd, cwd=cwd, check=True)

def build_overlay(overlay_dir, output_apk):
    res_dir = os.path.join(overlay_dir, "res")
    manifest = os.path.join(overlay_dir, "AndroidManifest.xml")
    compiled_res = os.path.join(overlay_dir, "compiled.flata")
    unaligned_apk = os.path.join(overlay_dir, "unaligned.apk")

    # 1. Compile resources
    run_cmd([AAPT2, "compile", "--dir", res_dir, "-o", compiled_res])

    # 2. Link APK
    run_cmd([
        AAPT2, "link",
        "-I", ANDROID_JAR,
        "--manifest", manifest,
        "-o", unaligned_apk,
        compiled_res
    ])

    # 3. Zipalign
    if os.path.exists(output_apk):
        os.remove(output_apk)
    run_cmd([ZIPALIGN, "-f", "-p", "4", unaligned_apk, output_apk])

    # 4. Sign
    run_cmd([
        APKSIGNER, "sign",
        "--ks", KEYSTORE,
        "--ks-pass", "pass:expressive",
        "--key-pass", "pass:expressive",
        "--ks-key-alias", "expressive",
        output_apk
    ])

    # Cleanup intermediate files
    for f in [compiled_res, unaligned_apk]:
        if os.path.exists(f):
            os.remove(f)

    print(f"✓ Successfully built and signed overlay: {output_apk}")

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(script_dir, "bin")
    os.makedirs(out_dir, exist_ok=True)

    overlays = [
        ("ExpressiveSystemUIOverlay", "ExpressiveSystemUIOverlay.apk"),
        ("ExpressiveAmoledThemeOverlay", "ExpressiveAmoledThemeOverlay.apk"),
        ("ExpressiveNavOverlay", "ExpressiveNavOverlay.apk")
    ]

    for src_name, apk_name in overlays:
        src_path = os.path.join(script_dir, src_name)
        target_apk = os.path.join(out_dir, apk_name)
        build_overlay(src_path, target_apk)

if __name__ == "__main__":
    main()
