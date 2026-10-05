# Test plan — PH3b scheduled cleanup function (`pending_cleanup` sweeper)

**Design:** `../specs/2026-09-30-photos-s3-s4-design.md`, section "PH3b — design v2" (review P1-P10, decisions Q-J / Q-K / Q-L).
**Branches (planned):** `feat/2026-10-05-ph3b-sweeper-lib` (S-A), `feat/2026-10-05-ph3b-sweeper-binding` (S-B), `feat/2026-10-05-ph3b-sweeper-e2e-docs` (S-C).
**Status:** **S-A implemented 2026-10-05** (branch `feat/2026-10-05-ph3b-sweeper-lib`): sections 1.1-1.5 are written and green in the sandbox, functions suite 560/560 (491 baseline + 69), `lib/photoCleanup.js` line/branch/function coverage 100% (`node --test --experimental-test-coverage test/photoCleanup.test.js test/cleanupSweep.test.js`). Sections 2-4 (functional, e2e, real project) NOT written yet (S-B, S-C). **S-B implemented 2026-10-05** (branch `feat/2026-10-05-ph3b-sweeper-binding`, stacked on S-A): section 2 written and green in the sandbox in `functions/test/index.handlers.cleanupScheduler.test.js` (19 cases: FS01-FS10 as planned plus FS02b, FS11, FS11b, FS12-FS17) and 6 new unit cases UT01-UT06 for the `timestampToMs` helper; functions suite 585/585 (560 + 25), `photoCleanup.js` still 100% line/branch/function; no uncovered line in the new `index.js` block. Mutation-checked: 5 deliberate binding bugs (set+merge, no cursor, no parked flag, run never throws, wrong database) each failed the suite. Sections 3-4 (e2e, real project) NOT written yet (S-C, Taher). Cases added beyond the plan during S-A: US14 (junk input), UR11b (park throws at the cap), UR14b (notDue count), UR16b (unparsable path), UR19 (monkey over `runCleanupSweep`), 4 small `runCleanupSweep` cases (junk sweep result, marker built from path id, garbage `listMarkers`, actor fields kept), 1 `readAllMarkers` defaults case. **Final sweep (same day) added US15, UR09b, UR17b and changed UR17/UR04** (see S1/S2 in the spec review ledger): a THROWN sweep now raises `PH3B_ALERT sweep-threw` instead of a silent WARNING, and a stored `prefix` that is not the rebuilt prefix is malformed at once. **Deviation from design v2:** `park(env, path, reason)` instead of `park(env, tenantId, productId, reason)` (a malformed marker may have no parsable path, the doc is addressed by its path; S-B binds `db.doc(path).update(...)`). Summary `parked` = already-parked + newly parked at the cap; `malformed` counted separately. Node cases run in the sandbox; the emulator e2e and the real-scheduler checks are CI / on-project only.
**All design decisions taken 2026-10-05 (Taher): Q-J park at 12 with backoff 10/20/30/30 min; Q-K no index, due time computed in code; Q-L amended to a log-based alert (Taher creates it at deploy; R1 amended Q-K to a paged read).** Tests import `PARK_AT`, `GRACE_MS`, `DUE_SLACK_MS`, `BACKOFF_STEP_MS`, `BACKOFF_STEPS` instead of hard-coding them. If Q-K is ever reopened to the index design, sections 1.3, 1.4, 2 and 3 (E1-E4) must be rewritten.
**Planned totals:** unit 57, functional 10, e2e 5, real-project (DV) 9. **Actual unit after S-A + final sweep: 69** (34 in `photoCleanup.test.js` added by S-A, 35 in `cleanupSweep.test.js`, counted with `grep -c "^test("`); functional/e2e/DV still planned.
**Coverage target (user rule: 100% of new code):** line AND branch coverage of every new function in `functions/lib/photoCleanup.js` = 100%, measured with `node --test --experimental-test-coverage` (sandbox Node 22; availability of the flag on CI's Node is UNVERIFIED, so CI does not gate on it). `index.js` binding lines are covered by section 2 plus E1-E4.

## 1. Unit (Node, `functions/test/photoCleanup.test.js` extended + new `functions/test/cleanupSweep.test.js`)

### 1.1 `parseMarkerPath` (8)
| ID | Case |
|---|---|
| UP01 | `tenants/T1/pending_cleanup/PRD-1` -> `{tenantId:"T1", productId:"PRD-1"}` |
| UP02 | wrong collection name (`tenants/T1/locks/PRD-1`) -> null |
| UP03 | deeper path (`tenants/T1/x/y/pending_cleanup/PRD-1`) -> null |
| UP04 | root-level `pending_cleanup/PRD-1` (no tenant) -> null |
| UP05 | empty segment (`tenants//pending_cleanup/PRD-1`, trailing slash) -> null |
| UP06 | unsafe segments: `..`, `a b`, `a.b`, `a%2Fb`, 65 chars, non-ASCII -> null (matches `isSafePathSegment`) |
| UP07 | non-string input (null, undefined, number, object) -> null, never throws |
| UP08 | MONKEY: 2000 random strings (printable + control + unicode); never throws; any non-null result has both segments passing `isSafePathSegment` |

### 1.2 `delayMs` (7)
| ID | Case |
|---|---|
| UD01 | attempts 0 -> `GRACE_MS` (90 s) |
| UD02 | attempts 1, 2, 3 -> 1x, 2x, 3x `BACKOFF_STEP_MS` |
| UD03 | attempts 4, 11, 1000 -> capped at `BACKOFF_STEPS` x step |
| UD04 | negative -> `GRACE_MS` |
| UD05 | NaN, Infinity, `"3"`, null, undefined, object -> `GRACE_MS` (non-finite or non-number is treated as 0) |
| UD06 | fractional (2.5) -> deterministic, no throw (floor or ceil, pinned by the test) |
| UD07 | monotonic non-decreasing for attempts 0..50 |

### 1.3 `selectDue` (13; four groups must partition the input)
| ID | Case |
|---|---|
| US01 | fresh marker inside grace -> notDue |
| US02 | boundary is `nowMs + DUE_SLACK_MS >= dueAtMs`: exactly `GRACE_MS - DUE_SLACK_MS` after `createdAtMs` -> due; one ms earlier -> notDue |
| US03 | `lastAttemptAtMs` wins over `createdAtMs` for the due time |
| US04 | **regression P1**: legacy marker (no `lastAttemptAtMs`, no actor fields, no `nextAttemptAt`) -> due once the grace has passed |
| US05 | `parked: true` -> parked group, never due (also with attempts 0) |
| US06 | `parked: false` / absent / `"true"` string -> not treated as parked (only boolean `true` parks) |
| US07 | **P8**: body `productId` differs from path id -> malformed |
| US08 | **P7**: marker `envPrefix` `"prd"` scanned under expected `"dev1"` -> malformed |
| US09 | missing / non-string `prefix`, missing `envPrefix` -> malformed |
| US15 | **final sweep S2**: stored `prefix` not EXACTLY the prefix rebuilt from env + path ids (other product / tenant / env, no trailing `/`, widened to `products/`, `null`, leading space) -> malformed `bad-prefix`; correct prefix still due; unsafe `envPrefix` equal to the scanned env -> malformed |
| US10 | `createdAtMs` missing, NaN, negative -> malformed |
| US11 | due list sorted by `dueAtMs` ascending (oldest first), stable for ties |
| US13 | **tick slack**: marker with attempts 1 failed at tick+5 s is NOT due 9 min later but IS due at the next tick (tick+10 min); same with attempts 3 (30 min) |
| US12 | MONKEY: 5000 random markers (random types per field, random nowMs); never throws; sum of the four groups == input length; no marker in two groups |

### 1.4 `runCleanupSweep` (14 planned; 17 written incl. UR09b, UR17b, UR19, fakes only)
| ID | Case |
|---|---|
| UR01 | happy path: 3 due markers in 1 env -> `sweep` called 3 times oldest first; summary `swept:3`, `envFailures:0` |
| UR02 | empty run: no markers in any env -> no `sweep`/`park` call, all counters 0, no throw |
| UR03 | env isolation: `listMarkers` throws for env 2 -> env 1 and env 3 still processed, `envFailures:1`, env 2 summary has `error` |
| UR04 | marker isolation: `sweep` throws for marker A -> marker B still swept, A counted `failed`, one `sweep-threw` alert (S1) |
| UR05 | `sweep` returns `{ok:false}` below the cap -> `failed`, `park` NOT called |
| UR06 | `sweep` returns `{ok:false}` at `attempts + 1 == PARK_AT` -> `park` called once with the sweep's error text |
| UR07 | `sweep` returns `{dropped:true}` -> `droppedIdReuse` +1, no park |
| UR08 | budget: injected clock advances past `RUN_BUDGET_MS` after the 2nd marker -> 3rd and later `deferred`, none parked, none swept |
| UR09 | malformed marker -> `park` immediately with reason `malformed-marker: ...`, `sweep` never called for it |
| UR09b | **final sweep S2**: wrong stored prefix (4 variants incl. widened `products/`) -> parked at once, reason `malformed-marker: bad-prefix`, `sweep` never called, one alert |
| UR10 | parked marker skipped: never swept, counted `parked` |
| UR11 | `park` throws -> counted `failed`, run continues with the next marker |
| UR12 | `listMarkers` reports `backlog:true` -> summary `backlog:true` and an ERROR log line containing `PH3B_ALERT` |
| UR13 | **crashed sweep (old E7)**: marker with attempts 0 whose handler died (age > grace) -> swept on the next run, marker gone |
| UR14 | summary shape: each env summary has exactly the documented keys; one `log` call per env |

### 1.4b `readAllMarkers` paging, R1 (7) and alert logging (4)
| ID | Case |
|---|---|
| UL01 | empty first page -> `{docs:[], backlog:false}`, `fetchPage` called once |
| UL02 | one short page (< pageSize) -> all docs, `backlog:false`, one call |
| UL03 | exactly `pageSize` docs then an empty page -> all docs, `backlog:false`, two calls (a full page does not mean more exist) |
| UL04 | 3 pages (full, full, short) -> docs concatenated in page order, no duplicates, cursor passed is the previous page's last doc |
| UL05 | `maxPages` full pages -> `backlog:true`, exactly `maxPages` calls, never more (loop guard) |
| UL06 | `fetchPage` throws on page 2 -> error propagates, no partial result returned |
| UL07 | MONKEY: 300 random (pageSize, maxPages, total) triples against a fake paged store; docs == first `min(total, pageSize*maxPages)` in order, `backlog` correct, calls <= maxPages |
| UR15 | marker parked at the cap -> one ERROR log whose message starts `PH3B_ALERT` with `env`, `tenantId`, `productId`, `reason` |
| UR16 | malformed marker parked -> same `PH3B_ALERT` ERROR log, reason starts `malformed-marker` |
| UR17 | sub-cap `{ok:false}` failure -> WARNING log only, NO `PH3B_ALERT` anywhere (alert noise guard) |
| UR17b | **final sweep S1**: a THROWN `sweep` (Error, string, undefined) -> exactly one ERROR `PH3B_ALERT sweep-threw` per run, no WARNING, never parked, counted `failed` |
| UR18 | env-level failure (`listMarkers` throws) -> `PH3B_ALERT` ERROR log with `env`, run still throws at the end |

### 1.5 `sweepMarker` changes (4)
| ID | Case |
|---|---|
| UM01 | failed sweep patch contains `lastAttemptAtMs == deps.now()` plus `attempts + 1` and truncated `lastError` |
| UM02 | no `deps.now` supplied -> `lastAttemptAtMs` is a finite number (default clock) |
| UM03 | `unsafe-sweep-prefix` failure also stamps `lastAttemptAtMs` |
| UM04 | success and id-reuse drop write no patch |

## 2. Functional (Node, handler harness; the harness gains `update` and `collectionGroup`) (10)
| ID | Case |
|---|---|
| FS01 | `cleanupPendingMarkers` is exported; its trigger metadata: schedule `every 10 minutes`, region `asia-south1`, timeout 300, maxInstances 1, retryCount 0 (metadata property path UNVERIFIED, confirm when writing) |
| FS02 | **regression P3**: sweep fails, but the marker was deleted by a concurrent sweeper before `updateMarker` -> the marker is NOT re-created |
| FS03 | `.run()` happy path: marker + 3 `stock_batches` + 2 Storage files -> batches and files gone, marker gone, 3 `cascade~` audit docs |
| FS04 | legacy marker from #113 (no actor fields) swept; audit actor is `system` |
| FS05 | **P7**: `prd` marker inside the `dev1` database -> parked, Storage untouched |
| FS06 | env-level failure (read throws) -> `.run()` rejects at the END, after the other envs ran |
| FS07 | per-marker failures only (Storage throws for every marker) -> `.run()` resolves |
| FS08 | handler sweep and scheduler sweep of the same marker in parallel -> no duplicate audit docs, no zombie marker, files gone |
| FS09 | id reused (product doc exists again) -> marker dropped, files and batches untouched |
| FS10 | full lifecycle with a controllable clock, ticks every 10 min: fail -> not retried inside the backoff -> retried after it -> **12th failure lands ~300 min after the first (+-1 tick), not ~410** -> parked + ERROR log -> next run skips -> un-park (`parked:false, attempts:0`) -> swept |

Rules (emulator, CI): **no new rules case.** Markers are already server-only (R01-R05, R11); the Admin SDK used by the scheduler bypasses rules by design. Pin only: R01-R05 stay green.

### 2.1 Added beyond the plan during S-B (all green)
| ID | Case |
|---|---|
| FS02b | failed sweep of a LIVE marker updates it in place: `attempts+1`, `lastError`, `lastAttemptAtMs`, every other field kept, never `set()` |
| FS11 | paging: 450 fresh markers -> 3 reads of `PAGE_SIZE`, cursor = previous page's last doc, `scanned 450`, nothing deleted |
| FS11b | `MAX_SCAN + 5` markers -> exactly `MAX_PAGES` reads, `backlog:true`, ERROR `PH3B_ALERT backlog` |
| FS12 | three databases + several tenants in one run, each marker swept only under its own env prefix; decoy files of the same tenant/product under other env prefixes survive |
| FS13 | `park` throws at the cap -> run resolves, marker not parked, ERROR `PH3B_ALERT park-failed` |
| FS14 | MONKEY: 5 seeds x 36 random markers (9 flavours: fresh, old, parked, wrong env prefix, bad createdAt, no prefix, id mismatch, id reused, legacy) x 25 ticks with 40% random Storage failures; protected files survive, parked docs unchanged, no `set()` on markers, no zombie, attempts <= `PARK_AT`, every Storage sweep targets a sweepable seeded prefix |
| FS15 | `createdAt` string -> malformed `bad-created-at` parked, Storage untouched; plain-number `createdAt` accepted |
| FS16 | already-parked marker: never swept, never re-parked, never re-alerted over two runs |
| FS17 | a THROWN sweep (Storage bucket cannot be created) -> WARNING + `failed`, never parks, attempts unchanged, run resolves |
| UT01-UT06 | `timestampToMs` (in `photoCleanup.test.js`): Timestamp stand-in, Date, number, invalid Date/NaN/Infinity, wrong types, throwing/non-finite `toMillis`, monkey 3000 values |

Real-project note for FS10: the clock is stepped manually and the failure time is stamped 5 s after each tick (a hook bumps the clock inside the failing delete), which is what makes the tick slack testable; the 12th failure lands 300 min after the first.

## 3. End-to-end (emulator, CI only: `test/e2e/cleanupSweep.e2e.test.js`, added to the `node --test` list in `checks.yml`) (5)
| ID | Case |
|---|---|
| E1 | seeded stuck marker + 3 batches + 2 Storage objects in two tenants -> `cleanupPendingMarkers.run({})` -> everything gone in both tenants (proves the unfiltered collection-group read crosses tenants on real Firestore semantics) |
| E2 | **P1 at real Firestore**: marker with only the fields PR #113 wrote -> swept |
| E3 | id-reused marker dropped, live product + its photos untouched |
| E4 | parked marker untouched; after un-park it is swept |
| E5 | **R1 paging at real Firestore semantics**: seed `PAGE_SIZE * 2 + 50` markers across 3 tenants, one run -> every due marker swept (proves cursor-without-orderBy walks the whole collection group, no skips, no repeats) |
UNVERIFIED: that the Admin SDK in `test/e2e` and the one in `functions/` coexist (different major versions) and that the storage emulator host is picked up by `index.js`; expect one correction round. The emulator does NOT prove the no-index claim: that is DV-1.

## 4. Real project, Taher (after a MANUAL deploy of ALL functions, dev database only)
Prerequisite: deploy everything (`firebase deploy --only functions`), accept the Cloud Scheduler API prompt, write the deploy into `CHECKPOINT.md`.

### 4.1 Happy path
- [ ] DV-1 (the no-index claim): Logs Explorer shows a run of `cleanupPendingMarkers` with a summary line per env and NO `FAILED_PRECONDITION` / "requires an index".
- [ ] DV-2: Cloud Scheduler console lists the job, schedule `every 10 minutes`, location acceptable.
- [ ] DV-3: create a marker by hand in `dev1` (`tenants/<t>/pending_cleanup/PRD-DV1` with the fields of a real marker, a Storage file under its prefix, one fake `stock_batches` doc with that `productId`): within ~12 min the marker, file and batch are gone and a `cascade~` audit entry exists.

### 4.2 Negative
- [ ] DV-4: marker with a wrong `prefix`: not swept, `attempts` rises each backoff, Storage untouched.
- [ ] DV-5: marker with `attempts: 11` and a wrong prefix: parks on the next failed run (`parked: true`, doc kept), ERROR log visible; later runs do not touch it.

### 4.3 Edge cases
- [ ] DV-6: delete a product on the app while the scheduler is running (handler sweep + scheduler overlap is unlikely to be forced by hand; just confirm no leftover marker and no zombie doc afterwards).
- [ ] DV-7: marker for a product id that exists again: marker disappears, product and photos intact.
- [ ] DV-9 (alert, the production-blocker gate): alert policy created per `../specs/2026-10-05-ph3b-alert-runbook.md`; plant a malformed marker in `dev1` (`envPrefix: "prd"`): within ~12 min it parks, an email AND a Google Cloud console mobile app push arrive, a second run does not re-notify inside the rate-limit window; delete the planted marker afterwards. Negative: a marker failing below the cap sends nothing.
- [ ] DV-8: un-park (`parked` false, `attempts` 0) on a fixed marker: swept within two runs.

### 4.4 Affected areas
| Area | Automated cover | Where to look on the project |
|---|---|---|
| `functions/lib/photoCleanup.js` | sections 1, 2 | n/a |
| `functions/index.js` (`updateMarker`, scheduler) | section 2, E1-E4 | DV-1..DV-8 |
| `recordMutation` product delete (shares `sweepProductCleanup`) | existing PH3/BC1 handler tests must stay green | delete a product in the app, confirm photos, batches and marker are gone |
| `firebase.json`, `firestore.indexes.json` | none needed (Q-K = a) | DV-1 |
| Cloud Scheduler | none (real project only) | DV-2 |

### 4.5 Regression watch
- A marker written before PH3b must still be swept (US04, FS04, E2).
- A marker deleted by one sweeper must never reappear (FS02).
- A parked marker must never be deleted or swept by code (UR10, E4).
- A marker of another environment must never delete Storage objects (US08, FS05).
