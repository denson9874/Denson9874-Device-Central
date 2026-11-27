# ExpressiveOS wallpapers (expressiveos-cheetah/wallpapers). Inherited from
# vendor/extra/product.mk, which apply-wallpapers.sh sets up. vendor/expressiveos/config/common.mk
# inherits vendor/extra/product.mk first, so the overlay below comes ahead of
# vendor/expressiveos/overlay/common in PRODUCT_PACKAGE_OVERLAYS and wins over it.
# Every ExpressiveOS phone (devices/<device>.conf) ships it: the system scales and crops the
# 1440x3120 PNG to each screen (README.md, "On the other phones").
ifneq ($(filter eos_cheetah eos_husky eos_kodiak eos_grizzly eos_cubs eos_yogi,$(TARGET_PRODUCT)),)

# The first-boot wallpaper. WallpaperManager.openRawDefaultWallpaper() reads
# ro.config.wallpaper before the CMF path and before framework-res's default_wallpaper
# drawable, so this one file replaces it at every density.
PRODUCT_COPY_FILES += \
    vendor/extra/wallpapers/ExpressiveWallpapers/res/drawable-nodpi/expressiveos_bloom.png:$(TARGET_COPY_OUT_PRODUCT)/media/wallpaper/expressiveos_bloom.png
PRODUCT_PRODUCT_PROPERTIES += \
    ro.config.wallpaper=/product/media/wallpaper/expressiveos_bloom.png

# theming_defaults set to "*|EXPRESSIVE|home_wallpaper": the first-boot theme comes
# from the wallpaper (blue petal) in M3 Expressive style, and later wallpaper changes still recolour the system.
# Evolution X's "#0049c7" is a preset colour source, which stops that.
PRODUCT_PACKAGE_OVERLAYS += vendor/extra/wallpapers/overlay

# ExpressiveWallpapers registers via ACTION_SET_WALLPAPER so all four bespoke ExpressiveOS
# wallpapers appear in Wallpaper & Style alongside Google's PixelWallpapers2026 without overriding it.
PRODUCT_PACKAGES += \
    ExpressiveWallpapers

endif
