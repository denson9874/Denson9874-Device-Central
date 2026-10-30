# ViPER4Android RE for ExpressiveOS (cheetah). Inherited from vendor/extra/product.mk,
# which apply-v4a.sh sets up; README.md in expressiveos-cheetah/viper4android has the details.
# The app (/system_ext/priv-app) pulls in its privapp-permissions and hiddenapi XMLs.
#
# vendor/extra/product.mk is read for every product the ExpressiveOS tree builds, and that
# tree builds all of ExpressiveOS's phones: only the ones with EOS_V4A=1 in their
# devices/<device>.conf get ViPER4Android. That's cheetah alone: the non-AIDL driver needs
# gs201's HIDL effect HAL, and husky's and the Pixel 11s' effect HALs aren't that. A phone
# with gs201's HIDL effect HAL may be added to this list, with EOS_V4A=1 in its devices/ file.
ifneq ($(filter lineage_cheetah,$(TARGET_PRODUCT)),)

PRODUCT_SOONG_NAMESPACES += \
    vendor/extra/viper4android

PRODUCT_PACKAGES += \
    ViPER4Android \
    libv4a_re

endif
