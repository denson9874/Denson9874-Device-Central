# DerpFest-only additions for kodiak. vendor/lineage/config/common.mk inherits this file when it exists.
# Not a repo project, so `repo sync` leaves it alone. Backup: ExpressiveOS evolution-kodiak/derpfest_vendor_extra/

# Basic Call Recorder (chenxiaolong/BCR), prebuilt and presigned. README.md has the details.
PRODUCT_PACKAGES += \
    BCR
