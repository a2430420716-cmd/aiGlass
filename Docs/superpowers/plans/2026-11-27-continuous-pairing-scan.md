# Continuous discovery during pairing service verification

**Goal:** Reduce the additional search wait caused by verifying one candidate while losing advertisements from other glasses. User reports adding new glasses still searches slowly; no new timing log accompanies this report.

**Confirmed source bottleneck:** Manual candidates lacking generation service UUIDs require serial GATT verification. `connect(to:probing:)` previously stopped scanning, and `didDiscover` discarded every advertisement once the connection state left scanning. A stalled/weak candidate therefore paused both verification and radio discovery for other nearby candidates. Cached-name prioritization could also put a weaker L1-named candidate ahead of a stronger matching candidate.

**Implementation:** Retain the physical scan only for active manual service probes, accept advertisements during that precise state, and order the pending service-verification queue by RSSI. Actual GATT connections remain serial. Current advertised-name/model checks, device_type/advertised-or-GATT generation verification, stale-tap rejection, name-change revocation, final pairing and row order are preserved. User-selected and ordinary background/reconnect connections continue stopping/admitting scans as before.

- [x] Add shared pure admission policy and scope the scanning exception to manual verification only.
- [x] Update connect/discovery admission and RSSI queue scheduling.
- [x] Add six policy regression assertions to the existing required production-source scan suite.
- [x] Verify changed Swift method syntax, Python generator syntax, actual generated probe syntax, exact read-back, preserved guard implementations and Git whitespace locally.
- [ ] Run native regression/build checks during user-requested packaging.
- [ ] Measure scan start, first matching advertisement, GATT verification and visible-row timing on iPhone with multiple glasses and a weak/unresponsive candidate.

The change reduces a confirmed source-level serial wait; it does not establish why the user's latest attempt was slow or guarantee a fixed discovery time. A first candidate may still wait for its own broadcast/name/service verification. Current-name filtering intentionally remains strict to prevent renamed L2 devices appearing under L1. No native compiler, radio timing or device run was available on this Windows host. The November 27 local changes have not been delivered in a new IPA. Version/build stay 1.1.7 (187); the unrelated OTA view edit remains untouched.
