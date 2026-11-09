# ViPER4Android RE for ExpressiveOS: the AIDL driver and its effects config for a phone whose
# vendor is Google's stock image (EOS_V4A=aidl-overlay: the Pixel 11s). They can't go into that
# read-only image, so they install under /product/vendor_overlay/0, and init.viper4android.rc
# lays them over /vendor/lib64/soundfx and /vendor/etc at boot. viper4android.mk adds them to
# those products only. Make, not Soong: Soong may not install under /product/vendor_overlay
# (prebuilt_vendor_overlay is neverallowed), and PRODUCT_COPY_FILES refuses ELF files. Class ETC
# copies the bytes as they are (unstripped, upstream's sha256). apply-v4a.sh stages this file
# with the binaries; README.md has the details.
LOCAL_PATH := $(call my-dir)

# /product/vendor_overlay/0/lib64/soundfx/libv4a_aidl.so, seen by the audio HAL as
# /vendor/lib64/soundfx/libv4a_aidl.so (the same library as husky's libv4a_aidl)
include $(CLEAR_VARS)
LOCAL_MODULE := v4a_overlay_libv4a_aidl
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_STEM := libv4a_aidl.so
LOCAL_SRC_FILES := libv4a_aidl_arm64-v8a.so
LOCAL_PRODUCT_MODULE := true
LOCAL_MODULE_PATH := $(TARGET_OUT_PRODUCT)/vendor_overlay/0/lib64/soundfx
LOCAL_LICENSE_KINDS := legacy_restricted
LOCAL_LICENSE_CONDITIONS := restricted
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE.viperdsp $(LOCAL_PATH)/NOTICE.pffft
include $(BUILD_PREBUILT)

# /product/vendor_overlay/0/etc/audio_effects_config.xml, seen as
# /vendor/etc/audio_effects_config.xml: the AIDL zip's config, unchanged (as husky's)
include $(CLEAR_VARS)
LOCAL_MODULE := v4a_overlay_audio_effects_config.xml
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_STEM := audio_effects_config.xml
LOCAL_SRC_FILES := audio_effects_config.aidl.xml
LOCAL_PRODUCT_MODULE := true
LOCAL_MODULE_PATH := $(TARGET_OUT_PRODUCT)/vendor_overlay/0/etc
LOCAL_REQUIRED_MODULES := v4a_overlay_libv4a_aidl
LOCAL_LICENSE_KINDS := legacy_restricted
LOCAL_LICENSE_CONDITIONS := restricted
LOCAL_NOTICE_FILE := $(LOCAL_PATH)/NOTICE.viperdsp $(LOCAL_PATH)/NOTICE.pffft
include $(BUILD_PREBUILT)
