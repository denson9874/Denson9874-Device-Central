# SukiSU for ExpressiveOS: its manager APK, unmodified, as /product/etc/eos/sukisu-manager.apk,
# and the first-boot setup that installs it to /data (eos-ksu-firstboot.rc, ksu-firstboot.sh).
# SukiSU's kernel crowns only a manager installed under /data/app, so it isn't a system app.
# apply-ksu.sh stages this folder as vendor/extra/ksu with the APK fetch-ksu.sh verified and
# SukiSU's licence, and writes this file last. A phone's ksu-patches 0101 adds eos-sukisu to
# PRODUCT_PACKAGES; the rest comes with it. Make files aren't allowed under device/google/,
# so the module lives here.
LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := eos-sukisu
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_LICENSE_KINDS := SPDX-license-identifier-GPL-3.0
LOCAL_LICENSE_CONDITIONS := restricted
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/LICENSE
LOCAL_SRC_FILES := sukisu-manager.apk
LOCAL_MODULE_STEM := sukisu-manager.apk
LOCAL_MODULE_RELATIVE_PATH := eos
LOCAL_PRODUCT_MODULE := true
# /product/etc/init/eos-ksu-firstboot.rc, checked by host_init_verifier like any init rc
LOCAL_INIT_RC := eos-ksu-firstboot.rc
LOCAL_REQUIRED_MODULES := eos-ksu-firstboot.sh
include $(BUILD_PREBUILT)

# /product/etc/eos/ksu-firstboot.sh: eos-ksu-firstboot.rc runs it with /system/bin/sh, so 0644
include $(CLEAR_VARS)
LOCAL_MODULE := eos-ksu-firstboot.sh
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_SRC_FILES := ksu-firstboot.sh
LOCAL_MODULE_STEM := ksu-firstboot.sh
LOCAL_MODULE_RELATIVE_PATH := eos
LOCAL_PRODUCT_MODULE := true
include $(BUILD_PREBUILT)
