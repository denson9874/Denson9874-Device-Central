# ==============================================================================
# ExpressiveOS Product Definition for Pixel 11 Pro / XL (Android 17 / API 37)
# ==============================================================================

# Inherit from standard Pixel 11 base device tree
$(call inherit-product, device/google/pixel11/device-pixel11.mk)

# Inherit 64-bit target configuration
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)

# Product Identification
PRODUCT_NAME := expressive_pixel11
PRODUCT_DEVICE := pixel11
PRODUCT_BRAND := google
PRODUCT_MODEL := Pixel 11 Pro / XL
PRODUCT_MANUFACTURER := Google

# ExpressiveOS Brand Properties
PRODUCT_SYSTEM_PROPERTIES += \
    ro.expressive.version=1.0.0 \
    ro.expressive.device=pixel11 \
    ro.expressive.channel=stable \
    ro.build.display.id=ExpressiveOS-1.0.0-Pixel11ProXL \
    ro.config.media_vol_steps=25 \
    ro.launcher.blur.appLaunch=true \
    vendor.display.enable_variable_refresh_rate=1

# Core System Packages
PRODUCT_PACKAGES += \
    ExpressiveLauncherQuickstep \
    ExpressiveHub \
    privileged-permissions-expressive \
    sysconfig-expressive

# Pixel Flagship Feature Parity Packages
# (Tensor AI services, Pixel Camera, Now Playing, Pixel Recorder, GMS Core)
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
