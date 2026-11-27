# Home carousel ends at Add Glasses

The supplied `glasses(3).zip` Android source was checked locally. `DevicePagerAdapter.getItemCount()` returns `deviceList.size + 1`, and the final position uses `TYPE_EMPTY`. `HomeFragment.initDevicePager()` changes the visible device in `onPageSelected`; a device click connects, while an empty-card click opens Add Device. This is a finite pager, with no last-to-first wraparound.

iOS already appends `DeviceCardData.findDevice` after all bound devices, but a swipe also changed the BLE reconnection target. Its delayed automatic connection could reorder a newly connected device to the first position. Home synchronization also replaces the special find-device selection with a bound device. Both paths could move the visible page while the user was browsing toward Add Glasses.

The visible page now has a separate identity in `HomeView.browsedHomeDeviceKey`. `HomeDeviceSelection.visibleIndex` resolves that identity before the connection target, so the final Add Glasses page survives device reorder, removal or insertion. The existing finite scroll bounds and Add Glasses design are preserved. Returning to the home root resets browsing to the current connection target, as before.

Swiping no longer writes `AuthSession.selectedHomeDeviceKey` or starts the delayed card-selection connection task. Explicit card taps retain the existing BLE retry and busy-task guards. Pull-to-refresh retries only the visible real device, and never treats Add Glasses as a connection target. Passive home refreshes keep the actual connection target separate from the page being browsed.

Regression coverage was added to the existing `DeviceUnpairAndIdentityTests.swift` suite for reaching Add Glasses, remaining there across connection reorder and list changes, avoiding wraparound at the end, and swiping back to the last device. Native tests are prepared but were not executed: this Windows host has no Swift/Xcode runtime. They remain part of the existing required packaging check, `Tests/run-device-unpair-identity-tests.sh`.

Local verification passed: full Swift syntax parsing of both production files and the test file, scoped layout scan, and Git whitespace checks. The Android reference files match the original ZIP byte for byte. Manual source review confirmed swipe updates only browsing state, the last card is still appended, and tap-to-connect retains its explicit path. Physical iPhone scrolling and native compilation remain unverified. Version stays 1.1.7 (187); no package or cloud task was started.
