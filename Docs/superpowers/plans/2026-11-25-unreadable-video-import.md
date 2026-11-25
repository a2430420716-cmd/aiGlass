# Import downloaded videos even when playback is unavailable

**Goal:** Fully downloaded but undecodable videos enter the App album normally. Only opening playback reports failure; they no longer remain in the local-processing retry banner. Preserve original bytes, complete-download checks, account/UUID ownership, cancellation and durable manifest handling. No packaging or version change.

**Evidence:** Wi-Fi log 20261125_104419 repeatedly processes the same local file 2026-11-25-09-51-01.mp4 and receives AVFoundation -11829 before stabilization. These are local decode failures, not evidence of a new failed transfer or proof of how the camera damaged the file.

**Architecture:** Keep the validator as a read-only enhancement gate. When it reports an unreadable original, bypass native stabilization/rotation, copy the preserved complete original into the album and create a video placeholder. Store an optional unreadable-video flag, compatible with existing manifests. Skip automatic Photos export for known undecodable media so Photos rejection does not retain the App inbox entry. Show failure upon opening known unreadable media and observe AVPlayerItem.status for runtime decode failures.

**Files:** Gen1VideoImportPipeline.swift, MediaLibrary.swift (both Gen1 and HTTP import), MediaImportManager.swift, AlbumMediaDetailView.swift; update pipeline/validator regression tests and manifest compatibility checks. Preserve previous pending fixes and unrelated OTA edits.

- [x] Add a byte-preserving unreadable-original path that bypasses enhancement and retains cancellation/path checks.
- [x] Commit media, placeholder thumbnail and manifest; only then allow inbox cleanup. Normal readable media keeps processing.
- [x] Separate unsupported Photos export and playback errors from App import completion.
- [ ] Check broken-media bypass, exact bytes, no enhancement calls, cancellation and old-manifest compatibility. Native tests/compilation require a Mac runner; GitHub billing currently prevents startup.

**Local checks:** `analysis/unreadable-video-import-20261125/source_check.py` passed parsing of six modified Swift sources plus the extracted manifest model, shell syntax, source integration checks for the unchanged-byte fallback, video placeholder generation, archive/manifest commit before inbox cleanup, Photos bypass and AVPlayer status handling. Original TCP download validation, inbox completion checks, archive hashing and read-only video validation match HEAD. This is source inspection, not execution of Swift or AVFoundation.

**Regression coverage prepared:** Existing pipeline tests now cover rejected native enhancement callbacks for unreadable recordings, exact source/output bytes, source retention, actual copy failure, old manifests without the flag, flag persistence across reload and cancelled raw imports. Validator tests combine AVFoundation rejection of a broken MP4 with the raw-copy path. Both runners are included in CI. They have not run on a Mac: the account's billing/spending restriction blocked runner startup earlier this session. No full iOS compilation or real-device playback was performed; no archive/IPA or version change.

**Additional handling:** Readable-metadata files whose rotation/export or thumbnail decode fails also fall back to the original bytes or a preview placeholder. A decode/preview failure alone cannot discard a fully downloaded video. Missing sources, cancellation, write failures and manifest failures remain errors.
