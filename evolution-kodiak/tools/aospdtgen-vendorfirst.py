"""Run aospdtgen, reading device-specific partition props before system's.

Pixel 11+ ships a shared generic_system_google system image whose
ro.product.system.* props say "generic". sebaubuntu_libs checks system
first, so the whole tree gets named "generic". Reorder the lookup in place
before aospdtgen builds its prop lists at import time.
"""
import runpy
import sys

from sebaubuntu_libs.libandroid.props import utils

LATE = {"system", "system_ext", "bootimage", "system_dlkm"}
utils.PARTITIONS[:] = [p for p in utils.PARTITIONS if p not in LATE] + [
    p for p in utils.PARTITIONS if p in LATE
]
print("prop lookup order:", utils.PARTITIONS, file=sys.stderr)
sys.argv[0] = "aospdtgen"
runpy.run_module("aospdtgen", run_name="__main__")
