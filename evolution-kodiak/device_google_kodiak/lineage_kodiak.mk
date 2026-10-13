#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

# Same system/product composition as LineageOS's Pixel trees (laguna aosp_common.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit_only.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/generic_system.mk)
# RisingOS's vendor/rising adds its own props to /system (PRODUCT_SYSTEM_PROPERTIES),
# which generic_system.mk's artifact-path check rejects. Evolution X keeps its
# props off /system, so it keeps the check.
ifneq ($(wildcard vendor/rising/config/version.mk),)
PRODUCT_ENFORCE_ARTIFACT_PATH_REQUIREMENTS := false
else
PRODUCT_ENFORCE_ARTIFACT_PATH_REQUIREMENTS := relaxed
endif
$(call inherit-product, $(SRC_TARGET_DIR)/product/handheld_system_ext.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/telephony_system_ext.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_product.mk)

# Evolution X puts these in /system, which generic_system.mk's artifact-path
# rules forbid for device makefiles: AppDataBackup (its skip-on-Pixel check reads
# PRODUCT_MANUFACTURER, which inherited product makefiles never see) and the
# vendor/gms system apps. Same allow-list as device/google/shusky (husky).
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += \
    system/etc/permissions/privapp-permissions-appbackup.xml \
    system/priv-app/AppDataBackup/% \
    system/app/GoogleExtShared/% \
    system/app/GooglePrintRecommendationService/% \
    system/priv-app/DocumentsUIGoogle/% \
    system/priv-app/GooglePackageInstaller/% \
    system/priv-app/TagGoogle/%

# Device
$(call inherit-product, device/google/kodiak/device.mk)

# Lineage / Evolution X common
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

PRODUCT_DEVICE := kodiak
PRODUCT_NAME := lineage_kodiak
PRODUCT_BRAND := google
PRODUCT_MODEL := Pixel 11 Pro XL
PRODUCT_MANUFACTURER := Google
PRODUCT_SYSTEM_BRAND := google
PRODUCT_SYSTEM_MANUFACTURER := Google
PRODUCT_SYSTEM_NAME := generic_system_google

PRODUCT_GMS_CLIENTID_BASE := android-google

# Boot animation
TARGET_SCREEN_HEIGHT := 2992
TARGET_SCREEN_WIDTH := 1344

# Evolution X
WITH_GMS := true
TARGET_HAS_UDFPS := true
TARGET_INCLUDE_BOOT_ANIMATIONS := true
TARGET_ENABLE_BLUR := true
# Bring-up only: tolerate missing product packages
TARGET_DISABLE_EPPE := true

PRODUCT_BUILD_PROP_OVERRIDES += \
    BuildDesc="kodiak-user 17 CD1A.261005.003 16262255 release-keys" \
    BuildFingerprint=google/kodiak/kodiak:17/CD1A.261005.003/16262255:user/release-keys \
    BuildSystemFingerprint=google/generic_system_google/generic:17/CD1A.261005.003/16262255:user/release-keys \
    DeviceProduct=kodiak
