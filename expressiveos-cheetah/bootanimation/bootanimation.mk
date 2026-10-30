# ExpressiveOS boot animation (expressiveos-cheetah/bootanimation). Inherited from
# vendor/extra/product.mk, which apply-bootanim.sh sets up. Evolution X's bootanimation.zip
# module (vendor/lineage/bootanimation/Android.mk) copies TARGET_BOOTANIMATION to
# /product/media/bootanimation.zip; product makefiles are read before that Android.mk.
# Every ExpressiveOS phone (devices/<device>.conf) ships it: the canvas is drawn 1:1 and
# centred on any screen (README.md, "On the other phones").
ifneq ($(filter lineage_cheetah lineage_husky lineage_kodiak lineage_grizzly lineage_cubs lineage_yogi,$(TARGET_PRODUCT)),)
TARGET_BOOTANIMATION := vendor/extra/bootanimation/bootanimation.zip
# The holiday copy, which persist.sys.bootanim.name=holiday picks, and the init rc that keeps
# its name and colours in /metadata for the next boot (README.md, "Holiday boot animations").
# They ship together: bootanim starts before /data, so without the rc a boot can't pick the
# zip, and the rc alone would name a zip that isn't there. host_init_verifier checks the rc.
PRODUCT_COPY_FILES += \
    vendor/extra/bootanimation/bootanimation_holiday.zip:$(TARGET_COPY_OUT_PRODUCT)/media/bootanimation_holiday.zip \
    vendor/extra/bootanimation/expressiveos-bootanim-hint.rc:$(TARGET_COPY_OUT_PRODUCT)/etc/init/expressiveos-bootanim-hint.rc
endif
