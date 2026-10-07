# ==============================================================================
# ExpressiveOS BoardConfig.mk for Pixel 8 Pro (husky)
# ==============================================================================

TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv9-a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_VARIANT := cortex-a715

TARGET_SUPPORTS_64_BIT_APPS := true
TARGET_SUPPORTS_32_BIT_APPS := false

# A/B System Updates (Seamless OTA)
AB_OTA_UPDATER := true
AB_OTA_PARTITIONS += \
    boot \
    init_boot \
    vendor_boot \
    dtbo \
    pvmfw \
    system \
    system_dlkm \
    system_ext \
    product \
    vendor \
    vendor_dlkm \
    vbmeta \
    vbmeta_system \
    vbmeta_vendor

# Dynamic Partitions
BOARD_SUPER_PARTITION_SIZE := 9126805504
BOARD_SUPER_PARTITION_GROUPS := google_dynamic_partitions
BOARD_GOOGLE_DYNAMIC_PARTITIONS_SIZE := 9122611200
BOARD_GOOGLE_DYNAMIC_PARTITIONS_PARTITION_LIST := \
    system \
    system_ext \
    product \
    vendor \
    vendor_dlkm \
    system_dlkm

# Android Verified Boot (AVB 2.0)
BOARD_AVB_ENABLE := true
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 0
BOARD_AVB_KEY_PATH := vendor/expressive/keys/avb_custom_key.pem
BOARD_AVB_ALGORITHM := SHA256_RSA4096

# SELinux Policy
BOARD_SEPOLICY_DIRS += device/google/pixel11/sepolicy
