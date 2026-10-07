#!/usr/bin/env python3
"""
Compiles and signs ExpressiveLab system application.
"""

import os
import shutil
import subprocess
import sys

AAPT2 = "/Users/daryldenson/Library/Android/sdk/build-tools/36.0.0/aapt2"
D8 = "/Users/daryldenson/Library/Android/sdk/build-tools/36.0.0/d8"
ZIPALIGN = "/Users/daryldenson/Library/Android/sdk/build-tools/36.0.0/zipalign"
APKSIGNER = "/Users/daryldenson/Library/Android/sdk/build-tools/36.0.0/apksigner"
ANDROID_JAR = "/Users/daryldenson/Library/Android/sdk/platforms/android-37/android.jar"
KEYSTORE = "/Users/daryldenson/Developer/ExpressiveOS/tools/keys/expressive_platform.keystore"

def run_cmd(cmd, cwd=None):
    print(f">> Running: {' '.join(cmd)}")
    subprocess.run(cmd, cwd=cwd, check=True)

def main():
    root = os.path.dirname(os.path.abspath(__file__))
    res_dir = os.path.join(root, "res")
    src_dir = os.path.join(root, "src")
    manifest = os.path.join(root, "AndroidManifest.xml")
    build_dir = os.path.join(root, "build_output")
    shutil.rmtree(build_dir, ignore_errors=True)
    os.makedirs(build_dir, exist_ok=True)

    compiled_res = os.path.join(build_dir, "compiled_res.flata")
    unaligned_apk = os.path.join(build_dir, "unaligned.apk")
    gen_dir = os.path.join(build_dir, "gen")
    classes_dir = os.path.join(build_dir, "classes")
    os.makedirs(gen_dir, exist_ok=True)
    os.makedirs(classes_dir, exist_ok=True)

    # 1. Compile resources with aapt2
    run_cmd([AAPT2, "compile", "--dir", res_dir, "-o", compiled_res])

    # 2. Link APK & generate R.java
    run_cmd([
        AAPT2, "link",
        "-I", ANDROID_JAR,
        "--manifest", manifest,
        "--java", gen_dir,
        "-o", unaligned_apk,
        compiled_res
    ])

    # 3. Find all java files
    java_files = []
    for base in [gen_dir, src_dir]:
        for r, _, files in os.walk(base):
            for f in files:
                if f.endswith(".java"):
                    java_files.append(os.path.join(r, f))

    # 4. Compile with javac
    run_cmd(["javac", "-cp", ANDROID_JAR, "-d", classes_dir] + java_files)

    # 5. Dex with d8
    class_files = []
    for r, _, files in os.walk(classes_dir):
        for f in files:
            if f.endswith(".class"):
                class_files.append(os.path.join(r, f))

    dex_dir = os.path.join(build_dir, "dex")
    os.makedirs(dex_dir, exist_ok=True)
    run_cmd([D8, "--output", dex_dir, "--lib", ANDROID_JAR] + class_files)

    # 6. Add classes.dex into APK
    classes_dex = os.path.join(dex_dir, "classes.dex")
    run_cmd(["zip", "-j", "-u", unaligned_apk, classes_dex])

    # 7. Zipalign
    aligned_apk = os.path.join(root, "ExpressiveLab.apk")
    if os.path.exists(aligned_apk):
        os.remove(aligned_apk)
    run_cmd([ZIPALIGN, "-f", "-p", "4", unaligned_apk, aligned_apk])

    # 8. Sign with apksigner
    run_cmd([
        APKSIGNER, "sign",
        "--ks", KEYSTORE,
        "--ks-pass", "pass:expressive",
        "--key-pass", "pass:expressive",
        "--ks-key-alias", "expressive",
        aligned_apk
    ])

    print("======================================================")
    print(f"✓ ExpressiveLab.apk compiled successfully!")
    print(f"  Location: {aligned_apk}")
    print("======================================================")

if __name__ == "__main__":
    main()
