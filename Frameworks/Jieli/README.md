# Jieli iOS OTA SDK

Official `Jieli-Tech/iOS-JL_OTA`, release directory `libs/Release2.5.0`.

- Source: https://github.com/Jieli-Tech/iOS-JL_OTA
- Commit: `28f12b3dee972f110efcceb57c7dbaa5330ee085`
- License: Apache 2.0; see `LICENSE`.
- Included: `JL_OTALib`, `JL_HashPair`, `JL_AdvParse`, `JLLogHelper`.
- Device and simulator slices are supplied by the vendor.

G5K61 Android's `glassesOtaLib-release.aar` uses Jieli RCSP with default
authentication enabled and standard AE00/AE01/AE02 GATT UUIDs. iOS uses the
official native CoreBluetooth integration, including authentication and
bootloader reconnect by peripheral identifier or manufacturer-advertised MAC.
Firmware image compatibility still requires validation on a physical G5K61.
