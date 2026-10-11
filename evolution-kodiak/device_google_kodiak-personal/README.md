# kodiak personal extras (private)

Google apps for the maintainer's own Pixel 11 Pro XL that the official Evolution X device tree doesn't
ship: Pixel Screenshots (PixelAI), AICore, PixelSense, Creative Assistant, Ambient Streaming, Now Playing,
Hotword enrollment, Pixel Camera Services and SatelliteGateway.

- Lives at `device/google/kodiak-personal` on the build server. `./extract-files.py <dump>` generates
  `vendor/google/kodiak-personal`.
- `device/google/kodiak/device.mk` inherits `personal.mk` only with `KODIAK_PERSONAL=true` in the environment.
  `~/kodiak-images.sh` (test builds) sets it; `~/kodiak-build.sh` (release OTA) doesn't.
- **Never publish** this directory or `vendor/google/kodiak-personal`.
