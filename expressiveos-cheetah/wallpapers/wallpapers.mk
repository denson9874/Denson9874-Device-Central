# ExpressiveOS wallpapers (expressiveos-cheetah/wallpapers). Inherited from
# vendor/extra/product.mk, which apply-wallpapers.sh sets up. vendor/lineage/config/common.mk
# inherits vendor/extra/product.mk on its line 2, before anything else, so the overlay below
# comes ahead of vendor/lineage/overlay/common in PRODUCT_PACKAGE_OVERLAYS and wins over it.
ifeq ($(TARGET_PRODUCT),lineage_cheetah)

# The first-boot wallpaper. WallpaperManager.openRawDefaultWallpaper() reads
# ro.config.wallpaper before the CMF path and before framework-res's default_wallpaper
# drawable (Evolution X's, in vendor/lineage/overlay/common), so this one file replaces it
# at every density without touching vendor/lineage.
PRODUCT_COPY_FILES += \
    vendor/extra/wallpapers/ExpressiveWallpapers/res/drawable-nodpi/expressiveos_bloom.png:$(TARGET_COPY_OUT_PRODUCT)/media/wallpaper/expressiveos_bloom.png
PRODUCT_PRODUCT_PROPERTIES += \
    ro.config.wallpaper=/product/media/wallpaper/expressiveos_bloom.png

# theming_defaults back to AOSP's "*|TONAL_SPOT|home_wallpaper": the first-boot theme comes
# from the wallpaper (blue petal), and later wallpaper changes still recolour the system.
# Evolution X's "#0049c7" is a preset colour source, which stops that.
PRODUCT_PACKAGE_OVERLAYS += vendor/extra/wallpapers/overlay

# The picker keeps Google's PixelWallpapers2026 in 1.0 (Daryl, 2026-10-27): it reads only one
# partner APK, so ExpressiveWallpapers/ (all four, but none of Pixel's) isn't built yet. In 1.1
# one pack holds both.

endif
