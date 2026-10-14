#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

LOCAL_PATH := $(call my-dir)

ifeq ($(TARGET_DEVICE),kodiak)

INSTALLED_RADIOIMAGE_TARGET += $(PRODUCT_OUT)/vendor_kernel_boot.img

ifneq ($(wildcard vendor/google/espada-kernel/kodiak/vendor_kernel_boot.img),)
$(PRODUCT_OUT)/vendor_kernel_boot.img: vendor/google/espada-kernel/kodiak/vendor_kernel_boot.img
	$(transform-prebuilt-to-target)
else
$(PRODUCT_OUT)/vendor_kernel_boot.img: vendor/google/kodiak-images/radio/vendor_kernel_boot.img
	$(transform-prebuilt-to-target)
endif

endif
