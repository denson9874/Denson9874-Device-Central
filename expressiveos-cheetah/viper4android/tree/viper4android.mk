# ViPER4Android RE for ExpressiveOS. Inherited from vendor/extra/product.mk, which
# apply-v4a.sh sets up; README.md in expressiveos-cheetah/viper4android has the details.
# The app (/system_ext/priv-app) pulls in its privapp-permissions and hiddenapi XMLs.
#
# vendor/extra/product.mk is read for every product the ExpressiveOS tree builds, and that
# tree builds all of ExpressiveOS's phones: each gets what its devices/<device>.conf's EOS_V4A
# says, and eos-images.sh checks that before building.
# EOS_V4A=1, the HIDL driver (gs201's HIDL effect HAL; Evolution X's libeffects loads it):
ifneq ($(filter lineage_cheetah,$(TARGET_PRODUCT)),)

PRODUCT_SOONG_NAMESPACES += \
    vendor/extra/viper4android

PRODUCT_PACKAGES += \
    ViPER4Android \
    libv4a_re

endif

# EOS_V4A=aidl, the AIDL driver and the effects config that loads it (an AIDL effect HAL in a
# vendor this tree builds, with no audio_effects_config.xml of its own; the device tree labels
# the driver's viper.control service). The Pixel 11s' vendor is Google's image: none for them.
ifneq ($(filter lineage_husky,$(TARGET_PRODUCT)),)

PRODUCT_SOONG_NAMESPACES += \
    vendor/extra/viper4android

PRODUCT_PACKAGES += \
    ViPER4Android \
    libv4a_aidl \
    v4a_audio_effects_config.xml

endif
