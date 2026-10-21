#!/usr/bin/env -S PYTHONPATH=../../../tools/extract-utils python3
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Extracts the personal extras in proprietary-files.txt (Google apps the
# official kodiak tree doesn't ship) into vendor/google/kodiak-personal.
# Private: never publish this directory or its output.
#
#   ./extract-files.py <dumpyara dump of the stock factory image>
#

from extract_utils.main import (
    ExtractUtils,
    ExtractUtilsModule,
)

module = ExtractUtilsModule(
    'kodiak-personal',
    'google',
)

if __name__ == '__main__':
    utils = ExtractUtils.device(module)
    utils.run()
