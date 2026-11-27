# AI recording duration display

The user supplied the AI Recording screenshot showing 00:12 in the file header and 00:13 beside the expanded playback slider for the same recording.

Both labels already derive from the same stored durationMs. AIRecordingItem.durationText truncated milliseconds, while AIRecordingItem.totalSeconds rounded to the nearest second and was used by the player. Values from 12,500 through 12,999 ms therefore produced the screenshot's one-second discrepancy; the screenshot alone does not establish this file's exact millisecond duration.

The header now formats AIRecordingItem.totalSeconds too. The existing playback rounding policy is retained. Previously stored recordings receive the same display fix automatically: no metadata migration, reimport or audio modification is required. Capture clocks, PCM/sample rates, file-duration extraction, progress seeking and playback are unchanged.

Local verification: exact edit read-back, full Swift syntax parse, both UI label references, arithmetic boundary review and Git whitespace checks pass. No native Swift compilation or physical playback was available on this Windows host. No package/build change; version remains 1.1.7 (187). The unrelated OTA working edit was preserved.
