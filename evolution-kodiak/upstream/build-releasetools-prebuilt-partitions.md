# Upstream PR draft: Evolution-X/build (`cnb`)

Not opened yet. It needs Daryl's go-ahead. It would be opened from a fork (`denson9874/build`), branch
`releasetools-prebuilt-partitions`, against `Evolution-X/build:cnb`. The patch is
`evolution-kodiak/device_google_kodiak/patches/build_make/0001-releasetools-tolerate-prebuilt-partitions-without-a-.patch`.

## Title

releasetools: tolerate prebuilt partitions without a directory

## Body

Since 5b95f1f ("releasetools: Support ZipFile/zip-path input in PartitionMapFromTargetFiles", #4),
`PartitionBuildProps._ReadPartitionPropFile` indexes `PartitionMapFromTargetFiles(input_file)[name]`
directly.

`LoadInfoDict` loads build props for every partition in `PARTITIONS_WITH_BUILD_PROP`. A device that ships a
prebuilt partition (`BOARD_PREBUILT_VENDORIMAGE` etc.) has only `IMAGES/vendor.img` in target-files (core/Makefile
copies the image, not a `VENDOR/` directory), so the map has no `vendor` key. `m evolution` then fails while
building the OTA:

    KeyError: 'vendor'

Before #4, a missing partition directory meant a missing build.prop, and the props were left empty. This restores
that behaviour: when the partition has no directory in target-files, log it and return an empty build.prop.

Found while porting Evolution X 17 to the Pixel 11 Pro XL (kodiak), which uses the stock prebuilt vendor,
vendor_dlkm and system_dlkm images. With this change `m evolution` completes. The device runs builds from the
same tree, installed as fastboot images.
