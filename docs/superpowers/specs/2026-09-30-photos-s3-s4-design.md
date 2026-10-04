# Product photos — pending items: PH3 (server), PH4 (client), PH5 (remove legacy `photoUrl`) — design

**Status:** design only. Decisions Q1-Q11 taken by Taher 2026-09-30, Q12-Q15 on 2026-10-01 after the PR #108 review (ledger below). No code written. PH3 (server) can start once PR #108 merges. **PH3b (scheduled cleanup function): design v2 reviewed 2026-10-05, ready for implementation once Q-J/Q-K/Q-L are answered (defaults adopted); v1 schema superseded**, see its section; PH3 does not depend on it.
**Slice labels:** PH3/PH4/PH5 (renamed from S3/S4/S5 on 2026-10-01: the stuck-writes workstream already owns `S3`, #109).
**Checkpoint / evidence trail:** `2026-09-30-photos-pending-design-CHECKPOINT.md` (every code claim here was read on `main` @ `0d77f9a`; on 2026-10-01 `functions/`, `firestore.rules`, `storage.rules` re-checked unchanged on `main` @ `52776d7`, only client files moved; items marked UNVERIFIED were not).
**Test plan:** `../test-plans/2026-09-30-photos-ph3-s4-s5-test-plan.md`.
**Builds on:** `2026-09-21-product-photos-firebase-storage-design.md` (PR #84) and PR #99 follow-ups.

## Project facts (Taher, repeated; do not design around their opposites)

Dev env only, no production, no backward compatibility, every PR tested on a NEW tenant. No legacy product `photoUrl` support. No offline operation (app is disabled offline, `Main.qml` ~L451). User-profile `photoUrl` (AuthStore/AuthService/ProfilePage/`provisionMember`) is unrelated and must never be touched.

## Decision ledger

| # | Item | Decision | Note |
|---|---|---|---|
| Q1 | F3 orphans on 404/409 upload | **Read product + photoIds BEFORE any Storage write**; in-txn checks stay as final authority | Tiny race between read and write accepted |
| Q2 | F5 false 409 when `photoIds` drifts | **Accept the 409** (no code) | I advised server-owned `photoIds`; overruled. Strict compare stays, which also prevents a stale `after.photoIds` clobbering a new photo. Cost: stale edit dropped, user redoes it |
| Q3 | N2 role gate | **owner/admin only on both photo endpoints** + **403 becomes terminal in `PhotoQueueLogic`** | Mirrors `AuthStore.canManageInventory`. Partial hardening only; general fix stays in KNOWN-ISSUES (`recordMutation` has no role check) |
| Q4 | C1 who cleans Storage on product delete | **Server cascade in `recordMutation`** after a committed inventory delete | Replaces the client loop |
| Q5 | Durability | **Transactional cleanup marker** `pending_cleanup/{productId}` written in the SAME txn as the delete | Generic operation journal / cross-device lock = roadmap only |
| Q6 | Who drains leftovers | **AMENDED 2026-10-01: scheduled function**, own slice PH3b, own session (was: piggyback in 3 handlers) | Piggyback dropped: it put awaited sweeps on user requests and left idle tenants stuck. PH3 keeps the immediate post-commit sweep only. Design of PH3b decided except Q-I (deploy/plan facts) |
| Q7 | Client per-photo delete loop | **Remove** (and its legacy branch); keep only the `PhotoQueue` purge | Decided by implication of the project facts; reversible |
| Q8 | Legacy product `photoUrl` | **PH5: remove all** of it, own slice, after PH3/PH4 | |
| Q9 | N1 photo id | **`Qt.uuid()` minus braces** (Q10a amendment) + **server whitelist** `[A-Za-z0-9_-]`, length 1-64 | Keep `photo-` prefix (42 chars) |
| Q10 | Small items | N3: second Skill 66 renamed **Skill 89** (DONE in this session). P1 `FailedTileGeometry.js` keep. D1 keep. L1 fold into PH4 only if <=3 lines. OC dropped. DV goes in the test plan. P2 `setPhoto` goes in PH5 | |
| Q11 | Inventory delete via batch / ops bypasses the marker | **Reject `inventory`+`delete` in `recordMutationsBatch` and `recordOperation`** via one shared predicate | Upgrade to a shared marker helper when the delete roadmap builds atomic product+batches delete |
| Q12 | Poison markers (review I1) | **Cap 5 attempts**, then the marker is parked (kept, never auto-deleted, logged) | Chosen by Taher. Mechanics live in PH3b. **Under review 2026-10-05 (Q-J): cap 5 predates money data in the marker; default is now park at 12 with backoff capped at 30 min** |
| Q13 | Product id not found | **Delete = idempotent on both sides, no server change**: photo delete already works with a missing product (existing code, pin test F40); product delete of a server-absent product gets 409 `current:null` and the client already removes the local row (pin test F41). PH4 fixes the misleading toast | Verified in code 2026-10-01. Upload to a missing product stays 404 with zero Storage writes (Q1) |
| Q14 | Slice names | **PH3 / PH4 / PH5 (+ PH3b)** | Collision with stuck-writes S3 |
| Q15 | Scheduler timing | **PH3b is its own session**, needs error + response handling designed | PH3 ships without a drain: failed sweeps wait for PH3b (dev only, accepted) |

## Slices and order

PH3 first (server), then PH4 (client), then PH5. No deploy-order concern (dev only), but ~~PH3-before-PH4 keeps every intermediate state free of the destroy-before-ack bug.~~ **WRONG (found 2026-10-04, PR #113 device test):** the bug is the client `removeProductPhoto` loop, which stays live until PH4 item 3 ships; PH3 alone does not remove it. PH4 item 3 was pulled forward on `fix/2026-10-04-pr113-upload-delete-race`. Batches/activity log are still destroy-before-ack (KNOWN-ISSUES).

| Slice | Branch (planned, may differ) | Touches | Verifiable by |
|---|---|---|---|
| **PH3** server cascade + hardening | `feat/2026-10-01-photos-ph3-server` | `functions/lib/photoValidation.js`, new `functions/lib/photoCleanup.js`, `functions/lib/gatewayLogic.js`, `batchMutationLogic.js`, `operationLogic.js`, `functions/index.js`, `firestore.rules`, tests | Node tests run for real in the sandbox; rules + e2e on CI |
| **PH4** client | `feat/2026-10-01-photos-ph4-client` | `qml/helper/PhotoQueueLogic.js`, `qml/model/StorageService.qml`, `qml/model/InventoryStore.qml` (delete path), maybe `PhotoQueue.qml` (L1), tests | CI only (no Qt in sandbox) |
| **PH5** remove legacy `photoUrl` | `feat/2026-10-01-photos-ph5-legacy-removal` | see PH5 list | CI only, plus C++ compile on CI |

## PH3 — server design

### Validation (`photoValidation.js`)
`isSafePathSegment` becomes a whitelist: `^[A-Za-z0-9_-]{1,64}$` (today: anything without `/` or `..`). Applies to tenantId, productId, photoId and the env prefix segments on `uploadProductPhoto`, `deleteProductPhoto` and the sweep guard. Not-a-string, empty, `.`/`..`, `a/b`, backslash, space, unicode, control chars, 65 chars: all rejected.

### Role gate (both photo endpoints)
Right after `deriveContext` and BEFORE any Firestore read or Storage write: `ctx.role` must be `owner` or `admin`, else `403 {ok:false, error:"role-not-allowed"}`. Pure helper `canManagePhotos(role)` in `photoCleanup.js` (exact match; `"OWNER"`, `""`, `undefined`, `"viewer"` all false; there is no viewer role).

### `uploadProductPhoto` flow (F3)
parse/auth -> `deriveContext` -> **role gate** -> whitelist + existing payload validation -> **preflight read** of `tenants/{t}/inventory/{p}`: missing -> existing 404; `photoIds.length >= cap` and `photoId` not already in `photoIds` -> existing 409 (error codes unchanged; replay of an already-confirmed `photoId` must still pass) -> Storage saves (main + thumb) -> existing transaction (final authority, keeps its 404/409) -> respond. Known limit: product deleted between preflight and Storage write can still leave one orphan pair; the next delete of that id cannot catch it (marker already consumed). Accepted, documented.

### `deleteProductPhoto`
Role gate and whitelist added; existing behavior otherwise unchanged. It already tolerates a missing product doc and still deletes the Storage objects (Q13): keep, pin with F40.

### Cleanup marker (Q5)
- Path `tenants/{t}/pending_cleanup/{productId}` (via `scopedDb(env)` like every other collection). Doc: `{productId, envPrefix, prefix, createdAt (server ts), attempts: 0, lastError: null}` (`requestId` dropped: never read; `envPrefix` added so the sweep guard can rebuild the prefix, review I2).
- `prefix = storageEnvPrefix(body.env) + "/tenants/" + t + "/products/" + p + "/"`, built by `photoCleanup.buildSweepPrefix(envPrefix, t, p)` in the handler and passed to `applyMutation` as `params.cleanupPrefix` (with `params.cleanupEnvPrefix`). It returns `null` unless every segment passes the whitelist and the result ends with `/`. Handler: inventory delete with `null` prefix -> `400 invalid-entity-id` before `applyMutation`.
- **Sweep safety (hard requirement):** an empty or odd productId must never widen the prefix to `products/`, which would delete every product's photos in the tenant. The sweep executor refuses when the prefix is null, does not end in `/`, or does not equal `buildSweepPrefix(marker.envPrefix, tenantId, marker.productId)` (tenantId taken from the marker doc path, never from the marker body).
- `applyMutation`: after the existing CAS compare and only when `isCascadeEntityDelete(entity, action)` (true only for `inventory`+`delete`), `txn.set(markerRef, marker)` in the same transaction as the doc delete and the audit doc. A CAS conflict returns before any write: **no marker, no sweep** (this is the regression test for the destroy-before-ack bug). Idempotent replay returns early: no second marker.
- After commit (`result.ok && !idempotentReplay`) the handler **awaits** `sweepMarker` for this product, then responds 200. Sweep failure never fails the response.

### `sweepMarker(deps, marker)` (pure, dependencies injected)
1. Re-read the product doc. If it exists again (id reused): delete the marker only, do NOT sweep.
2. `bucket.deleteFiles({prefix, force:true})`.
3. Delete the marker.
Any step that throws: leave the marker, `attempts += 1`, `lastError` = message truncated to 200 chars, log it. The attempts cap (Q12) is enforced by the PH3b scheduler, not here. Marker-delete failure is swallowed and logged. Two devices sweeping the same marker is safe (prefix delete is idempotent); no claim/lease.

> **BC1 note (2026-10-05):** the marker now also drives the product's stock-batch cleanup (`sweepMarker` runs `sweepBatches` before the Storage delete) and carries `actorUid`/`actorRole`/`requestId`. PH3b must call the same `sweepMarker` with those fields, tolerate old markers (`system` actor), tolerate a concurrent handler sweep, and must NOT silently abandon a capped marker that still has batches (money data). See the BC design, "PH3b implications".

### Drain: moved to PH3b (Q6 amended)
PH3 has NO drain. The only sweep is the awaited one right after a committed delete. A marker whose sweep failed stays put (durable) until PH3b ships. `selectDrainable` and all drain cases moved to PH3b (see test plan).

### Batch and ops (Q11)
Shared predicate `isCascadeEntityDelete(entity, action)` in `gatewayLogic.js`. `recordMutationsBatch` rejects a batch containing it: `400`, zero writes, whole batch rejected. `recordOperation` rejects an op containing it: `400` with `opIndex`, zero writes. Other deletes, creates, updates and delta ops unchanged.

### `firestore.rules` (corrected after review C1)
A separate `match /pending_cleanup/{docId} { allow ...: if false; }` is NOT enough: Firestore allows a request if ANY matching rule allows it, and the `/{collection}/{docId}` wildcard still lets members read and write. `locks` is safe only because it is also listed in `isServerOnlyCollection` (`firestore.rules` L59-61). **Required change: add `'pending_cleanup'` to `isServerOnlyCollection`** (`name in ['locks', 'pending_cleanup']`). An explicit deny-all match for it is optional documentation. Rules tests R01-R05 and R11 are the proof. `storage.rules` unchanged (public read, no client write).

### Interactions
- **P1 stock movements (planned, NOT merged):** its S1a/S1b also edit `applyMutation`, batch and ops (batch cap 200->150, ops write budgets). Expect merge conflicts in `gatewayLogic.js`; the two changes are independent. Q11 means no marker writes in batch/ops, so P1's write-budget arithmetic is unaffected. Single path gains one write per inventory delete (marker).
- **F5 stays:** strict `before` compare including `photoIds` at all three sites. Add one pin test documenting it.

## PH3b — scheduled cleanup function (design v2, reviewed 2026-10-05; READY once Q-J / Q-K / Q-L are answered)

Replaces the piggyback drain (Q6 amended). v1 (2026-10-01, `nextAttemptAt` schema + collection-group index) is in git history at `7ec2fc6`; the 2026-10-05 review below found it would not work as written. **Nothing is built.** Code facts below were read on `main` @ `7ec2fc6` (functions suite 491/491 green in-session before this change).

### Review ledger (2026-10-05, code read + Firebase docs, NOT run against a real project)

| ID | Sev | Finding | Resolution in v2 |
|---|---|---|---|
| P1 | High | v1 queries `where('nextAttemptAt','<=',now)`. Markers written by PR #113 / BC1 have no such field (`photoCleanup.buildMarker` writes `createdAt, attempts, lastError` + actor fields only). A Firestore range filter excludes docs lacking the field, so the failed markers PH3b exists to rescue would never be returned | No new schedule field. Due time is computed in code from fields EVERY marker has (`createdAt`, `attempts`) plus one new failure-time field (`lastAttemptAtMs`) |
| P2 | High | v1 needs a collection-group single-field index. (a) Collection-group indexes are not automatic (Firebase docs: filtered/ordered collection-group queries need an index with collection-group scope). (b) `firebase.json` has ONE `firestore` object with no `database` key, so `firebase deploy --only firestore:indexes` targets `(default)` only; README says `dev1`/`test` rules are applied by hand per database. (c) The emulator-based CI would not prove the index exists (UNVERIFIED but widely stated; treat as unproven) | No index. Per Firebase docs a collection-group query that neither filters nor orders needs no index. Read all markers (`limit(MAX_SCAN)`), filter in code. Markers exist only for failed/crashed sweeps, so the read is tiny. No `firestore.indexes.json` or `firebase.json` change |
| P3 | High | `index.js` `sweepProductCleanup.updateMarker` is `markerRef.set(patch, {merge:true})`. `set`+merge on a deleted doc RE-CREATES it as `{attempts, lastError}` with no `productId`/`prefix`/`envPrefix`. Today only one sweeper exists so it is dormant. With PH3b the handler sweep and the scheduler can overlap: one succeeds and deletes the marker, the other fails and resurrects a zombie that fails `unsafe-sweep-prefix` forever and ends parked | `updateMarker` becomes `markerRef.update(patch)` (rejects NOT_FOUND on a deleted doc; `sweepMarker.fail` already swallows that). Regression test needs the handler harness to grow `update` (it has none today) |
| P4 | Med | Q12 (cap 5, ~100 min of linear backoff then parked) was chosen for photos only. Since BC1 the marker also carries money data (batches). A Storage/Firestore outage of a few hours would park markers and need a human | Q-J below |
| P5 | Med | No timeout/budget in v1 ("timeout well under the period"). One marker with 1000 batches is 10 commits + a Storage delete | `timeoutSeconds: 300`, `budgetMs: 240000` checked before each marker, remainder `deferred` to the next run (`maxInstances: 1`, 10 min cadence: no overlap) |
| P6 | Med | v1 grace "commit + 60 s" equals the HTTP handler's default timeout (no `timeoutSeconds` set on `recordMutation`, so Cloud Functions default; UNVERIFIED in console). `createdAt` is set a second or two into the request, so a 60 s grace can overlap a still-running handler sweep | Fresh-marker grace is 90 s |
| P7 | Med | Cross-env safety: the scheduler reads three databases but Storage is ONE shared bucket. A `prd`-prefixed marker found in the `dev1` database must never delete `prd/...` objects | `selectDue` rejects a marker whose `envPrefix` differs from `storageEnvPrefix(env being scanned)` as malformed (parked, never swept) |
| P8 | Low | A collection-group query on `pending_cleanup` returns matches at ANY depth, and tenant/product come from the doc body unless forced | Tenant and product id come from the doc PATH only (`parseMarkerPath`, regex + `isSafePathSegment`); body `productId` must equal the path id or the marker is malformed |
| P9 | Low | A thrown run error is the only signal Cloud Scheduler shows; per-marker failures never throw (Q-G), so the job shows green while every marker fails. No alerting exists in the project | Q-L below |
| P10 | Low | Overlapping sweeps both write `attempts + 1` from the same read: undercount by one | Accepted: the cap is soft. Audit ids are deterministic (`cascade~{p}~{b}`) and deletes of missing docs are no-ops, so overlap duplicates nothing (read in `buildCascadeAuditId` / `commitChunk`) |

BC-design "PH3b implications" 1-6 are all covered: (1) the scheduler reuses `index.js` `sweepProductCleanup` as-is (it binds `sweepBatches`); (2) capped markers are parked visibly, never deleted; (3) overlap safe, see P3/P10; (4) old markers sweep as `system`; (5) crashed-sweep case = test U-R-crash; (6) the scheduler takes no client `requestId`.

### Decision ledger

| Q | Question | Status |
|---|---|---|
| Q-E | v1: `nextAttemptAt` + park by removing the field | **SUPERSEDED by Q-K** (reason: P1, P2). Taher's 2026-10-01 "ok" was given to a proposal that had these defects |
| Q-F | Run every 10 min, all three envs | kept. Backoff shape changes under Q-J |
| Q-G | Throw only at the end, only for env-level failures | kept |
| Q-H | Keep the immediate awaited post-commit sweep | kept |
| Q-I | Blaze + manual deploy | answered 2026-10-03 |
| **Q-J** | Backoff and park cap. **(a) keep v1: delay `attempts x 10 min`, park at 5 (~100 min)** vs **(b) recommended: delay `min(attempts,3) x 10 min` (10, 20, 30, 30 ...), park at 12 (~5 h)** | **OPEN. Default adopted for the plan: (b).** Cost of (b): a poisoned marker retries ~12 times (12 cheap runs) before a human is told. Cost of (a): one Storage outage > 100 min leaves money batches waiting on a human. `PARK_AT` is a constant; tests import it, so switching is one line |
| **Q-K** | Schedule by (a) **recommended: in-code due time from `createdAt`/`attempts`/`lastAttemptAtMs`, unfiltered collection-group read, no index** vs (b) v1 `nextAttemptAt` + index exemption + per-database index deploy + one-off backfill of existing markers | **OPEN. Default adopted: (a).** (a) trade-off: every non-deleted marker (incl. parked) is read each run, capped at `MAX_SCAN = 500`; fine while markers are rare, revisit if parked markers pile up. (b) trade-off: needs `firebase.json` multi-database indexes or manual console steps in 3 databases, and a backfill; CI cannot prove either |
| **Q-L** | Alerting on `parked`/errors. (a) **recommended now: none, runbook = console query `parked == true` + Logs Explorer severity ERROR; recorded as a PRODUCTION-publish blocker** vs (b) one log-based alert policy in Cloud Monitoring (console config, no code) | **OPEN. Default adopted: (a).** Honest note: with (a) a parked money marker is invisible unless someone looks |

### Design v2

**Marker fields.** Unchanged at write time (`buildMarker`, `applyMutation` and the delete handler are NOT touched). New fields are written only by the sweeper: on failure `lastAttemptAtMs` (number, from `deps.now()`), on park `parked: true`, `parkedAtMs`.

**Due rule (pure).** `dueAtMs = (lastAttemptAtMs ?? createdAtMs) + delayMs(attempts)`; `delayMs(a) = 90_000` for `a <= 0` or a non-number, else `min(a, 3) x 600_000`. Due when `nowMs >= dueAtMs`. `parked === true` is skipped. Due markers are processed oldest `dueAtMs` first (the budget then favours the longest-waiting).

**New pure functions in `lib/photoCleanup.js`:** `parseMarkerPath(path)` -> `{tenantId, productId} | null`; `delayMs(attempts)`; `selectDue(markers, nowMs, expectedEnvPrefix)` -> `{due, notDue, parked, malformed}` (never throws; the four groups partition the input); `runCleanupSweep(deps)`; constants `GRACE_MS`, `BACKOFF_STEP_MS`, `BACKOFF_STEPS`, `PARK_AT`, `MAX_SCAN`, `RUN_BUDGET_MS`. `sweepMarker` gains `lastAttemptAtMs: deps.now()` in its failure patch (`deps.now` optional, defaults to `Date.now`).

**`runCleanupSweep(deps)`.** deps: `envs`, `listMarkers(env) -> [{path, data, createdAtMs}]`, `sweep(env, tenantId, marker) -> sweepMarker result`, `park(env, tenantId, productId, reason)`, `now()`, `log(severity, obj)`. For each env in its own try/catch: list, `selectDue`, park every malformed marker at once (reason `malformed-marker: ...`, never swept), then sweep due markers one at a time, each in its own try/catch, stopping new work when `now() - start >= RUN_BUDGET_MS` (rest counted `deferred`). After a failed sweep, if `attempts + 1 >= PARK_AT` call `park`. A `park` that throws is logged and counted `failed`; the run continues. One summary per env `{env, scanned, swept, droppedIdReuse, failed, parked, malformed, notDue, deferred, backlog, error}` (`backlog: true` when the read hit `MAX_SCAN`, also logged at ERROR). Returns `{envs, envFailures}`.

**Binding in `index.js`.**
```
exports.cleanupPendingMarkers = onSchedule(
  { schedule: "every 10 minutes", region: "asia-south1", timeoutSeconds: 300, maxInstances: 1, retryCount: 0 },
  async () => { const out = await runCleanupSweep(<bound deps>); if (out.envFailures > 0) throw new Error(...); });
```
`listMarkers` = `scopedDb(env).collectionGroup("pending_cleanup").limit(MAX_SCAN).get()`. `sweep` = existing `sweepProductCleanup(scopedDb(env), tenantId, {...data, productId: <from path>})`. `park` = `markerRef.update({parked:true, parkedAtMs, lastError})` plus `console.error`. `firebase-functions/v2/scheduler` `onSchedule` and `ScheduleFunction.run()` were confirmed present in the installed SDK; `maxInstances` is inherited from `GlobalOptions` (type-level only; confirm at first deploy).

**Errors and response handling.** Per-marker failure: marker kept, counted. Per-env failure (cannot read, database missing): counted in `envFailures`, other envs still run. End of run: throw only if `envFailures > 0` (the run then shows failed in Cloud Scheduler / Logging). `retryCount: 0` explicit: the next run is the retry and every step is idempotent. Parked markers are NEVER deleted by code. **Un-park runbook:** in the console set `parked` to false and `attempts` to 0 on the marker (it is swept on the next run).

**Deploy facts (Taher deploys manually).** Deploy ALL functions, not only the new one: the P3 fix lives in `recordMutation`'s shared module, and a scheduler-only deploy would leave the handler racy. Record every deploy in the checkpoint (deployed != main drift). First deploy of a scheduled function prompts to enable Cloud Scheduler (and related) APIs. Scheduler location must be available for `asia-south1` (UNVERIFIED, confirm at deploy). Verify the free-tier job quota in the console, not from memory.

**Slices (each small, resumable, own commit).**
- S-A `photoCleanup.js` pure functions + unit tests (Node, runnable in sandbox).
- S-B `index.js`: P3 `update` fix, `cleanupPendingMarkers`, harness `update` + `collectionGroup`, functional tests.
- S-C `test/e2e/cleanupSweep.e2e.test.js` (+ add it to the `node --test` list in `.github/workflows/checks.yml`), docs (AGENTS runbook line, KNOWN-ISSUES, roadmap), no deploy.
Test plan: `../test-plans/2026-10-05-ph3b-scheduled-cleanup-test-plan.md`.

**Acceptance.** Functions suite green with new tests; new-code line + branch coverage of `lib/photoCleanup.js` 100% (`node --test --experimental-test-coverage`); emulator e2e green on CI; after a manual deploy a seeded stuck marker disappears within two runs on a real project (DV).

## PH4 — client design
1. `PhotoQueueLogic.js`: `TERMINAL_STATUS` `{400,413,404,409}` -> add `403`. A 403 goes straight to `failed` (existing Retry/Discard UI). Accepted trade-off: a reactivated suspended member's `no-tenant-context` 403 also needs a manual Retry.
2. `StorageService._nextPhotoId`: `"photo-" + Qt.uuid()` with `{`/`}` stripped. UNVERIFIED that `Qt.uuid()` works in headless `qmltestrunner`: confirm on the first CI run; if not, stub in tests.
3. `InventoryStore.deleteProduct`: delete the `removeProductPhoto` loop over `before.photoIds` and the legacy `photoUrl` -> `ImageProcessor.removeLocalCopy(productId)` branch. KEEP the `PhotoQueue` purge of queued photos for that product (local files; the server cannot do it). Result: photos are only destroyed after a committed delete.
4. Fold L1 (breaker open re-arms a 250 ms timer for the whole cooldown) only if the fix is <=3 lines: re-arm at `cooldownUntil`. Otherwise drop.
5. Product delete when the server row is already gone (Q13): `Gateway` hands `_onMutationConflicted` a 409 with `current: null`; the store already removes the local row, but shows "Couldn't delete ... restored with the latest version". When `action === "delete"` and `current` is null, show an "already deleted elsewhere" toast instead (few lines). Test C26.
6. Standalone remove-photo button already surfaces failures via `removeFailed(photoId, err)` (`ProductPhotoGallery.qml` ~L76): no change.

## PH5 — remove legacy PRODUCT `photoUrl`/`photoUpdatedAt`
Remove: `InventoryStore.qml` normalize (L132-133), clone fields (L198-199, L226), `setPhoto` (L622-630, dead), clear-legacy helper (L663-674), upsert/import fields (L985-997); `EditProductDialog.qml` property, load, reset and the "Upload this photo" migration UI (L14/31/147/219/299-304); `InventoryPage.qml` thumbnail fallback (L241); `StorageService.qml` legacy comments (L12/37); `XlsxService.cpp` export column 11 "Photo URL" (L81) and `ImportPreviewDialog.qml` import "Photo URL" (L460/482); tests `tst_InventoryStore_deleteProductCascade.qml`, `tst_InventoryStore_photoIds.qml`, `test/felgo-dependent/tst_InventoryPage_deleteButton.qml`. **Must check before editing:** whether dropping export column 11 shifts later columns, and whether the import template/docs mention it (user-visible spreadsheet format change): decide remove-vs-blank then. **Never touch** AuthStore, AuthService, ProfilePage, `provisionMember`.

## Known limits (accepted, to be written into KNOWN-ISSUES / photo design spec at implementation)
F5 stale-edit 409 (user redoes the edit). A failed sweep waits for the PH3b scheduled function (until PH3b ships it waits indefinitely; dev only). Residual race between upload preflight and Storage write. No timeliness guarantee on cleanup. Photo gate is partial hardening (staff token can still edit/delete products via `recordMutation`).

## Not building
Generic cross-device operation journal / lock (existing `lockLogic.js` is a 90 s TTL lock and does not fit a persistent "deleting" state; CAS already 409s stale edits after a delete; atomic product+batches delete belongs to the delete roadmap via one `recordOperation`). Firestore trigger or scheduled function for cleanup. Server-minted photo ids. Offline photo cache. Deleting `FailedTileGeometry.js`. D1 attempt counting. General `authorize(role, entity, action)` (KNOWN-ISSUES).

## Docs to update when implementing
(PH3b adds: `AGENTS.md` scheduled function + `parked` runbook line, `firestore.indexes.json` exemption note.) `KNOWN-ISSUES.md` (F5 accepted entry; note photo gate in the authz entry is already cross-linked), photo design spec "Known limits", `AGENTS.md` file-map lines for `photoCleanup.js` and the new `pending_cleanup` collection, `README.md` if it lists collections, `SKILLS.md` (new skill only for lessons actually hit), test-plans `README.md` row (added with this design).

## Acceptance
PH3: functions suite green incl. new tests, rules + e2e green on CI, no Storage write on any 403/404/409 upload, marker written iff a delete committed. PH4: CI green, `deleteProduct` issues no `removeProductPhoto`, 403 never retries. PH5: no product `photoUrl` reference left except the test that asserts absence; profile photo untouched.
