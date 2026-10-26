# ViPER4Android RE for ExpressiveOS (cheetah). Inherited from vendor/extra/product.mk,
# which apply-v4a.sh sets up; README.md in expressiveos-cheetah/viper4android has the details.
# The app (/system_ext/priv-app) pulls in its privapp-permissions and hiddenapi XMLs.

PRODUCT_SOONG_NAMESPACES += \
    vendor/extra/viper4android

PRODUCT_PACKAGES += \
    ViPER4Android \
    libv4a_re
