# Product photos — pending items: PH3 (server), PH4 (client), PH5 (remove legacy `photoUrl`) — design

**Status:** design only. Decisions Q1-Q11 taken by Taher 2026-09-30, Q12-Q15 on 2026-10-01 after the PR #108 review (ledger below). No code written. PH3 (server) can start once PR #108 merges. **PH3b (scheduled cleanup function) design is decided except Q-I** (Blaze/Cloud Scheduler plan and who deploys), see its section; PH3 does not depend on it.
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
| Q12 | Poison markers (review I1) | **Cap 5 attempts**, then the marker is parked (kept, never auto-deleted, logged) | Chosen by Taher. Mechanics live in PH3b |
| Q13 | Product id not found | **Delete = idempotent on both sides, no server change**: photo delete already works with a missing product (existing code, pin test F40); product delete of a server-absent product gets 409 `current:null` and the client already removes the local row (pin test F41). PH4 fixes the misleading toast | Verified in code 2026-10-01. Upload to a missing product stays 404 with zero Storage writes (Q1) |
| Q14 | Slice names | **PH3 / PH4 / PH5 (+ PH3b)** | Collision with stuck-writes S3 |
| Q15 | Scheduler timing | **PH3b is its own session**, needs error + response handling designed | PH3 ships without a drain: failed sweeps wait for PH3b (dev only, accepted) |

## Slices and order

PH3 first (server), then PH4 (client), then PH5. No deploy-order concern (dev only), but PH3-before-PH4 keeps every intermediate state free of the destroy-before-ack bug.

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

### Drain: moved to PH3b (Q6 amended)
PH3 has NO drain. The only sweep is the awaited one right after a committed delete. A marker whose sweep failed stays put (durable) until PH3b ships. `selectDrainable` and all drain cases moved to PH3b (see test plan).

### Batch and ops (Q11)
Shared predicate `isCascadeEntityDelete(entity, action)` in `gatewayLogic.js`. `recordMutationsBatch` rejects a batch containing it: `400`, zero writes, whole batch rejected. `recordOperation` rejects an op containing it: `400` with `opIndex`, zero writes. Other deletes, creates, updates and delta ops unchanged.

### `firestore.rules` (corrected after review C1)
A separate `match /pending_cleanup/{docId} { allow ...: if false; }` is NOT enough: Firestore allows a request if ANY matching rule allows it, and the `/{collection}/{docId}` wildcard still lets members read and write. `locks` is safe only because it is also listed in `isServerOnlyCollection` (`firestore.rules` L59-61). **Required change: add `'pending_cleanup'` to `isServerOnlyCollection`** (`name in ['locks', 'pending_cleanup']`). An explicit deny-all match for it is optional documentation. Rules tests R01-R05 and R11 are the proof. `storage.rules` unchanged (public read, no client write).

### Interactions
- **P1 stock movements (planned, NOT merged):** its S1a/S1b also edit `applyMutation`, batch and ops (batch cap 200->150, ops write budgets). Expect merge conflicts in `gatewayLogic.js`; the two changes are independent. Q11 means no marker writes in batch/ops, so P1's write-budget arithmetic is unaffected. Single path gains one write per inventory delete (marker).
- **F5 stays:** strict `before` compare including `photoIds` at all three sites. Add one pin test documenting it.

## PH3b — scheduled cleanup function (own session, design decided except Q-I)
Replaces the piggyback drain (Q6 amended). Taher: separate session, must handle scheduler errors and response handling. Proposal below was accepted as written (Q-E to Q-H); Q-I open:

**Facts verified 2026-10-01:** no scheduled function exists in `functions/index.js` today; `firestore.indexes.json` is empty; marker lives at `tenants/{t}/pending_cleanup/{productId}`, so finding markers across tenants needs a **collection-group query**, per Firestore database (`DATABASE_ID_FOR_ENV`: `dev1`, `test`, `(default)`). Cloud Scheduler needs the Blaze plan (UNVERIFIED for this project; Storage use suggests yes). A scheduled function has no HTTP caller: "response handling" means structured logs, thrown-vs-swallowed errors and the run summary.

**Proposal (not decided):**
- Marker gets `nextAttemptAt` (initial = commit time + 60 s). Scheduler queries `collectionGroup('pending_cleanup').where('nextAttemptAt','<=',now).orderBy('nextAttemptAt').limit(25)`: one field, range + order on the SAME field, so only a collection-group single-field index exemption in `firestore.indexes.json` is needed, no composite index.
- Failure: `attempts += 1`, `nextAttemptAt = now + attempts x 10 min`. At `attempts >= 5` (Q12) **park**: delete the `nextAttemptAt` field (an absent field is not indexed, so it leaves the query: no head-of-line starvation), set `parked: true`, keep the doc, log at error severity. Parked markers need a human (console query on `parked == true`).
- Run every 10 min, `maxInstances: 1`, timeout well under the period. Loop envs independently; per marker try/catch; per env try/catch; one summary log line per env `{env, scanned, swept, droppedIdReuse, failed, parked}`.
- Errors: per-marker and per-env failures are logged and counted, never abort the run. Throw at the very end only if any env-level failure happened (so the run shows as failed in Cloud Scheduler/Logging). No `retryCount`: the next run is the retry and every step is idempotent.
- Reuse `sweepMarker` unchanged (id-reuse recheck, prefix guard).
- Testing: export a pure `runCleanupSweep(deps)` so Node tests drive it with fakes (budget, parking, env isolation, throw-at-end); one emulator e2e calling it directly; real scheduler firing is a DV item (device/real project only).

**Decided by Taher 2026-10-01 ("ok" to the advised defaults):** Q-E schema `nextAttemptAt` + park by removing the field (plus `parked: true`). Q-F run every 10 min, linear backoff `attempts x 10 min`, all three envs. Q-G throw only at the end of the run if an env-level failure happened, never for per-marker failures. Q-H keep the immediate awaited post-commit sweep in the delete handler.
**Still OPEN (needs facts, "ok" cannot answer it): Q-I.** (1) Is the Firebase project on Blaze with Cloud Scheduler allowed? Storage use suggests yes, UNVERIFIED. (2) Who deploys functions: CI or manual? PH3b implementation must not start until Q-I is answered; PH3 does not depend on it.

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
