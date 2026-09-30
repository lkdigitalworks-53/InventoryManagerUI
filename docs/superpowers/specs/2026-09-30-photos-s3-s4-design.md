# Product photos — pending items: S3 (server), S4 (client), S5 (remove legacy `photoUrl`) — design

**Status:** design only, every decision taken by Taher on 2026-09-30 (ledger below). No code written. An implementation session can start at S3 immediately.
**Checkpoint / evidence trail:** `2026-09-30-photos-pending-design-CHECKPOINT.md` (every code claim here was read on `main` @ `0d77f9a`; items marked UNVERIFIED were not).
**Test plan:** `../test-plans/2026-09-30-photos-s3-s4-s5-test-plan.md`.
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
| Q6 | Who drains leftovers | **Piggyback** inside inventory-delete + the two photo handlers; <=3 markers, age >60 s, awaited | Idle tenant: marker waits (durable). Upgrade path: scheduled fn, same schema |
| Q7 | Client per-photo delete loop | **Remove** (and its legacy branch); keep only the `PhotoQueue` purge | Decided by implication of the project facts; reversible |
| Q8 | Legacy product `photoUrl` | **S5: remove all** of it, own slice, after S3/S4 | |
| Q9 | N1 photo id | **`Qt.uuid()` minus braces** (Q10a amendment) + **server whitelist** `[A-Za-z0-9_-]`, length 1-64 | Keep `photo-` prefix (42 chars) |
| Q10 | Small items | N3: second Skill 66 renamed **Skill 89** (DONE in this session). P1 `FailedTileGeometry.js` keep. D1 keep. L1 fold into S4 only if <=3 lines. OC dropped. DV goes in the test plan. P2 `setPhoto` goes in S5 | |
| Q11 | Inventory delete via batch / ops bypasses the marker | **Reject `inventory`+`delete` in `recordMutationsBatch` and `recordOperation`** via one shared predicate | Upgrade to a shared marker helper when the delete roadmap builds atomic product+batches delete |

## Slices and order

S3 first (server), then S4 (client), then S5. No deploy-order concern (dev only), but S3-before-S4 keeps every intermediate state free of the destroy-before-ack bug.

| Slice | Branch (planned, may differ) | Touches | Verifiable by |
|---|---|---|---|
| **S3** server cascade + hardening | `feat/2026-10-01-photos-s3-server` | `functions/lib/photoValidation.js`, new `functions/lib/photoCleanup.js`, `functions/lib/gatewayLogic.js`, `batchMutationLogic.js`, `operationLogic.js`, `functions/index.js`, `firestore.rules`, tests | Node tests run for real in the sandbox; rules + e2e on CI |
| **S4** client | `feat/2026-10-01-photos-s4-client` | `qml/helper/PhotoQueueLogic.js`, `qml/model/StorageService.qml`, `qml/model/InventoryStore.qml` (delete path), maybe `PhotoQueue.qml` (L1), tests | CI only (no Qt in sandbox) |
| **S5** remove legacy `photoUrl` | `feat/2026-10-01-photos-s5-legacy-removal` | see S5 list | CI only, plus C++ compile on CI |

## S3 — server design

### Validation (`photoValidation.js`)
`isSafePathSegment` becomes a whitelist: `^[A-Za-z0-9_-]{1,64}$` (today: anything without `/` or `..`). Applies to tenantId, productId, photoId and the env prefix segments on `uploadProductPhoto`, `deleteProductPhoto` and the sweep guard. Not-a-string, empty, `.`/`..`, `a/b`, backslash, space, unicode, control chars, 65 chars: all rejected.

### Role gate (both photo endpoints)
Right after `deriveContext` and BEFORE any Firestore read or Storage write: `ctx.role` must be `owner` or `admin`, else `403 {ok:false, error:"role-not-allowed"}`. Pure helper `canManagePhotos(role)` in `photoCleanup.js` (exact match; `"OWNER"`, `""`, `undefined`, `"viewer"` all false; there is no viewer role).

