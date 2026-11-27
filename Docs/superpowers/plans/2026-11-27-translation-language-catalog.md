# Align translation languages with the supplied Android app

> Implement locally in this session; preserve version 1.1.7 (187) and the unrelated OTA detail view edit. Native verification runs only as part of a requested package.

**Goal:** Both conversation translation and simultaneous interpretation expose the Android app's complete 60-language catalog, with matching Chinese/English labels, ordering and request codes.

**Reference:** The user's `glasses(3).zip`, `app/src/main/res/{values,values-zh,values-en}/strings.xml`: `translation_languages` and `translation_language_codes`. Android's two translation controllers index these arrays; Norwegian is `nb`, Filipino `fil`, Cantonese `yue`, Asturian `ast`.

**Approach:** Keep the existing `TranslationLanguage` enum API, fill its catalog and use it through the existing shared picker. Resolve Chinese/English labels and ISO codes consistently. Preserve the old Nepali case for stored records, while the selectable catalog matches Android's 60 options. Retain default Chinese/English labels and existing recording/translation routing.

- [x] Import the exact 60 label/code triples, confirm them against the supplied ZIP and align selectable order.
- [x] Keep language selection, default/fallback and saved-language decoding consistent across both translation screens and history.
- [x] Add a native catalog contract test using Android-derived expectations and wire it into package validation.
- [x] Check catalog equality, source/probe syntax, shell syntax and preserved source locally. Do not claim native execution, backend recognition/TTS support or rendered device validation.

**Local verification:** Parsed the iOS case/metadata pairs and compared all 60 Chinese names, English names, codes and ordering directly with the original `glasses(3).zip`, including `values-zh`. All entries match and have unique names/codes. Swift source and test syntax, Bash syntax and Git whitespace checks pass. Both translation pages still use the same picker and code conversion; script filtering accepts the additional language codes. Version/build and the unrelated OTA edit hash are preserved.

The native regression suite validates each entry through Chinese, English and code resolution, both picker locales, same-language fallback and legacy labels. It is wired into the existing package workflow but has not executed on this Windows host. No cloud task, new IPA or live translation request was made; actual recognition/translated speech for the expanded catalog requires device/backend validation.
