# Expressive Launcher for ExpressiveOS (expressiveos-cheetah/launcher). Inherited from
# vendor/extra/product.mk, which apply-launcher.sh sets up; the kit's launcher/README.md has
# the details. ExpressiveLauncher (/system_ext/priv-app) pulls in its privapp-permissions and
# hiddenapi XMLs and its two overlays, and its overrides drop Pixel Launcher
# (NexusLauncherRelease) and AOSP's Launcher3 from the build.
#
# vendor/extra/product.mk is read for every product the ExpressiveOS tree builds: every
# ExpressiveOS phone (devices/<device>.conf) gets the launcher. tools/launcher-check.sh tree
# checks that this list names each of them.
ifneq ($(filter lineage_cheetah lineage_husky lineage_kodiak lineage_grizzly lineage_cubs lineage_yogi,$(TARGET_PRODUCT)),)

PRODUCT_SOONG_NAMESPACES += \
    vendor/extra/launcher

PRODUCT_PACKAGES += \
    ExpressiveLauncher

endif
