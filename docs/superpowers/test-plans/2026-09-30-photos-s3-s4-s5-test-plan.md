# Test plan — photos PH3 (server), PH4 (client), PH5 (legacy removal)

**Branches (planned, names may differ):** PH3 `feat/2026-10-01-photos-ph3-server`, PH4 `feat/2026-10-01-photos-ph4-client`, PH5 `feat/2026-10-01-photos-ph5-legacy-removal`.
**Design:** `docs/superpowers/specs/2026-09-30-photos-ph3-s4-design.md`. **Checkpoint:** `2026-09-30-photos-pending-design-CHECKPOINT.md`.
**Written before implementation. NOTHING here has been run**: the design session wrote no code, had no Qt toolchain (standing rule) and did not run the Node suite. Every status below is `planned`; implementation PRs replace it with the CI result. Counts below are computed from the case lists by the generator script, not typed (Skill 49).
**Environment:** dev only, new tenant per PR, no offline operation (app disabled offline), no legacy `photoUrl`.
**Coverage bar (Taher):** 100% line coverage of new/changed code, happy + negative + edge + multi-scenario + monkey. Server pure logic can be measured in the sandbox (`node --test --experimental-test-coverage`); QML is CI-only.

**Totals (planned):** unit 41 + functional 36 = 77 Node cases (runnable in the sandbox); rules 11 + e2e 12 + client QML 26 + PH5 QML 12 = 61 CI-only cases. Grand total 138. Case ids are NOT renumbered after the 2026-10-01 review: U21-U27, F11-F13, F17, F29 moved to PH3b, so ids have gaps; U48, F40, F41, C26 are new.

## 1. Unit tests (pure logic, `functions/test/`) — 41 planned
New file `functions/lib/photoCleanup.js` (`buildSweepPrefix`, `buildMarker`, `canManagePhotos`, `isCascadeEntityDelete`, `evaluateUploadPreflight`, `sweepMarker`) and the whitelist in `photoValidation.js`. Status: planned.