### `uploadProductPhoto` flow (F3)
parse/auth -> `deriveContext` -> **role gate** -> whitelist + existing payload validation -> **preflight read** of `tenants/{t}/inventory/{p}`: missing -> existing 404; `photoIds.length >= cap` and `photoId` not already in `photoIds` -> existing 409 (error codes unchanged; replay of an already-confirmed `photoId` must still pass) -> Storage saves (main + thumb) -> existing transaction (final authority, keeps its 404/409) -> **drain** -> respond. Known limit: product deleted between preflight and Storage write can still leave one orphan pair; the next delete of that id cannot catch it (marker already consumed). Accepted, documented.

### `deleteProductPhoto`
Role gate and whitelist added; existing behavior otherwise unchanged; **drain** before responding.

### Cleanup marker (Q5)
- Path `tenants/{t}/pending_cleanup/{productId}` (via `scopedDb(env)` like every other collection). Doc: `{productId, prefix, requestId, createdAt (server ts), attempts: 0, lastError: null}`.
- `prefix = storageEnvPrefix(body.env) + "/tenants/" + t + "/products/" + p + "/"`, built by `photoCleanup.buildSweepPrefix(envPrefix, t, p)` in the handler and passed to `applyMutation` as `params.cleanupPrefix`. It returns `null` unless every segment passes the whitelist and the result ends with `/`. Handler: inventory delete with `null` prefix -> `400 invalid-entity-id` before `applyMutation`.
- **Sweep safety (hard requirement):** an empty or odd productId must never widen the prefix to `products/`, which would delete every product's photos in the tenant. The sweep executor refuses when the prefix is null, does not end in `/`, or is not exactly the prefix rebuilt from the marker's ids.
- `applyMutation`: after the existing CAS compare and only when `isCascadeEntityDelete(entity, action)` (true only for `inventory`+`delete`), `txn.set(markerRef, marker)` in the same transaction as the doc delete and the audit doc. A CAS conflict returns before any write: **no marker, no sweep** (this is the regression test for the destroy-before-ack bug). Idempotent replay returns early: no second marker.
- After commit (`result.ok && !idempotentReplay`) the handler **awaits** `sweepMarker` for this product, then drains, then responds 200. Sweep failure never fails the response.

### `sweepMarker(deps, marker)` (pure, dependencies injected)
1. Re-read the product doc. If it exists again (id reused): delete the marker only, do NOT sweep.
2. `bucket.deleteFiles({prefix, force:true})`.
3. Delete the marker.
Any step that throws: leave the marker, `attempts += 1`, `lastError` = message truncated to 200 chars, log it. Marker-delete failure is swallowed and logged. Two devices sweeping the same marker is safe (prefix delete is idempotent); no claim/lease.

### Drain (Q6)
In the inventory-delete path and both photo handlers only (NOT every `recordMutation`): read `pending_cleanup` ordered by `createdAt`, limit 10 (single-field index, no composite), keep markers older than 60 000 ms and not the current request's product, take at most 3, `sweepMarker` each, **awaited before responding** (Cloud Functions v2 throttles CPU after `res.send`). Log one line with the drained count. Pure selector `selectDrainable(markers, now, excludeProductId, limit, minAgeMs)`.

### Batch and ops (Q11)
Shared predicate `isCascadeEntityDelete(entity, action)` in `gatewayLogic.js`. `recordMutationsBatch` rejects a batch containing it: `400`, zero writes, whole batch rejected. `recordOperation` rejects an op containing it: `400` with `opIndex`, zero writes. Other deletes, creates, updates and delta ops unchanged.

### `firestore.rules`
Inside `match /tenants/{tenantId}`, BEFORE the `/{collection}/{docId}` wildcard (which lets members read and conditionally write any collection not server-only): `match /pending_cleanup/{docId} { allow read, write: if false; }`, same shape as `locks`/`audit_log`. Rules test required. `storage.rules` unchanged (public read, no client write).

### Interactions
- **P1 stock movements (planned, NOT merged):** its S1a/S1b also edit `applyMutation`, batch and ops (batch cap 200->150, ops write budgets). Expect merge conflicts in `gatewayLogic.js`; the two changes are independent. Q11 means no marker writes in batch/ops, so P1's write-budget arithmetic is unaffected. Single path gains one write per inventory delete (marker).
- **F5 stays:** strict `before` compare including `photoIds` at all three sites. Add one pin test documenting it.

