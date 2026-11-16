# English Copy Alignment Implementation Plan

**Goal:** Align existing iOS page translations with the supplied November 13 English reference.

**Architecture:** Keep existing `L10n.t` calls and replace their English literals in place. Match Android resource keys through the existing Chinese resource file, then review ambiguous matches in their iOS context. Preserve Chinese, interpolation expressions, protocol values, language selection, and existing local edits.

**Tech Stack:** Swift / SwiftUI, Python for resource inventory and static verification, Tree-sitter for Swift literal boundaries.

**Spec:** `D:/xwechat_files/wxid_8zda02e5j9ee22_b546/msg/file/2026-11/strings EN 1113.xml`

## Constraints

- Apply page copy, including corresponding alerts and user-facing status messages; preserve iOS-specific permission guidance and unsupported Android-only features.
- Keep generation labels removed, as previously requested; do not import obsolete availability restrictions or demo content.
- Preserve Swift interpolation and all code outside reviewed English literals.
- Resolve context-specific labels separately: translation card/page, close/off, placeholder/validation, title/prefix, action/status.
- Do not bump build or package without a request.

## Tasks

- [x] Inventory 890 supplied string resources and existing iOS `L10n.t` pairs; tolerate bare ampersands in the reference as text.
- [x] Review exact, ambiguous and unmatched page copy; record per-occurrence resource decisions in `analysis/translations-en-20261116`.
- [x] Update 335 English literals across 51 existing Swift files, preserving existing edits.
- [x] Verify every changed string against the chosen reference, interpolation counts/expressions, and unchanged surrounding code. Parse modified Swift files and run `git diff --check`.
- [x] Record changed counts and remaining platform-specific limitations. Xcode / visual device validation is unavailable on this Windows host.

No new runtime mechanism or unit tests are needed for this copy-only change. Implementation proceeds in this session within the user's requested scope.
