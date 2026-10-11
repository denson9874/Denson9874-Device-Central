#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Only system-side and ramdisk configuration lives here: vendor, vendor_dlkm
# and system_dlkm are stock prebuilts (see BoardConfig.mk), so anything this
# file installed into them would never ship.
#

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit_only.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/emulated_storage.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/virtual_ab_ota/launch_with_vendor_ramdisk.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/generic_ramdisk.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/developer_gsi_keys.mk)
$(call inherit-product, frameworks/native/build/phone-xhdpi-6144-dalvik-heap.mk)

# API levels (stock ro.product.first_api_level)
PRODUCT_SHIPPING_API_LEVEL := 37

# IMS (AOSP packages/modules/ImsStack) and Wi-Fi calling (AOSP Iwlan, as
# LineageOS laguna). The rest of the Pixel telephony stack, including
# PixelImsMediaService, is stock blobs.
PRODUCT_PACKAGES += \
    FrameworkResOverlayKodiak \
    ImsStack \
    Iwlan \
    PixelImsMediaServiceOverlayKodiak \
    TeleServiceOverlayKodiak

# HIDL: shipping API 37 drops these, but stock kodiak's system still ships
# them (the stock vendor and Pixel services use HIDL), and vintffm requires
# android.hidl.allocator for the frozen level-7 framework matrix.
PRODUCT_PACKAGES += \
    android.hidl.allocator@1.0-service \
    android.hidl.memory@1.0-impl \
    hwservicemanager

# Partitions
PRODUCT_USE_DYNAMIC_PARTITIONS := true
PRODUCT_BUILD_SUPER_PARTITION := false
PRODUCT_BUILD_INIT_BOOT_IMAGE := true
PRODUCT_BUILD_VENDOR_BOOT_IMAGE := true

# A/B
AB_OTA_POSTINSTALL_CONFIG += \
    RUN_POSTINSTALL_system=true \
    POSTINSTALL_PATH_system=system/bin/otapreopt_script \
    FILESYSTEM_TYPE_system=erofs \
    POSTINSTALL_OPTIONAL_system=true

PRODUCT_PACKAGES += \
    cppreopts.sh \
    otapreopt_script \
    update_engine \
    update_engine_sideload \
    update_verifier

# Recovery: base_vendor.mk normally adds these, but vendor is prebuilt so this
# product doesn't inherit it. Recovery lives in vendor_boot.
PRODUCT_PACKAGES += \
    adbd.recovery \
    cgroups.recovery.json \
    charger.recovery \
    init_second_stage.recovery \
    ld.config.recovery.txt \
    linker.recovery \
    otacerts.recovery \
    recovery \
    servicemanager.recovery \
    shell_and_utilities_recovery \
    watchdogd.recovery

PRODUCT_HOST_PACKAGES += \
    e2fsdroid \
    make_f2fs \
    mke2fs \
    sload_f2fs

# fastbootd
PRODUCT_PACKAGES += \
    android.hardware.fastboot@1.1-impl.pixel \
    fastbootd

# First-stage fstab and recovery init, copied from the stock vendor_boot
PRODUCT_COPY_FILES += \
    vendor/google/kodiak-images/proprietary/fstab.malibu:$(TARGET_COPY_OUT_VENDOR_RAMDISK)/first_stage_ramdisk/system/etc/fstab.malibu \
    vendor/google/kodiak-images/proprietary/init.recovery.malibu.rc:$(TARGET_COPY_OUT_RECOVERY)/root/init.recovery.malibu.rc

# pKVM (pvmfw is built from AOSP; prebuilt pvmfw is no longer allowed)
$(call inherit-product, packages/modules/Virtualization/apex/product_packages.mk)
PRODUCT_BUILD_PVMFW_IMAGE := true

# Test builds only: trust a local adb key in recovery (and Android), so a
# development machine can read logs from a device that fails to boot.
# Set KODIAK_DEV_ADB_KEYS=/path/to/adbkey.pub in the build environment.
ifneq ($(KODIAK_DEV_ADB_KEYS),)
PRODUCT_ADB_KEYS := $(KODIAK_DEV_ADB_KEYS)
endif

# Personal builds only: a maintainer's private extras, if present. Off unless
# KODIAK_PERSONAL=true is set in the build environment, so official builds
# never pick them up.
ifeq ($(KODIAK_PERSONAL),true)
$(call inherit-product-if-exists, device/google/kodiak-personal/personal.mk)
endif

# Adaptive Connectivity Services (SCONE) and Google Fi (Tycho): vendor/gms
# defines both modules in Android.mk, but gms_full.mk's PRODUCT_MANUFACTURER
# filter doesn't match inside inherit-product. Install them from here, along
# with SCONE's privileged-permission allowlist and stock's sysconfig entries.
PRODUCT_PACKAGES += \
    SCONE-v77459 \
    Tycho

PRODUCT_COPY_FILES += \
    device/google/kodiak/configs/permissions/privapp-permissions-kodiak-scone.xml:$(TARGET_COPY_OUT_PRODUCT)/etc/permissions/privapp-permissions-kodiak-scone.xml \
    device/google/kodiak/configs/sysconfig/kodiak-scone.xml:$(TARGET_COPY_OUT_PRODUCT)/etc/sysconfig/kodiak-scone.xml

# Characteristics
PRODUCT_CHARACTERISTICS := nosdcard

# Soong namespaces
PRODUCT_SOONG_NAMESPACES += \
    $(LOCAL_PATH) \
    hardware/google/av \
    hardware/google/interfaces \
    hardware/google/pixel

# Stock images and ramdisk files (extract-images.sh)
$(call inherit-product, vendor/google/kodiak-images/kodiak-images.mk)

# Proprietary system_ext/product blobs (extract-files.py)
$(call inherit-product, vendor/google/kodiak/kodiak-vendor.mk)
