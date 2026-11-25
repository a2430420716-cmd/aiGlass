# Release diagnostics implementation plan

**Goal:** Disable App debug logs and floating controls in production while retaining diagnostics in development/testing packages. Keep version 1.1.7 (182); packaging is paused by the user.

**Architecture:** Shared compile-time policy for the Swift logger, console output, Objective-C wrappers and SDK logging. Local Debug enables diagnostics; local Release disables them. The packaging script explicitly enables `AIGLASS_DIAGNOSTICS` for `debugging`/`release-testing` and forces `AIGLASS_PRODUCTION` for `app-store-connect`/`enterprise`, because both package kinds currently archive with Release. Production overrides inherited diagnostic flags.

**Review focus:** Hide the panel and stop recording; prevent export files; skip formatting and console interpolation when off; keep SDK configuration separate from business commands; verify testing archives retain diagnostics.

- [x] Add shared Swift/Objective-C policy and guard overlay, store, console and SDK logging.
- [x] Configure flags from export method, with a metadata check before IPA export.
- [x] Verify default Release, local Debug, testing Release and mixed flags; check all log channels and console side effects.
- [x] Run native logging checks and unsigned iOS compilation only; do not archive or export IPA.

**Validation:** [Run 45539916704](https://github.com/frankqianghe/AIGlass/actions/runs/45539916704) succeeded against source snapshot `51f6cb31f7c8902a3945c86959c445e397ea9817`. Ruby export-method checks and all four Swift/Objective-C configurations passed, covering console suppression, eleven log entry points, four channels, body/header formatting and text/file exports. Existing BLE diagnostics passed 55 formatter/budget assertions and six store assertions. The complete unsigned Release iOS app compiled successfully; its Info.plist verified version 1.1.7 (182) and disabled production diagnostics. The uploaded source manifest matches the local staged implementation. Packaging run `45532489732` remains cancelled; no archive or IPA was generated.

**Validation fixes:** Use Bash 3.2 compatible optional arrays; run host tests with the project's Swift 5 language mode and fixed bundle metadata instead of UIKit; explicitly expand the custom log marker in the source Info.plist. The existing BLE log test now includes the shared diagnostic policy and enables the testing flag.
