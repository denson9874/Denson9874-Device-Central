@ECHO OFF
:: ==============================================================================
:: ExpressiveOS Fastboot Flash Installer for Pixel 11 Pro / XL (Windows)
:: ==============================================================================

PATH=%PATH%;"%SYSTEMROOT%\System32"

ECHO ======================================================
ECHO       ExpressiveOS Flasher - Pixel 11 Pro / XL        
ECHO ======================================================

fastboot --version >nul 2>&1
IF ERRORLEVEL 1 (
    ECHO Error: fastboot command not found! Ensure Android SDK platform-tools is in PATH.
    PAUSE
    EXIT /B 1
)

ECHO Waiting for Pixel 11 Pro / XL in fastboot mode...
fastboot wait-for-device

IF EXIST "bootloader-pixel11.img" (
    ECHO Flashing bootloader...
    fastboot flash bootloader bootloader-pixel11.img
    fastboot reboot-bootloader
    timeout /t 5 /nobreak >nul
)

IF EXIST "radio-pixel11.img" (
    ECHO Flashing radio firmware...
    fastboot flash radio radio-pixel11.img
    fastboot reboot-bootloader
    timeout /t 5 /nobreak >nul
)

IF EXIST "image-expressive_pixel11.zip" (
    ECHO Flashing ExpressiveOS system images...
    fastboot update -w image-expressive_pixel11.zip
    ECHO ======================================================
    ECHO   ExpressiveOS installed successfully! Rebooting...
    ECHO ======================================================
) ELSE (
    ECHO Flashing modular partitions...
    IF EXIST "boot.img" fastboot flash boot boot.img
    IF EXIST "init_boot.img" fastboot flash init_boot init_boot.img
    IF EXIST "vendor_boot.img" fastboot flash vendor_boot vendor_boot.img
    IF EXIST "dtbo.img" fastboot flash dtbo dtbo.img
    IF EXIST "super.img" fastboot flash super super.img
    fastboot reboot
)

PAUSE
