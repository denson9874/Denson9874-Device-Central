# ExpressiveOS boot animation (expressiveos-cheetah/bootanimation). Inherited from
# vendor/extra/product.mk, which apply-bootanim.sh sets up. ExpressiveOS's bootanimation.zip
# module (vendor/expressiveos/bootanimation/Android.mk) copies TARGET_BOOTANIMATION to
# /product/media/bootanimation.zip; product makefiles are read before that Android.mk.
# Every ExpressiveOS phone (devices/<device>.conf) ships it: the canvas is drawn 1:1 and
# centred on any screen (README.md, "On the other phones").
ifneq ($(filter eos_cheetah eos_husky eos_kodiak eos_grizzly eos_cubs eos_yogi,$(TARGET_PRODUCT)),)
TARGET_BOOTANIMATION := vendor/extra/bootanimation/bootanimation.zip
# The Silk Aurora style (selectable in Expressive Studio: persist.sys.bootanim.name=silk_aurora),
# the holiday copy (persist.sys.bootanim.name=holiday), and the init rc that keeps the selected
# name and colours in /metadata for the next boot (README.md, "Holiday boot animations").
# They ship together: bootanim starts before /data, so without the rc a boot can't pick either
# named zip, and host_init_verifier checks the rc.
PRODUCT_COPY_FILES += \
    vendor/extra/bootanimation/bootanimation_silk_aurora.zip:$(TARGET_COPY_OUT_PRODUCT)/media/bootanimation_silk_aurora.zip \
    vendor/extra/bootanimation/bootanimation_holiday.zip:$(TARGET_COPY_OUT_PRODUCT)/media/bootanimation_holiday.zip \
    vendor/extra/bootanimation/expressiveos-bootanim-hint.rc:$(TARGET_COPY_OUT_PRODUCT)/etc/init/expressiveos-bootanim-hint.rc
endif
