# PR #124 second review: PH3b design v2 (docs only)

Branch `review/2026-10-05-pr124-design-review`, base = PR #124 branch. Nothing built, nothing run.
Skills: requesting-code-review (applied inline, no subagent: free-plan token budget), ponytail-audit (scoped to the PH3b diff, not whole repo), qt-qml-review (not applicable: zero QML in the diff).

## Verified against code (main @ 7ec2fc6 + PR #124)
- P3 real: `functions/index.js:105` `updateMarker: (patch) => markerRef.set(patch, { merge: true })`.
- `scopedDb(env)` returns a real Firestore handle per database (`index.js:51`), so `collectionGroup` works per env.
- `pending_cleanup` is already in `isServerOnlyCollection` (`firestore.rules:64`).
- Storage env prefix map differs from DB map only in `prd` vs `(default)`; P7 guard is needed and correct.

## Findings (new, not in P1-P10)
| ID | Sev | Finding | Suggested handling |
|---|---|---|---|
| R1 | Med | Q-K reads markers with `limit(MAX_SCAN=500)` and no order. Parked markers are never deleted, so they stay in the read forever. Once parked + not-due markers reach 500, newly failed markers can sit outside the window and are never swept; only a `backlog:true` ERROR log (which Q-L says nobody watches) shows it | Cheapest fix: after S-C, un-park or delete parked markers by runbook on a cadence; or page with `orderBy(documentId()).startAfter` (no index needed for `__name__`). Decide before prod. Dev-only today |
| R2 | Low | Q-L (no alert) + park at ~300 min + parked marker holds money data = a human must look. Documented as production blocker; acceptable now | Keep blocker. Do not let it slip: add to the pre-publish checklist, not only KNOWN-ISSUES |
| R3 | Low | `ponytail`: `DUE_SLACK_MS`, `GRACE_MS`, `BACKOFF_*`, `PARK_AT`, `MAX_SCAN`, `RUN_BUDGET_MS` = 7 constants for a dev-only sweeper. Not wrong; the slack constant is justified by a measured ~110 min error | Keep; no delete. net: -0 lines |

No Critical. No blocker for merging PR #124.
