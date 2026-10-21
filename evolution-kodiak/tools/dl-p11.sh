#!/bin/bash
# Download the grizzly and cubs CD1A.261005.003 factory images and verify them
cd ~/android-dt/firmware
dl() {  # url sha256
    f=$(basename "$1")
    curl -sSfL --retry 5 -C - -o "$f" "$1" && echo "$2  $f" | sha256sum -c && echo "DL_OK $f" || echo "DL_FAIL $f"
}
dl https://dl.google.com/dl/android/aosp/grizzly-cd1a.261005.003-factory-7c6dad8a.zip 7c6dad8a1b55ec5c8142b6ea3aa0de7a75f63816a9ca1ae10ef450dfe9693317 &
dl https://dl.google.com/dl/android/aosp/cubs-cd1a.261005.003-factory-38087b24.zip 38087b24ebe643f80a533a1c2c9bc791fdac2b0ec7edcb0aec70f6c97236ca59 &
wait
echo ALL_DONE
