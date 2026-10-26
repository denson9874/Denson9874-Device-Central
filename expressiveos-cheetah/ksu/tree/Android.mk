# KernelSU Next manager for ExpressiveOS cheetah, preinstalled in /product/app.
# apply-ksu.sh stages this folder as vendor/extra/ksu with the manager APK fetch-ksu.sh
# verified, its LICENSE and its four arm64 libs (lib/arm64/, from the APK itself), and
# writes this file last. device/google/pantah patch 0101 adds KernelSUNext to
# PRODUCT_PACKAGES and makes libksud.so executable (ksu/config.fs).
#
# Make, not Soong: android_app_import can't install an app's JNI libs, and it rewrites
# a presigned APK's libs uncompressed, which drops the v2 signature the kernel checks.
# Android never unpacks native libs for a system app it hasn't updated, so they're
# installed in the app's nativeLibraryDir (/product/app/KernelSUNext/lib/arm64).
# Make files aren't allowed under device/google/, so the module lives here.
LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := KernelSUNext
LOCAL_MODULE_CLASS := APPS
LOCAL_MODULE_SUFFIX := $(COMMON_ANDROID_PACKAGE_SUFFIX)
LOCAL_MODULE_TAGS := optional
LOCAL_LICENSE_KINDS := SPDX-license-identifier-GPL-3.0
LOCAL_LICENSE_CONDITIONS := restricted
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/LICENSE
LOCAL_SRC_FILES := KernelSUNext.apk
# Installed byte for byte as upstream signed it: no re-signing, zipalign or lib rewrite
LOCAL_CERTIFICATE := PRESIGNED
LOCAL_REPLACE_PREBUILT_APK_INSTALLED := $(LOCAL_PATH)/KernelSUNext.apk
LOCAL_PRODUCT_MODULE := true
LOCAL_DEX_PREOPT := false
LOCAL_ENFORCE_USES_LIBRARIES := false
LOCAL_MULTILIB := 64
LOCAL_PREBUILT_JNI_LIBS_arm64 := \
    lib/arm64/libadbroot.so \
    lib/arm64/libandroidx.graphics.path.so \
    lib/arm64/libkernelsu.so \
    lib/arm64/libksud.so
include $(BUILD_PREBUILT)