| ID | Case | File |
|---|---|---|
| U01 | whitelist: plain valid id accepted | functions/test/photoValidation.test.js |
| U02 | whitelist: uuid-style id with hyphens accepted | functions/test/photoValidation.test.js |
| U03 | whitelist: exactly 64 chars accepted | functions/test/photoValidation.test.js |
| U04 | whitelist: 65 chars rejected | functions/test/photoValidation.test.js |
| U05 | whitelist: empty string rejected | functions/test/photoValidation.test.js |
| U06 | whitelist: `.` and `..` rejected | functions/test/photoValidation.test.js |
| U07 | whitelist: `/` and `\` rejected | functions/test/photoValidation.test.js |
| U08 | whitelist: space, tab, newline rejected | functions/test/photoValidation.test.js |
| U09 | whitelist: emoji, RTL, combining chars rejected | functions/test/photoValidation.test.js |
| U10 | whitelist: percent-encoded `%2e%2e` rejected | functions/test/photoValidation.test.js |
| U11 | whitelist: null, undefined, number, object, array rejected | functions/test/photoValidation.test.js |
| U12 | MONKEY whitelist: 1000 random strings, accepted iff regex oracle says so | functions/test/photoValidation.test.js |
| U13 | buildSweepPrefix: exact `env/tenants/t/products/p/` | functions/test/photoCleanup.test.js (new) |
| U14 | buildSweepPrefix: always ends with `/` | functions/test/photoCleanup.test.js (new) |
| U15 | buildSweepPrefix: empty productId -> null (would widen to `products/`) | functions/test/photoCleanup.test.js (new) |
| U16 | buildSweepPrefix: unsafe tenant, product or env segment -> null, each separately | functions/test/photoCleanup.test.js (new) |
| U17 | buildSweepPrefix: env prefix containing `/` -> null | functions/test/photoCleanup.test.js (new) |
| U18 | MONKEY buildSweepPrefix: random ids never yield a prefix outside its own tenant+product | functions/test/photoCleanup.test.js (new) |
| U19 | buildMarker: fields present, attempts 0, lastError null, prefix copied | functions/test/photoCleanup.test.js (new) |
| U20 | buildMarker: null prefix refused | functions/test/photoCleanup.test.js (new) |
| U28 | canManagePhotos: owner, admin true | functions/test/photoCleanup.test.js (new) |
| U29 | canManagePhotos: manager, staff false | functions/test/photoCleanup.test.js (new) |
| U30 | canManagePhotos: empty, undefined, null, viewer, `OWNER`, `Owner ` false | functions/test/photoCleanup.test.js (new) |
| U31 | isCascadeEntityDelete: inventory+delete true | functions/test/photoCleanup.test.js (new) |
| U32 | isCascadeEntityDelete: inventory create/update/opening_balance false | functions/test/photoCleanup.test.js (new) |
| U33 | isCascadeEntityDelete: stock_batch, order, staff, supplier, transaction, removed_staff + delete false | functions/test/photoCleanup.test.js (new) |
| U34 | isCascadeEntityDelete: wrong case / undefined false | functions/test/photoCleanup.test.js (new) |
| U35 | preflight: missing product -> 404 | functions/test/photoCleanup.test.js (new) |
| U36 | preflight: cap reached, new photoId -> 409 | functions/test/photoCleanup.test.js (new) |
| U37 | preflight: cap reached, photoId already present (replay) -> ok | functions/test/photoCleanup.test.js (new) |
| U38 | preflight: below cap -> ok | functions/test/photoCleanup.test.js (new) |
| U39 | preflight: photoIds missing or not an array treated as empty | functions/test/photoCleanup.test.js (new) |
| U40 | sweepMarker: product exists again -> marker deleted, deleteFiles NOT called | functions/test/photoCleanup.test.js (new) |
| U41 | sweepMarker: product absent -> deleteFiles once with exact prefix, marker deleted | functions/test/photoCleanup.test.js (new) |
| U42 | sweepMarker: deleteFiles throws -> marker kept, attempts+1, lastError set and truncated to 200 | functions/test/photoCleanup.test.js (new) |
| U43 | sweepMarker: marker delete throws -> swallowed | functions/test/photoCleanup.test.js (new) |
| U44 | sweepMarker: product read throws -> marker kept, attempts+1, no sweep (never sweep when unsure) | functions/test/photoCleanup.test.js (new) |
| U45 | sweepMarker: null prefix, prefix not ending `/`, or prefix != rebuilt prefix -> no deleteFiles, marker kept with lastError | functions/test/photoCleanup.test.js (new) |
| U46 | sweepMarker: second run with no files -> ok | functions/test/photoCleanup.test.js (new) |
| U47 | sweepMarker: two concurrent sweeps of one marker both finish | functions/test/photoCleanup.test.js (new) |
| U48 | sweepMarker: missing or unsafe `envPrefix` -> no deleteFiles, marker kept with lastError (review I2) | functions/test/photoCleanup.test.js (new) |

## 2. Functional tests (handler level, in-memory Firestore/Storage fakes) — 36 planned
`functions/test/index.handlers.test.js` (additions) and new `photoCascade.handlers.test.js`; batch/ops/F5 cases in `batchMutationLogic.test.js`, `operationLogic.test.js`, `gatewayLogic.test.js`. Status: planned.

| ID | Case | File |
|---|---|---|
| F01 | upload: staff -> 403 role-not-allowed | functions/test/index.handlers.photos.test.js |
| F02 | upload: manager -> 403 | functions/test/index.handlers.photos.test.js |
| F03 | upload 403: zero Firestore reads, zero Storage saves | functions/test/index.handlers.photos.test.js |
| F04 | upload: owner happy path, both objects saved, photoIds updated | functions/test/index.handlers.photos.test.js |
| F05 | upload: admin happy path | functions/test/index.handlers.photos.test.js |
| F06 | upload: photoId with `/` -> 400, nothing read or written | functions/test/index.handlers.photos.test.js |
| F07 | upload: product missing -> 404 and ZERO Storage saves (F3) | functions/test/index.handlers.photos.test.js |
| F08 | upload: cap reached -> 409 and ZERO Storage saves (F3) | functions/test/index.handlers.photos.test.js |
| F09 | upload: same requestId replay -> idempotent, no extra object | functions/test/index.handlers.photos.test.js |
| F10 | upload: product deleted after preflight -> txn 404 (pins the documented orphan limit) | functions/test/index.handlers.photos.test.js |
| F14 | deletePhoto: staff/manager -> 403, zero Storage deletes | functions/test/index.handlers.photos.test.js |
| F15 | deletePhoto: owner happy path | functions/test/index.handlers.photos.test.js |
| F16 | deletePhoto: invalid ids -> 400 | functions/test/index.handlers.photos.test.js |
| F18 | inventory delete: marker written in SAME txn (delete doc, audit, marker, one commit) | functions/test/index.handlers.test.js + gatewayLogic.test.js |
| F19 | inventory delete: marker prefix and envPrefix correct for dev and prod env, attempts 0 | functions/test/index.handlers.test.js + gatewayLogic.test.js |
| F20 | inventory delete: post-commit sweep deletes exactly the product prefix, marker removed | functions/test/index.handlers.test.js |
| F21 | inventory delete: sweep failure -> still 200, marker retained with lastError | functions/test/index.handlers.test.js |
| F22 | inventory delete: CAS 409 -> no marker, no sweep, zero Storage calls | functions/test/index.handlers.test.js + gatewayLogic.test.js |
| F23 | inventory delete: idempotent replay -> no second marker, no second sweep | functions/test/index.handlers.test.js + gatewayLogic.test.js |
| F24 | inventory update -> no marker | functions/test/index.handlers.test.js |
| F25 | stock_batch / order / staff delete -> no marker, no sweep | functions/test/index.handlers.test.js |
| F26 | inventory delete with unsafe entityId -> 400 invalid-entity-id, nothing written | functions/test/index.handlers.test.js |
| F27 | inventory delete of product with zero photos -> marker written, sweep harmless | functions/test/index.handlers.test.js |
| F28 | id reuse: recreate before the sweep runs -> sweep drops the marker, new product photos intact | functions/test/index.handlers.test.js |
| F30 | staff-role inventory delete behaves as today (no new gate; pin) | functions/test/index.handlers.test.js |
| F31 | batch with inventory delete -> 400, zero writes | functions/test/batchMutationLogic.test.js |
| F32 | batch of valid creates + one inventory delete -> whole batch rejected, zero writes | functions/test/batchMutationLogic.test.js |
| F33 | batch non-inventory delete still accepted | functions/test/batchMutationLogic.test.js |
| F34 | ops with inventory delete -> 400 with opIndex, zero writes | functions/test/operationLogic.test.js |
| F35 | ops delta and non-inventory delete unaffected | functions/test/operationLogic.test.js |
| F36 | batch inventory create (import path) unaffected | functions/test/batchMutationLogic.test.js |
| F37 | F5 pin, single path: stale before.photoIds -> 409 conflict | functions/test/gatewayLogic.test.js |
| F38 | F5 pin, batch path | functions/test/batchMutationLogic.test.js |
| F39 | F5 pin, ops path | functions/test/operationLogic.test.js |
| F40 | deletePhoto: product doc missing -> 200, both Storage objects still deleted (Q13 pin) | functions/test/index.handlers.photos.test.js |
| F41 | recordMutation delete of a server-absent product with non-null before -> 409 conflict, `current:null`, no marker, no sweep (Q13 pin) | functions/test/index.handlers.test.js |

### Moved to PH3b (scheduled cleanup function, design open; case texts kept for the PH3b plan)
U21-U27 `selectDrainable` (age boundary, exclusion, cap 3, monkey) become `selectDue` cases when the schema is decided (Q-E). F11-F13, F17, F29 (drain piggyback in handlers) are replaced by `runCleanupSweep` cases: attempts cap 5 parks and leaves the query, backoff per attempt, per-env isolation, per-marker isolation, throw-at-end, summary log, 25-per-run budget, empty run is cheap. Plus one emulator e2e calling `runCleanupSweep` directly and a DV item for the real scheduler firing.

## 3. Rules tests (emulator, CI only) — 11 planned
`firestore.rules` (`'pending_cleanup'` added to `isServerOnlyCollection`, review C1) + `storage.rules`. Files: `test/firestore.rules.test.js`, `test/storage.rules.test.js`. Status: planned, CI only.

| ID | Case | File |
|---|---|---|
| R01 | pending_cleanup: member read denied | test/firestore.rules.test.js |
| R02 | member create denied | test/firestore.rules.test.js |
| R03 | member update denied | test/firestore.rules.test.js |
| R04 | member delete denied | test/firestore.rules.test.js |
| R05 | owner denied all four | test/firestore.rules.test.js |
| R06 | unauthenticated denied | test/firestore.rules.test.js |
| R07 | member of another tenant denied | test/firestore.rules.test.js |
| R08 | PIN wildcard collections unchanged (member still reads inventory) | test/firestore.rules.test.js |
| R09 | PIN `locks` and `audit_log` still denied | test/firestore.rules.test.js |
| R10 | PIN storage.rules: public read allowed, client write denied | test/storage.rules.test.js |
| R11 | forged marker attempt by a member leaves no marker behind | test/firestore.rules.test.js |

## 4. End-to-end (emulator: functions + Firestore + Storage, CI only) — 12 planned
Status: planned, CI only. Needs the Storage emulator hook for E05.

| ID | Case | File |
|---|---|---|
| E01 | owner: create product, upload, delete product -> Storage prefix empty, marker gone | test/e2e/tst_ProductPhotosE2E.qml (extend; raw `E2EHelpers.postDirect`) |
| E02 | staff token: upload 403 and deletePhoto 403, Storage untouched | test/e2e/tst_ProductPhotosE2E.qml (extend; raw `E2EHelpers.postDirect`) |
| E03 | admin token upload happy path | test/e2e/tst_ProductPhotosE2E.qml (extend; raw `E2EHelpers.postDirect`) |
| E04 | stale-before delete -> 409, photos and product both intact | test/e2e/tst_ProductPhotosE2E.qml (extend; raw `E2EHelpers.postDirect`) |
| E05 | injected sweep failure -> delete 200, marker present with attempts 1 and lastError (drain proof moves to PH3b) | test/e2e/tst_ProductPhotosE2E.qml (extend; raw `E2EHelpers.postDirect`) |
| E06 | recreate same productId before the sweep runs -> marker dropped, new photos intact | test/e2e/tst_ProductPhotosE2E.qml (extend; raw `E2EHelpers.postDirect`) |
| E07 | upload to a deleted product -> 404, zero objects | test/e2e/tst_ProductPhotosE2E.qml (extend; raw `E2EHelpers.postDirect`) |
| E08 | two products: delete A, B photos untouched (prefix-widening guard) | test/e2e/tst_ProductPhotosE2E.qml (extend; raw `E2EHelpers.postDirect`) |
| E09 | two tenants, same productId: delete in one leaves the other intact | test/e2e/tst_ProductPhotosE2E.qml (extend; raw `E2EHelpers.postDirect`) |
| E10 | batch inventory delete -> 400 end to end | test/e2e/tst_ProductPhotosE2E.qml (extend; raw `E2EHelpers.postDirect`) |
| E11 | photo cap reached -> 409, zero extra objects | test/e2e/tst_ProductPhotosE2E.qml (extend; raw `E2EHelpers.postDirect`) |
| E12 | MONKEY 30 random interleavings of create/upload/delete/recreate over 3 products; invariant: no Storage object belongs to a deleted product except the documented race | test/e2e/tst_ProductPhotosE2E.qml (extend; raw `E2EHelpers.postDirect`) |

## 5. Client QML (PH4) — 26 planned, CI only (no Qt in the sandbox)
`tests/tst_PhotoQueueLogic.qml`, `tests/tst_StorageService*.qml`, `tests/tst_InventoryStore_deleteProductCascade.qml`, gallery test. Status: planned, CI only.

| ID | Case | File |
|---|---|---|
| C01 | classify 403 -> terminal | tests/tst_PhotoQueueLogic.qml |
| C02 | 400/404/409/413 still terminal (regression) | tests/tst_PhotoQueueLogic.qml |
| C03 | 500/502/503/0 still transient | tests/tst_PhotoQueueLogic.qml |
| C04 | reduceQueueItem failed 403 -> state failed on attempt 1, no backoff scheduled | tests/tst_PhotoQueueLogic.qml |
| C05 | failed 403 then retry() -> enqueued again (Retry UI works) | tests/tst_PhotoQueueLogic.qml |
| C06 | breaker still counts a 403 failure | tests/tst_PhotoQueueLogic.qml |
| C07 | _nextPhotoId matches `^photo-[A-Za-z0-9_-]{36}$` | tests/tst_StorageServicePhotoId.qml (new) |
| C08 | _nextPhotoId strips braces when Qt.uuid is stubbed with braces | tests/tst_StorageServicePhotoId.qml (new) |
| C09 | _nextPhotoId length <= 64 | tests/tst_StorageServicePhotoId.qml (new) |
| C10 | 1000 ids all unique | tests/tst_StorageServicePhotoId.qml (new) |
| C11 | id passes a mirror of the server whitelist regex (parity test) | tests/tst_StorageServicePhotoId.qml (new) |
| C12 | MONKEY stubbed Qt.uuid uppercase/odd canonical forms -> still whitelist-safe | tests/tst_StorageServicePhotoId.qml (new) |
| C13 | deleteProduct with 3 photoIds: zero removeProductPhoto calls | tests/tst_InventoryStore_deleteProductCascade.qml |
| C14 | deleteProduct: only THIS product's queued photos discarded, others remain | tests/tst_InventoryStore_deleteProductCascade.qml |
| C15 | deleteProduct: queue purge throws -> delete and batch cascade still complete | tests/tst_InventoryStore_deleteProductCascade.qml |
| C16 | deleteProduct with no photoIds and empty queue -> no error | tests/tst_InventoryStore_deleteProductCascade.qml |
| C17 | deleteProduct: no ImageProcessor.removeLocalCopy(productId) (legacy branch gone) | tests/tst_InventoryStore_deleteProductCascade.qml |
| C18 | deleteProduct queues exactly one delete mutation with correct before | tests/tst_InventoryStore_deleteProductCascade.qml |
| C19 | delete then 409 conflict -> row restored, removeProductPhoto never called | tests/tst_InventoryStore_deleteProductCascade.qml |
| C20 | headless env, ImageProcessor undefined -> no throw | tests/tst_InventoryStore_deleteProductCascade.qml |
| C21 | stock-batch cascade unaffected (existing cases still pass) | tests/tst_InventoryStore_deleteProductCascade.qml |
| C22 | L1 (only if folded): breaker open -> timer armed once at cooldownUntil, not 250 ms | tests/tst_PhotoQueue.qml |
| C23 | L1 (only if folded): after cooldown the queue drains | tests/tst_PhotoQueue.qml |
| C24 | gallery remove fails with 403 -> removeFailed emitted with status text | tests/tst_PhotoGalleryLayout.qml, or a `test/felgo-dependent/` file if the gallery imports Felgo (decide at PH4) |
| C25 | gallery remove ok -> applyPhotoIds called with remaining ids | tests/tst_PhotoGalleryLayout.qml, or a `test/felgo-dependent/` file if the gallery imports Felgo (decide at PH4) |
| C26 | delete conflict with `current:null` -> local row removed, toast says already deleted (not "restored"); delete conflict with non-null current keeps the old toast | tests/tst_InventoryStore_deleteProductCascade.qml |

## 6. Client QML (PH5, legacy removal) — 12 planned, CI only

| ID | Case | File |
|---|---|---|
| S01 | normalize does not create photoUrl/photoUpdatedAt | tests/tst_InventoryStore_photoIds.qml |
| S02 | doc already carrying photoUrl loads without error and the field is not propagated on save | tests/tst_InventoryStore_photoIds.qml |
| S03 | clone and upsert payloads contain no photoUrl | tests/tst_InventoryStore_photoIds.qml |
| S04 | import without a Photo URL column parses | decide at PH5 (candidates: `test/felgo-dependent/tst_InventoryPage_deleteButton.qml`, new import/export test) |
| S05 | import with a stale Photo URL column ignores it without error | decide at PH5 (candidates: `test/felgo-dependent/tst_InventoryPage_deleteButton.qml`, new import/export test) |
| S06 | export has no Photo URL column; later columns aligned (or blank, per PH5 decision): pin | decide at PH5 (candidates: `test/felgo-dependent/tst_InventoryPage_deleteButton.qml`, new import/export test) |
| S07 | EditProductDialog has no 'Upload this photo' control | decide at PH5 (candidates: `test/felgo-dependent/tst_InventoryPage_deleteButton.qml`, new import/export test) |
| S08 | InventoryPage card shows placeholder when no photoIds | decide at PH5 (candidates: `test/felgo-dependent/tst_InventoryPage_deleteButton.qml`, new import/export test) |
| S09 | REGRESSION profile photoUrl still saved and loaded (AuthStore/AuthService) | existing AuthStore/AuthService test (find at PH5) |
| S10 | guard test: no `photoUrl` token in InventoryStore, EditProductDialog, InventoryPage, ImportPreviewDialog | decide at PH5 (candidates: `test/felgo-dependent/tst_InventoryPage_deleteButton.qml`, new import/export test) |
| S11 | setPhoto removed, no callers | tests/tst_InventoryStore_photoIds.qml |
| S12 | C++ XlsxService builds on CI | CI build job |

## 7. Regression coverage (why these exist)
Defects this work pins, by case id: F22, E04, C19 (destroy-before-ack) | F37-F39 (F5 pin) | R01-R05, R11 (rules wildcard trap) | U15, U45, E08, E09 (prefix widening) | F07, F08 (F3 orphans) | C01, C05 (403 retry loop) | S09 (profile photo).

## 8. Mutation checks to run in the sandbox for PH3 (Node side, planned)
Remove role gate; skip preflight; write marker outside the txn; write marker on CAS conflict; sweep without the product-absent re-check; drop the `/` suffix guard; widen whitelist to allow `/`; batch/ops reject removed. Each must turn at least one case red.

## 9. On-Device Test Plan (new tenant per PR; app is disabled offline so no offline steps)

### Happy Path
- [ ] Owner: add photo to a product; it shows in the tile and the gallery.
- [ ] Admin: same.
- [ ] Owner: delete a product that has 3 photos; open a former photo URL in a browser: it is gone (404). Check the Storage console: the product prefix is empty.
- [ ] After that delete, Firestore `pending_cleanup` has no doc for the product.
- [ ] Delete a product with no photos: no error, no leftover marker.

### Negative Cases
- [ ] Staff login: no photo controls visible.
- [ ] Demote an admin to staff while a photo sits queued: the tile ends in `failed` with Retry/Discard (one attempt, no retry loop).
- [ ] Try to upload a 6th photo (cap): clear failure, nothing extra in Storage.
- [ ] Product deleted on device B while device A has an upload queued: A's tile ends failed/purged, nothing appears in Storage.

### Edge Cases
- [ ] Device A edits the price while device B uploads a photo to the same product: A's save gets the conflict toast, row reverts to server state, A redoes the edit (accepted F5 behavior). Check whether an inventory-specific conflict toast actually shows (UNVERIFIED).
- [ ] Delete a product, recreate one with the same name within a minute: new product's photos unaffected.
- [ ] Delete a product on device A that device B already deleted: A's row disappears and the toast says it was already deleted, not "restored" (Q13, PH4).
- [ ] Delete fails with a conflict (edit the product on device B first): photos on device A's product are still visible afterwards (destroy-before-ack fixed).
- [ ] Product with 5 photos deleted: all 10 objects (main + thumb) gone.

### Multiple scenarios
- [ ] Two devices deleting two different products at once.
- [ ] Delete on A while B is mid-upload to the same product.
- [ ] Owner on A, admin on B, both uploading to different products.

### Monkey Testing
- [ ] 10 rapid add-photo / delete-product / recreate cycles across 3 products; no crash, no broken tile, Storage console shows no prefix of a deleted product.
- [ ] Kill the app right after tapping delete (before the toast): relaunch, the outbox finishes the delete; the post-commit sweep removes the marker (if it failed, the marker waits for PH3b).
- [ ] Toggle airplane mode mid-upload: app disables itself; on reconnect the queue resumes or fails cleanly.
- [ ] Spam the remove-photo button; rotate the device during a delete.

### Affected Areas (regression)
| Area | Automated | On-device check |
|---|---|---|
| `uploadProductPhoto`, `deleteProductPhoto` | sections 1, 2, 4 | upload/remove as owner |
| `recordMutation` inventory delete | sections 2, 4 | delete product |
| `recordMutationsBatch` (import) | F31-F36 | import a spreadsheet of products |
| `recordOperation` | F34, F35 (server tests only; no QML caller exists, nothing to check on device) | none |
| `firestore.rules` wildcard | section 3 | normal inventory edit still works |
| `PhotoQueueLogic`, `PhotoQueue` | section 5 | failed-tile Retry/Discard |
| `InventoryStore.deleteProduct` | section 5 | delete product with batches |
| PH5: edit dialog, inventory card, import/export | section 6 | open edit dialog, export, import |
| Profile photo | S09 | change profile photo |

### Regression Tests (manual counterpart)
- [ ] Delete a product: stock batches also disappear (older cascade).
- [ ] Order reopen/reversal does not resurrect a deleted batch.
- [ ] Bulk import still creates products.

### DV: device verification gap to close
- [ ] Confirm on the real Storage plan (not the emulator) that the prefix sweep removes objects.
- [ ] Read Cloud Functions logs: no sweep error for a normal delete.
- [ ] Check no `pending_cleanup` doc is older than a few minutes after normal use.

### Known unknowns
`Qt.uuid()` in headless `qmltestrunner`; whether the inventory 409 shows a toast; whether dropping export column 11 shifts later columns; how Storage emulator can be made to fail a delete (E05).
