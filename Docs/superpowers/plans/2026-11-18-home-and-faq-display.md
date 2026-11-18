# Home and FAQ display corrections

**Goal:** Correct the three display issues reported in the November 18 screenshots: oversized FAQ text, dimmed disconnected home actions, and wrapped English action labels.

**Scope:** `AIGlass/FAQHTMLText.swift`, `AIGlass/HomeView.swift`, and the adjacent short-label components. Keep build 179 and all BLE, recording, navigation, and disabled-action behavior unchanged.

- [x] Normalize FAQ HTML text to a 14px body baseline and a maximum 20px heading. Determine the authored body size from visible text before changing styles; scale oversized inline fonts proportionally. Preserve bold, colors, links, images, and content-height updates. Check the actual backend FAQ (28/32/36px fonts) plus ordinary HTML at 320/375/390/430px.
- [x] Replace the home action grid's plain button style with a local style that preserves its normal colors when disabled. Keep every existing disabled condition. Keep the disconnected glasses image at 50% and the volume control unavailable while disconnected.
- [x] Reserve space for one-line action titles with smaller adaptive media icons, explicit single-line sizing, and concise English progress labels. Apply the same single-line fitting to home feature/guide headings and nearby translation, sound-mode, and tab labels. Descriptions remain multiline.
- [x] Inspect the exact changed Swift syntax and diff. Verify FAQ rendering and font sizes with real HTML in a browser. Verify English label widths using the bundled app font; the changed production components were also compiled and rendered in a temporary iOS simulator probe. Full app and physical-device verification remain separate.

Execution: implement directly in this session under the user's existing fix request. No new package or version bump requested.


Verification completed:
- Actual FAQ response: body 28px -> 14px, headings 36px -> 18px / 32px -> 16px; rich color, bold, links, delayed image sizing and scroll width preserved.
- Browser checks at 280/335/350/390/728px content widths; 90 Chinese/English title measurements across 320/375/390/430/768px screen widths.
- Swift source syntax and all eight home action disabled conditions checked; existing glasses-image opacity remains 0.5 while disconnected.
- Native iOS simulator probe compiled the exact changed home card/button style and FAQ sources. First probe rendered enabled and disabled card areas with identical pixels. Second probe rendered the production assets on iPhone 13 mini: full-color disabled icons and single-line English titles confirmed. The iPhone 16 screenshot in the second probe captured a launch transition and is excluded; that run was cancelled after screenshots/artifacts had uploaded, during runner cleanup.
- Reviewed adjacent labels: translation entry cards, conversation recording buttons, sound-mode choices, device status, and bottom tabs. Descriptions and FAQ paragraphs intentionally remain multiline.
- No build bump or new deliverable IPA in this fix task.

## AI vision mode wording follow-up

- [x] Match the new reference image: title `智能图像识别模式选择`; options `极速 / 标准 / 精细 / 极致`, each with its supplied explanation. The final explanation uses the screenshot's `最高清的画质和最准确的识别率，耗时较长`.
- [x] Replace the title-only system action list with a compact selector that can display descriptions and the current checkmark. Reuse the existing save/sync callback and retain raw values 0/1/2/3.
- [x] Use the matching Android English resource wording, check compact-width text and Swift syntax. No package/build change.

AI vision validation: Xcode simulator run 44301051884 passed. Compiled exact production dialog/settings/radio/theme/protocol with an iOS 15 deployment target, rendered Chinese and English on iPhone 13 mini and reviewed both screenshots. All four titles, explanations, checkmark and Cancel are visible. Source checks confirm unchanged raw-value mapping, preference storage and BLE synchronization callback; new source uses the project's synchronized source folder. Physical-glasses verification remains pending.
