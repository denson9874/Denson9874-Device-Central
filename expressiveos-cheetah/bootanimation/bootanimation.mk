# ExpressiveOS boot animation (expressiveos-cheetah/bootanimation). Inherited from
# vendor/extra/product.mk, which apply-bootanim.sh sets up. Evolution X's bootanimation.zip
# module (vendor/lineage/bootanimation/Android.mk) copies TARGET_BOOTANIMATION to
# /product/media/bootanimation.zip; product makefiles are read before that Android.mk.
ifeq ($(TARGET_PRODUCT),lineage_cheetah)
TARGET_BOOTANIMATION := vendor/extra/bootanimation/bootanimation.zip
endif