## S4 — client design
1. `PhotoQueueLogic.js`: `TERMINAL_STATUS` `{400,413,404,409}` -> add `403`. A 403 goes straight to `failed` (existing Retry/Discard UI). Accepted trade-off: a reactivated suspended member's `no-tenant-context` 403 also needs a manual Retry.
2. `StorageService._nextPhotoId`: `"photo-" + Qt.uuid()` with `{`/`}` stripped. UNVERIFIED that `Qt.uuid()` works in headless `qmltestrunner`: confirm on the first CI run; if not, stub in tests.
3. `InventoryStore.deleteProduct`: delete the `removeProductPhoto` loop over `before.photoIds` and the legacy `photoUrl` -> `ImageProcessor.removeLocalCopy(productId)` branch. KEEP the `PhotoQueue` purge of queued photos for that product (local files; the server cannot do it). Result: photos are only destroyed after a committed delete.
4. Fold L1 (breaker open re-arms a 250 ms timer for the whole cooldown) only if the fix is <=3 lines: re-arm at `cooldownUntil`. Otherwise drop.
5. Standalone remove-photo button already surfaces failures via `removeFailed(photoId, err)` (`ProductPhotoGallery.qml` ~L76): no change.

## S5 — remove legacy PRODUCT `photoUrl`/`photoUpdatedAt`
Remove: `InventoryStore.qml` normalize (L132-133), clone fields (L198-199, L226), `setPhoto` (L622-630, dead), clear-legacy helper (L663-674), upsert/import fields (L985-997); `EditProductDialog.qml` property, load, reset and the "Upload this photo" migration UI (L14/31/147/219/299-304); `InventoryPage.qml` thumbnail fallback (L241); `StorageService.qml` legacy comments (L12/37); `XlsxService.cpp` export column 11 "Photo URL" (L81) and `ImportPreviewDialog.qml` import "Photo URL" (L460/482); tests `tst_InventoryStore_deleteProductCascade.qml`, `tst_InventoryStore_photoIds.qml`, `test/felgo-dependent/tst_InventoryPage_deleteButton.qml`. **Must check before editing:** whether dropping export column 11 shifts later columns, and whether the import template/docs mention it (user-visible spreadsheet format change): decide remove-vs-blank then. **Never touch** AuthStore, AuthService, ProfilePage, `provisionMember`.

## Known limits (accepted, to be written into KNOWN-ISSUES / photo design spec at implementation)
F5 stale-edit 409 (user redoes the edit). Idle tenant: a failed sweep waits for the next delete/photo action. Residual race between upload preflight and Storage write. No timeliness guarantee on cleanup. Photo gate is partial hardening (staff token can still edit/delete products via `recordMutation`).

## Not building
Generic cross-device operation journal / lock (existing `lockLogic.js` is a 90 s TTL lock and does not fit a persistent "deleting" state; CAS already 409s stale edits after a delete; atomic product+batches delete belongs to the delete roadmap via one `recordOperation`). Firestore trigger or scheduled function for cleanup. Server-minted photo ids. Offline photo cache. Deleting `FailedTileGeometry.js`. D1 attempt counting. General `authorize(role, entity, action)` (KNOWN-ISSUES).

## Docs to update when implementing
`KNOWN-ISSUES.md` (F5 accepted entry; note photo gate in the authz entry is already cross-linked), photo design spec "Known limits", `AGENTS.md` file-map lines for `photoCleanup.js` and the new `pending_cleanup` collection, `README.md` if it lists collections, `SKILLS.md` (new skill only for lessons actually hit), test-plans `README.md` row (added with this design).

## Acceptance
S3: functions suite green incl. new tests, rules + e2e green on CI, no Storage write on any 403/404/409 upload, marker written iff a delete committed. S4: CI green, `deleteProduct` issues no `removeProductPhoto`, 403 never retries. S5: no product `photoUrl` reference left except the test that asserts absence; profile photo untouched.
