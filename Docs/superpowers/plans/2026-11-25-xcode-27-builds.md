# Xcode 27 build environment implementation plan

> **For agentic workers:** Implement this plan in the current session. Verify the changed pipeline using a remote macOS compilation before claiming success.

**Goal:** Future packages use released Xcode 27.1 and iOS 27.1 SDK, satisfying the announced iOS 27 SDK submission floor.

**Architecture:** Use GitHub's documented `xcode-27` runner with the installed `/Applications/Xcode_27.1.app/Contents/Developer`. Check the active Xcode and SDK before dependencies/tests, and check the archived application's actual metadata before exporting.

**Tech Stack:** GitHub Actions, Xcode 27.1, Python 3, CocoaPods.

**Spec:** User asks that future packages use Xcode 27 or newer and iOS 27 SDK or newer. Runner manifest: https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md . It lists released Xcode 27.1 (27A9275) and iOS 27.1; the earlier preview announcement is not the current installed-version list.

## Global constraints

- Keep marketing version 1.1.7 and build 183; do not create replacement IPAs in this task.
- Keep iOS 15.0 minimum, current app behavior and separate production/testing diagnostic policies.
- Preserve the existing unstaged `AIGlass/DeviceOtaUpgradeDetailView.swift` edit outside this change.
- Do not use preview/beta Xcode paths for production; use the documented released 27.1 path.

## Review focus

- Verify both Xcode and iPhoneOS SDK versions; they need not have matching minor versions.
- Reject an archive built using an older SDK even if its source configuration requests a newer toolchain.
- Run host tests on the new ARM64 runner and compile all iOS sources/dependencies without signing.
- Validate emitted Info.plist SDK metadata, iOS minimum, build and production logging flag.

## Task 1: Update and verify the toolchain

**Files:** `.github/workflows/ios-ipa.yml`, `scripts/build-ios-ipa.sh`.

- [x] Select `xcode-27` and released Xcode 27.1, and fail early if Xcode or iOS SDK major version is below 27.
- [x] Verify archive `DTXcode` and `DTSDKName` before exporting an IPA.
- [x] Check shell/YAML syntax and unchanged version, minimum OS and unrelated local edit.
- [x] Upload the exact changed snapshot to an isolated validation branch; run existing native workflow checks and an unsigned production iOS build with Xcode 27.1. Confirm actual metadata uses iOS SDK >= 27 and production diagnostics are disabled.
- [x] Commit and push only this build-environment change after validation. No packaging or App Store upload.

**Validation evidence:** https://github.com/a2430420716-cmd/aiGlass/actions/runs/45574096910 succeeded: all native check groups and the complete unsigned Release iOS build passed. Emitted app metadata: `DTXcode=2710`, `DTXcodeBuild=27A9275`, `DTSDKName=iphoneos27.1`, `MinimumOSVersion=15.0`, version 1.1.7 (183), production diagnostics `NO`. Local archive-guard checks accept Xcode/SDK 27 and newer, and reject older or missing metadata. The staged workflow and script match the validated snapshot; existing unrelated OTA edits are preserved. This verification did not sign, archive or export a new IPA; the previously delivered 183 packages remain built with the earlier SDK.
