# Sound mode single-line display and build 180

**Goal:** Keep `Sound mode` on one line, then deliver an installable build 180 including the already completed local fixes.

**Architecture:** Give the sound card an explicit one-line subtitle limit while retaining the default three lines for descriptive feature cards. Apply single-line fitting to the sound sheet heading. Use the established signed GitHub Actions packaging workflow and debugging profile used for build 179.

**User scope:** “修改完这个就打包吧，build+1”. Execute directly in this session. Version stays 1.1.6; build changes 179 → 180.

- [x] Add single-line fitting for the home sound card subtitle and the sound sheet heading in `HomeView.swift` / `SoundEffectModeSheet.swift`. Keep sound command values and callbacks unchanged.
- [x] Update both Xcode build configurations and the workflow artifact label to 180.
- [ ] Inspect syntax and the full included diff; commit the authorized fixes and dispatch the existing signed packaging workflow.
- [ ] Follow required regressions, archive and export to completion. Download the IPA and validate its version/build, signature resources, provisioning profile and archive integrity before delivery.

Physical-glasses behavior remains subject to device validation; packaging and automated checks do not replace hardware tests.
