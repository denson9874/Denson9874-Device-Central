#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Personal extras (private). Inherited by device/google/kodiak/device.mk only
# when KODIAK_PERSONAL=true and this directory exists, so official builds
# never include it.
#

$(call inherit-product-if-exists, vendor/google/kodiak-personal/kodiak-personal-vendor.mk)
