# Firmware Download Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reject document/error responses before handing downloaded firmware to the glasses or OTA SDK.

**Architecture:** Add a Foundation-only payload validator and call it in the existing download completion handler. Keep the existing download URL, successful binary responses, BLE transport and recovery state behavior.

**Tech Stack:** Swift, Foundation URLSession, standalone swiftc regression tests.

**Spec:** User-provided 2026-11-13 18:15 logs: the `.ufw` GET returned HTTP 200, `Content-Type: text/html`, 2,578 bytes; those bytes reached `cmdOTAData` and produced `JL_OTAResultFailErrorFile` (0xF4). Earlier downloads of the same URL were 2,019,840-byte binary responses. Related analysis: `../analysis/gen1-bluetooth-ota-20261113-1815/findings.md`.

## Global Constraints

- Validate before `FirmwareDownloadClient.download` returns success, so the existing pre-handoff download order blocks invalid content before BLE disconnect or recovery-marker updates.
- Do not change BLE connection timeout/retry constants, packet format, firmware URL or release version/build.
- Accept binary firmware with generic or missing MIME type; no invented minimum firmware size or undocumented UFW magic.
- Preserve existing recovery evidence when download validation fails.
- Store HTTP status, headers, received byte count and rejection reason in diagnostics; do not log response bodies.

## Review Focus

- HTTP 200 HTML responses must fail even when nonempty and carrying the requested `.ufw` URL.
- HTML/JSON error documents mislabeled as binary must fail by content inspection.
- Valid binary with missing or vendor MIME type must remain accepted.
- Byte-count checking must not reject automatically decompressed responses based on compressed Content-Length.
- Empty and truncated bodies must fail without announcing successful download progress or initiating BLE handoff.

## Task 1: Validate firmware payloads before download completion

**Files:**
- Create: `AIGlass/Network/FirmwareDownloadValidation.swift`
- Modify: `AIGlass/Network/FirmwareDownloadClient.swift`
- Create: `Tests/FirmwareDownloadValidationTests.swift`
- Create: `Tests/run-firmware-download-tests.sh`
- Modify: `.github/workflows/ios-ipa.yml`

**Interfaces:**
- Consumes: downloaded `Data` and final `HTTPURLResponse`.
- Produces: `nonisolated static func FirmwareDownloadValidation.validate(_ data: Data, response: HTTPURLResponse) throws`; throws `ValidationError.emptyFile`, `.documentResponse` or `.lengthMismatch`.
- Client maps these errors to localized download messages and logs rejection before returning failure.

- [x] Write regression cases for the 2,578-byte HTML response, mislabeled HTML/JSON, valid binary MIME variants, empty body, identity length mismatch and compressed-response length handling.
- [x] Implement the pure validator and integrate before success logging/progress/completion.
- [x] Add the standalone macOS test script to the existing firmware checks in CI.
- [x] Run available syntax/whitespace/shell/workflow checks. Windows has no Swift/Xcode toolchain; Swift runtime tests and iOS compilation remain for the next authorized build.
- [x] Update analysis with the post-reboot failure, distinguishing it from the earlier loader reconnect timeouts. Review the final diff; leave build 177 unchanged.
