# ExpressiveOS boot animation (expressiveos-cheetah/bootanimation). Inherited from
# vendor/extra/product.mk, which apply-bootanim.sh sets up. Evolution X's bootanimation.zip
# module (vendor/lineage/bootanimation/Android.mk) copies TARGET_BOOTANIMATION to
# /product/media/bootanimation.zip; product makefiles are read before that Android.mk.
# Every ExpressiveOS phone (devices/<device>.conf) ships it: the canvas is drawn 1:1 and
# centred on any screen (README.md, "On the other phones").
ifneq ($(filter lineage_cheetah lineage_husky lineage_kodiak lineage_grizzly lineage_cubs lineage_yogi,$(TARGET_PRODUCT)),)
TARGET_BOOTANIMATION := vendor/extra/bootanimation/bootanimation.zip
endif
