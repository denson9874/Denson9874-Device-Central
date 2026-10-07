# ==============================================================================
# ExpressiveOS Product Definition for Pixel 8 Pro (husky) (Android 17 / API 37)
# ==============================================================================

# Inherit from Google Pixel 8 Pro base device tree
$(call inherit-product, device/google/shusky/device-husky.mk)

# Inherit 64-bit target configuration
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)

# Product Identification
PRODUCT_NAME := expressive_husky
PRODUCT_DEVICE := husky
PRODUCT_BRAND := google
PRODUCT_MODEL := Pixel 8 Pro
PRODUCT_MANUFACTURER := Google

# ExpressiveOS Brand Properties
PRODUCT_SYSTEM_PROPERTIES += \
    ro.expressive.version=1.0.0 \
    ro.expressive.device=husky \
    ro.expressive.channel=stable \
    ro.build.display.id=ExpressiveOS-1.0.0-Pixel8Pro \
    ro.config.media_vol_steps=25 \
    ro.launcher.blur.appLaunch=true \
    vendor.display.enable_variable_refresh_rate=1

# Core System Packages
PRODUCT_PACKAGES += \
    ExpressiveLauncherQuickstep \
    ExpressiveHub \
    privileged-permissions-expressive \
    sysconfig-expressive

# Pixel 8 Pro Flagship Feature Parity Packages
PRODUCT_PACKAGES += \
    GoogleCamera \
    NowPlaying \
    PixelRecorder \
    GoogleServicesFramework \
    Phonesky \
    PrebuiltGmsCore

# Security & Play Integrity
PRODUCT_SYSTEM_PROPERTIES += \
    ro.boot.verifiedbootstate=green \
    ro.boot.flash.locked=1
