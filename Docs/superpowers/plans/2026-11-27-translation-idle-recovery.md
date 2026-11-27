# Translation idle recovery implementation plan

**Goal:** Adapt the app to the user-confirmed backend policy of closing an application session after 60 seconds without activity, and bound recovery of translation-address lookup failures.

**Architecture:** Keep the existing connection-attempt generation and send queue. Add pure startup/idle policies in the existing translation state source; use them from the shared manager and validate reusable readiness before simultaneous recording. Conversation recording already creates a new manager for each turn.

**Tech Stack:** Swift, Foundation URLSession, existing AVFoundation capture/playback, existing standalone Swift regression suite.

**Spec:** User requests in this chat on November 27, 2026: implement app-side recovery, then confirms the 60-second server idle policy. The failed HTTP address lookup is still a separate failure from idle WebSocket closure.

## Constraints and review focus

- Analyze, edit and independently verify locally. No cloud job, package or build change without a packaging request.
- Preserve the unrelated `DeviceOtaUpgradeDetailView.swift` working change.
- Retry only the idempotent translation-address GET, once, for selected URL transport errors. Never retry auth/business/certificate failures or cancellation; never replay captured/sent PCM.
- Stop/cancel/page exit must invalidate lookup, backoff and old callbacks. Do not extend deadlines when repeated progress arrives.
- Preserve current recordings, final-result draining, playback and saved transcripts. Quietly retire only idle sessions, after pending sends/speech have drained.

## Changes

- [x] Separate startup phases and budgets: 8-second lookup, at most two lookups with 500 ms backoff, combined 10-second socket/service-ready budget, 30-second total cap.
- [x] Make APIClient.getRaw accept an optional request timeout, defaulting to its existing 20 seconds. Translation explicitly supplies 8 seconds instead of having its session timeout overridden by the shared request.
- [x] Keep a fresh ephemeral transport for each lookup and preserve attempt-generation/cancellation checks after suspension.
- [x] Track reusable readiness from service ready / successfully sent PCM; ping/pong does not refresh application activity. Expire reuse at 50 seconds, before the documented 60-second backend limit.
- [x] Quietly close idle sockets and clear controller readiness. Reconnect before simultaneous microphone capture when reuse is stale. Active/startup failures retain the existing error/stop flow.
- [x] Align conversation's secondary UI timeout to one second after the shared total cap, avoiding its old 20-second premature cancellation.
- [x] Add 22 deterministic policy assertions to the existing translation regression suite.
- [x] Parse all changed Swift sources; generate/parse the existing production-method playback regression fixture; check source ownership, playback preservation, scoped diffs and whitespace.
- [ ] Run the native Swift regression suite and app build during a user-requested packaging run.
- [ ] Verify on iPhone: leave the page idle for over one minute, start again; cancel during backoff; switch recording inputs; simulate active transport loss and recover.

## Verification and limits

Local syntax and source-contract checks pass. New state assertions are prepared in the suite already required by the packaging workflow, but have not run on this Windows host (no Swift/Xcode runtime). Native compilation, the actual backend idle-disconnect exchange and microphone behavior remain unverified. No change to the backend or evidence that the original HTTP failure was caused by its WebSocket idle policy is claimed. Version/build remain 1.1.7 (187).
