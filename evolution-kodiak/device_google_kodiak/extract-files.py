#!/usr/bin/env -S PYTHONPATH=../../../tools/extract-utils python3
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Extracts the system_ext/product blobs in proprietary-files.txt (Pixel
# telephony: MediaTek RIL glue, IMS, carrier settings, eSIM) into
# vendor/google/kodiak. The stock vendor/kernel images are handled separately
# by extract-images.sh (vendor/google/kodiak-images).
#
#   ./extract-files.py <dumpyara dump of the stock factory image>
#

from extract_utils.main import (
    ExtractUtils,
    ExtractUtilsModule,
)

namespace_imports = [
    'hardware/google/interfaces',
    'hardware/google/pixel',
]

module = ExtractUtilsModule(
    'kodiak',
    'google',
    namespace_imports=namespace_imports,
    add_generated_carriersettings_file=True,
)

if __name__ == '__main__':
    utils = ExtractUtils.device(module)
    utils.run()
