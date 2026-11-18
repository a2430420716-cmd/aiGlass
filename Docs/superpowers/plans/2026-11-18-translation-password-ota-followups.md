# Translation, password routing and reminder follow-ups

**Goal:** Resolve the four November 18 reports: a disabled-looking translation replay icon, phone password route verification, oversized OTA reminder, and three English labels.

**Architecture:** Correct the replay asset without changing audio playback. Keep phone password recovery and authenticated change as separate page/service routes. Let reminder release notes size to their actual content with a scroll limit. Use consistent English labels in cards and options.

**Constraints:** Preserve previous local changes; no packaging or build increment. User confirmed password routing scope is phone only; leave email contracts unchanged.

- [x] Replace the conversation message's glasses-speaker-off image with the Android glasses-speaker-on asset. Logs at 14:48:55.503 show phone microphone capture and Bluetooth A2DP playback to Astra A1 0209; the icon is a replay destination, not a mute setting.
- [x] Check phone forgot-password uses `login/forget_pwd` without authorization; phone change-password uses `user/change_pwd` with type string `2` and login authorization. Extend the request recorder regression to cover both paths; no live password changes or SMS.
- [x] Size the OTA reminder notes to their content, cap long notes for scrolling, reduce padding and button height while preserving forced-update cancellation rules and existing update action.
- [x] Set the sound selection option to `Dynamic`; verify `Sound mode` and `Tutorial` across current user-facing sources.
- [x] Check syntax/diff and compile/render actual changed UI components in Chinese and English. Run password request regressions; retain physical-device verification as a separate check.

**Validation:** Native check [44317763767](https://github.com/liuguang247/AIGlass/actions/runs/44317763767) passed using source SHA-256 manifest. Actual AuthService and UserService request regressions passed; exact OTA dialog and sound sheet compiled under Swift 6. Visually checked eight iPhone 13 mini screenshots: short/long notes, ordinary/forced update, sound options, Chinese/English. Short notes no longer reserve the long scroll region; forced offers omit Cancel; Dynamic and Sound mode fit on one line. Local syntax parsing passed for 16 edited Swift files; diff whitespace check passed. Build remains 179. No full app package or physical-device audio/upgrade run performed.
