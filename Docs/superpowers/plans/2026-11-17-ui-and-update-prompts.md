# UI and Device Update Prompts Implementation Plan

**Goal:** Apply the five pending UI and account fixes requested on November 17.

**Architecture:** Keep existing BLE commands and OTA transport intact. Adjust presentation and validation in their current views; reuse the existing update-offer coordinator and upgrade detail page.

**Tech Stack:** SwiftUI, UIKit, WebKit, existing JSON API client.

**Spec:** User messages and screenshots in this chat, including the Android source in `glasses(2).zip`.

## Constraints

- Preserve existing uncommitted changes; no build-number change or packaging.
- Implement in this session without delegation.
- Forgot-password requests must work without an authenticated session. Use documented paths, never infer an email reset endpoint.
- Ordinary update prompts use fresh device versions and the connected device's offer; interrupted Gen1 recovery takes priority.

## Tasks

- [x] `SoundEffectModeSheet.swift`, `HomeView.swift`: top-align the sound-mode sheet, enlarge cards/icons, cap tablet width, preserve selection commands.
- [x] `GlassesSettingsView.swift`: show 2016×1512, 1920×1080, 1280×720 in the existing resolution choices; preserve 2/1/0 mapping.
- [x] `ForgotPasswordView.swift`, `ChangePasswordView.swift`, `Network/AuthService.swift`: enable filled forms before password equality/format checks, validate raw passwords on tap, show an error toast, retain separate public reset and authenticated change APIs. Verified public routes using empty/invalid parameters; no SMS sent. The reported phone-code failure remains unconfirmed.
- [x] `FAQHTMLText.swift`: render HTML with preserved inline styles, headings, images, links and tables; size to content inside the parent scroll view. Leave pairing instruction rendering unchanged.
- [x] `MainTabView.swift`, `BluetoothFirmwareUpdateDialog.swift`: show an Android-style ordinary update prompt once per main-screen session, Bluetooth first, with cancel/update actions into the existing detail flow. Avoid overlap with pairing, navigation, imports, OTA or Gen1 recovery.

## Review and validation

- Filled passwords that differ, are too short, contain spaces, or lack character variety must yield visible feedback; no reset request for local validation errors.
- Public phone reset uses `login/send_sms` with string type `3`, then `login/forget_pwd`. Email public reset contract must be confirmed if the server rejects the current paths with code 99.
- Check FAQ bold/color/size preservation, relative images, delayed image sizing and width changes.
- Check prompt cancel deduplication, device disconnect/switch, both update kinds, recovery priority and return from other screens.
- Run Swift syntax parsing and `git diff --check`. Native compilation and visual/device checks require Xcode, unavailable on this Windows host.

## Results and remaining checks

- Swift syntax parsing and whitespace checks passed. Native compilation and iOS runtime checks remain pending: Swift/Xcode is unavailable on this Windows host.
- Browser verification exercised the actual FAQ HTML/CSS and measurement script at widths 320, 390 and 768. Inline 18px font, color, bold, links, delayed image resizing and content-height reporting passed. This is browser verification, not an iOS WKWebView runtime test.
- Added PasswordRecoveryRequestTests.swift and its runner to packaging CI. It compiles the actual AuthService with a recording client and checks public phone-code/reset paths, JSON string type 3, request fields and absent authorization. Not executed locally.
- Domestic login/send_sms with JSON string type 3 returned code -1 / 请输入手机号 for an empty phone, and code -1 / 手机号输入错误 for invalid, without login. The current code-sending route already matches the supplied document.
- User confirmed the code-99 report concerns the phone entrance. Supplied logs do not contain the failed send-code request. Affected build number and matching HTTP request/response remain needed; do not describe this failure as verified fixed.
- Domestic login/forget_pwd with deliberately invalid/empty parameters returned HTTP 500 (系统发生错误). This does not establish whether a valid reset succeeds. Valid reset and old-password reuse require account-side testing.
- Email public reset is separate from the phone report: current user/send_modify_email_code and user/modify_password return code 99 without login. A public email recovery contract is still needed.
- Ordinary update dialog honors is_forced from the server; missing flags default to optional updates. Both update kinds use the existing detail flow. No OTA transport or build-number changes in these five fixes.
