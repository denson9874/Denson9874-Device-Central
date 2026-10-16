🛠 **Evolution X for the Pixel 11 series: over-the-air updates, Espada kernel & Extreme Charging**

New official test builds for the **Pixel 11 Pro XL (kodiak)**, **Pixel 11 Pro (grizzly)**, **Pixel 11 (cubs)** and **Pixel 11 Pro Fold (yogi)**.

✨ **New: Over-the-air updates.** From this build on, Settings > System > System updates downloads and installs new builds in the background, no computer needed. This one still goes on with `fastboot update <zip>` (keeps your data).
✨ **New: Espada kernel v3 (Linux 6.12.92) by Kevtrejo37 built in** for kodiak, grizzly, and cubs (plain Magisk flavor; CASS scheduler, Simple LMK, measured EM; yogi remains on stock Google GKI).
✨ **New: Extreme Charging Mode ("Bodega") Quick Settings tile.** Stock Pixel 11 Extreme Charging brought to Evolution X via a dedicated system controller and QS tile. Communicates with `IPowerExt.setMode("BODEGA", on)` to unlock relaxed thermal ceilings and battery priority charging on 30 W+ USB-PD PPS chargers below 50% battery (auto-resets at full charge or upon disconnect).
✨ **New: Google's charging screensaver is built in** (Settings > Display & touch > Screen saver).
✅ **Fixed:** The charging screensaver showed 0% and drew the number too wide.
✅ **Fixed:** A brief brighter flash, in a lit room, when the screen times out into the always-on display.
🔐 **Rooted?** When an update is ready, use Magisk > Install > *Install to inactive slot (after OTA)* instead of restarting, or root is gone.
📦 Updates include the stock Pixel firmware (bootloader and radio) the build is made for (CD1A.261005.003). If an update doesn't boot, the phone rolls back to the previous build automatically.

Thanks to Kevtrejo37 for the Espada kernel, Sultan Alsawaf for CASS/Simple LMK, GrapheneOS for the zram read-ahead fix, and Ashray V K for the logs.

📱 **Pixel 11 Pro XL (kodiak)**: `EvolutionX-17.0-20261016-kodiak-12.3-Unofficial-fastboot.zip`
SHA-256: `540e495e33c868bfa030e87b5f05cdcdc972deb49f7031528918984ded6312fc`

📱 **Pixel 11 Pro (grizzly)**, untested: `EvolutionX-17.0-20261016-grizzly-12.3-Unofficial-UNTESTED-fastboot.zip`
SHA-256: `20fa44b0494a15ae48884b1e3853dd541fcac4328aea93dc68f818f5d1992609`

📱 **Pixel 11 (cubs)**, untested: `EvolutionX-17.0-20261016-cubs-12.3-Unofficial-UNTESTED-fastboot.zip`
SHA-256: `d8ad87979601d36d4f7eb8e3f94be66b26d3ca01f114631313e65ee7be1ffec3`

📱 **Pixel 11 Pro Fold (yogi)**, untested: `EvolutionX-17.0-20261016-yogi-12.3-Unofficial-UNTESTED-fastboot.zip`
SHA-256: `772f8ba673abcb8c9ce7b220d016cb8949c795154836bad56fc83c7819ff6ccb`

⬇️ SourceForge: https://sourceforge.net/projects/denson9874-s-user-builds/files/
💬 XDA: kodiak/grizzly https://xdaforums.com/t/4804712/ · cubs https://xdaforums.com/t/4804723/ · yogi https://xdaforums.com/t/4804826/
