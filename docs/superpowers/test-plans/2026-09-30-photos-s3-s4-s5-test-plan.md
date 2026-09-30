# Test plan — photos S3 (server), S4 (client), S5 (legacy removal)

**Branches (planned, names may differ):** S3 `feat/2026-10-01-photos-s3-server`, S4 `feat/2026-10-01-photos-s4-client`, S5 `feat/2026-10-01-photos-s5-legacy-removal`.
**Design:** `docs/superpowers/specs/2026-09-30-photos-s3-s4-design.md`. **Checkpoint:** `2026-09-30-photos-pending-design-CHECKPOINT.md`.
**Written before implementation. NOTHING here has been run**: the design session wrote no code, had no Qt toolchain (standing rule) and did not run the Node suite. Every status below is `planned`; implementation PRs replace it with the CI result. Counts below are computed from the case lists by the generator script, not typed (Skill 49).
**Environment:** dev only, new tenant per PR, no offline operation (app disabled offline), no legacy `photoUrl`.
**Coverage bar (Taher):** 100% line coverage of new/changed code, happy + negative + edge + multi-scenario + monkey. Server pure logic can be measured in the sandbox (`node --test --experimental-test-coverage`); QML is CI-only.

**Totals (planned):** unit 47 + functional 39 = 86 Node cases (runnable in the sandbox); rules 11 + e2e 12 + client QML 25 + S5 QML 12 = 60 CI-only cases. Grand total 146.

## 1. Unit tests (pure logic, `functions/test/`) — 47 planned
New file `functions/lib/photoCleanup.js` (`buildSweepPrefix`, `buildMarker`, `selectDrainable`, `canManagePhotos`, `isCascadeEntityDelete`, `evaluateUploadPreflight`, `sweepMarker`) and the whitelist in `photoValidation.js`. Status: planned.

| ID | Case | File |
|---|---|---|
| U01 | whitelist: plain valid id accepted | `photoValidation.test.js` / `photoCleanup.test.js` |
| U02 | whitelist: uuid-style id with hyphens accepted | `photoValidation.test.js` / `photoCleanup.test.js` |
| U03 | whitelist: exactly 64 chars accepted | `photoValidation.test.js` / `photoCleanup.test.js` |
| U04 | whitelist: 65 chars rejected | `photoValidation.test.js` / `photoCleanup.test.js` |
| U05 | whitelist: empty string rejected | `photoValidation.test.js` / `photoCleanup.test.js` |
| U06 | whitelist: `.` and `..` rejected | `photoValidation.test.js` / `photoCleanup.test.js` |
| U07 | whitelist: `/` and `\` rejected | `photoValidation.test.js` / `photoCleanup.test.js` |
| U08 | whitelist: space, tab, newline rejected | `photoValidation.test.js` / `photoCleanup.test.js` |
| U09 | whitelist: emoji, RTL, combining chars rejected | `photoValidation.test.js` / `photoCleanup.test.js` |
| U10 | whitelist: percent-encoded `%2e%2e` rejected | `photoValidation.test.js` / `photoCleanup.test.js` |
| U11 | whitelist: null, undefined, number, object, array rejected | `photoValidation.test.js` / `photoCleanup.test.js` |
| U12 | MONKEY whitelist: 1000 random strings, accepted iff regex oracle says so | `photoValidation.test.js` / `photoCleanup.test.js` |
| U13 | buildSweepPrefix: exact `env/tenants/t/products/p/` | `photoValidation.test.js` / `photoCleanup.test.js` |
| U14 | buildSweepPrefix: always ends with `/` | `photoValidation.test.js` / `photoCleanup.test.js` |
| U15 | buildSweepPrefix: empty productId -> null (would widen to `products/`) | `photoValidation.test.js` / `photoCleanup.test.js` |
| U16 | buildSweepPrefix: unsafe tenant, product or env segment -> null, each separately | `photoValidation.test.js` / `photoCleanup.test.js` |
| U17 | buildSweepPrefix: env prefix containing `/` -> null | `photoValidation.test.js` / `photoCleanup.test.js` |
| U18 | MONKEY buildSweepPrefix: random ids never yield a prefix outside its own tenant+product | `photoValidation.test.js` / `photoCleanup.test.js` |
| U19 | buildMarker: fields present, attempts 0, lastError null, prefix copied | `photoValidation.test.js` / `photoCleanup.test.js` |
| U20 | buildMarker: null prefix refused | `photoValidation.test.js` / `photoCleanup.test.js` |
| U21 | selectDrainable: empty list -> [] | `photoValidation.test.js` / `photoCleanup.test.js` |
| U22 | selectDrainable: age boundary 59 999 ms excluded, 60 000 ms included | `photoValidation.test.js` / `photoCleanup.test.js` |
| U23 | selectDrainable: excludes the current product | `photoValidation.test.js` / `photoCleanup.test.js` |
| U24 | selectDrainable: caps at 3, oldest first | `photoValidation.test.js` / `photoCleanup.test.js` |
| U25 | selectDrainable: missing/invalid createdAt skipped | `photoValidation.test.js` / `photoCleanup.test.js` |
| U26 | selectDrainable: limit 0 -> [] | `photoValidation.test.js` / `photoCleanup.test.js` |
| U27 | MONKEY selectDrainable: random sets never exceed limit, include excluded id, or beat minAge | `photoValidation.test.js` / `photoCleanup.test.js` |
| U28 | canManagePhotos: owner, admin true | `photoValidation.test.js` / `photoCleanup.test.js` |
| U29 | canManagePhotos: manager, staff false | `photoValidation.test.js` / `photoCleanup.test.js` |
| U30 | canManagePhotos: empty, undefined, null, viewer, `OWNER`, `Owner ` false | `photoValidation.test.js` / `photoCleanup.test.js` |
| U31 | isCascadeEntityDelete: inventory+delete true | `photoValidation.test.js` / `photoCleanup.test.js` |
| U32 | isCascadeEntityDelete: inventory create/update/opening_balance false | `photoValidation.test.js` / `photoCleanup.test.js` |
| U33 | isCascadeEntityDelete: stock_batch, order, staff, supplier, transaction, removed_staff + delete false | `photoValidation.test.js` / `photoCleanup.test.js` |
| U34 | isCascadeEntityDelete: wrong case / undefined false | `photoValidation.test.js` / `photoCleanup.test.js` |
| U35 | preflight: missing product -> 404 | `photoValidation.test.js` / `photoCleanup.test.js` |
| U36 | preflight: cap reached, new photoId -> 409 | `photoValidation.test.js` / `photoCleanup.test.js` |
| U37 | preflight: cap reached, photoId already present (replay) -> ok | `photoValidation.test.js` / `photoCleanup.test.js` |
| U38 | preflight: below cap -> ok | `photoValidation.test.js` / `photoCleanup.test.js` |
| U39 | preflight: photoIds missing or not an array treated as empty | `photoValidation.test.js` / `photoCleanup.test.js` |
| U40 | sweepMarker: product exists again -> marker deleted, deleteFiles NOT called | `photoValidation.test.js` / `photoCleanup.test.js` |
| U41 | sweepMarker: product absent -> deleteFiles once with exact prefix, marker deleted | `photoValidation.test.js` / `photoCleanup.test.js` |
| U42 | sweepMarker: deleteFiles throws -> marker kept, attempts+1, lastError set and truncated to 200 | `photoValidation.test.js` / `photoCleanup.test.js` |
| U43 | sweepMarker: marker delete throws -> swallowed | `photoValidation.test.js` / `photoCleanup.test.js` |
| U44 | sweepMarker: product read throws -> marker kept, attempts+1, no sweep (never sweep when unsure) | `photoValidation.test.js` / `photoCleanup.test.js` |
| U45 | sweepMarker: null prefix, prefix not ending `/`, or prefix != rebuilt prefix -> no deleteFiles, marker kept with lastError | `photoValidation.test.js` / `photoCleanup.test.js` |
| U46 | sweepMarker: second run with no files -> ok | `photoValidation.test.js` / `photoCleanup.test.js` |
| U47 | sweepMarker: two concurrent sweeps of one marker both finish | `photoValidation.test.js` / `photoCleanup.test.js` |

## 2. Functional tests (handler level, in-memory Firestore/Storage fakes) — 39 planned
`functions/test/index.handlers.test.js` (additions) and new `photoCascade.handlers.test.js`; batch/ops/F5 cases in `batchMutationLogic.test.js`, `operationLogic.test.js`, `gatewayLogic.test.js`. Status: planned.

| ID | Case | File |
|---|---|---|
| F01 | upload: staff -> 403 role-not-allowed | handlers / logic tests |
| F02 | upload: manager -> 403 | handlers / logic tests |
| F03 | upload 403: zero Firestore reads, zero Storage saves | handlers / logic tests |
| F04 | upload: owner happy path, both objects saved, photoIds updated | handlers / logic tests |
| F05 | upload: admin happy path | handlers / logic tests |
| F06 | upload: photoId with `/` -> 400, nothing read or written | handlers / logic tests |
| F07 | upload: product missing -> 404 and ZERO Storage saves (F3) | handlers / logic tests |
| F08 | upload: cap reached -> 409 and ZERO Storage saves (F3) | handlers / logic tests |
| F09 | upload: same requestId replay -> idempotent, no extra object | handlers / logic tests |
| F10 | upload: product deleted after preflight -> txn 404 (pins the documented orphan limit) | handlers / logic tests |
| F11 | upload drain: 5 aged markers -> exactly 3 swept, response only after sweeps | handlers / logic tests |
| F12 | upload drain failure does not fail the upload (200) | handlers / logic tests |
| F13 | upload drain logs one line with the count | handlers / logic tests |
| F14 | deletePhoto: staff/manager -> 403, zero Storage deletes | handlers / logic tests |
| F15 | deletePhoto: owner happy path | handlers / logic tests |
| F16 | deletePhoto: invalid ids -> 400 | handlers / logic tests |
| F17 | deletePhoto: drain piggyback, failure isolated | handlers / logic tests |
| F18 | inventory delete: marker written in SAME txn (delete doc, audit, marker, one commit) | handlers / logic tests |
| F19 | inventory delete: marker prefix correct for dev and prod env, requestId, attempts 0 | handlers / logic tests |
| F20 | inventory delete: post-commit sweep deletes exactly the product prefix, marker removed | handlers / logic tests |
| F21 | inventory delete: sweep failure -> still 200, marker retained with lastError | handlers / logic tests |
| F22 | inventory delete: CAS 409 -> no marker, no sweep, zero Storage calls | handlers / logic tests |
| F23 | inventory delete: idempotent replay -> no second marker, no second sweep | handlers / logic tests |
| F24 | inventory update -> no marker | handlers / logic tests |
| F25 | stock_batch / order / staff delete -> no marker, no sweep | handlers / logic tests |
| F26 | inventory delete with unsafe entityId -> 400 invalid-entity-id, nothing written | handlers / logic tests |
| F27 | inventory delete of product with zero photos -> marker written, sweep harmless | handlers / logic tests |
| F28 | id reuse: recreate before drain -> drain drops marker, new product photos intact | handlers / logic tests |
| F29 | drain after delete: other aged markers swept, own excluded | handlers / logic tests |
| F30 | staff-role inventory delete behaves as today (no new gate; pin) | handlers / logic tests |
| F31 | batch with inventory delete -> 400, zero writes | handlers / logic tests |
| F32 | batch of valid creates + one inventory delete -> whole batch rejected, zero writes | handlers / logic tests |
| F33 | batch non-inventory delete still accepted | handlers / logic tests |
| F34 | ops with inventory delete -> 400 with opIndex, zero writes | handlers / logic tests |
| F35 | ops delta and non-inventory delete unaffected | handlers / logic tests |
| F36 | batch inventory create (import path) unaffected | handlers / logic tests |
| F37 | F5 pin, single path: stale before.photoIds -> 409 conflict | handlers / logic tests |
| F38 | F5 pin, batch path | handlers / logic tests |
| F39 | F5 pin, ops path | handlers / logic tests |

## 3. Rules tests (emulator, CI only) — 11 planned
`firestore.rules` + `storage.rules`. Status: planned, CI only.

| ID | Case | File |
|---|---|---|
| R01 | pending_cleanup: member read denied | rules test file |
| R02 | member create denied | rules test file |
| R03 | member update denied | rules test file |
| R04 | member delete denied | rules test file |
| R05 | owner denied all four | rules test file |
| R06 | unauthenticated denied | rules test file |
| R07 | member of another tenant denied | rules test file |
| R08 | PIN wildcard collections unchanged (member still reads inventory) | rules test file |
| R09 | PIN `locks` and `audit_log` still denied | rules test file |
| R10 | PIN storage.rules: public read allowed, client write denied | rules test file |
| R11 | forged marker attempt by a member leaves no marker behind | rules test file |

## 4. End-to-end (emulator: functions + Firestore + Storage, CI only) — 12 planned
Status: planned, CI only. Needs the Storage emulator hook for E05.

| ID | Case | File |
|---|---|---|
| E01 | owner: create product, upload, delete product -> Storage prefix empty, marker gone | `tests/e2e/` photo cascade file |
| E02 | staff token: upload 403 and deletePhoto 403, Storage untouched | `tests/e2e/` photo cascade file |
| E03 | admin token upload happy path | `tests/e2e/` photo cascade file |
| E04 | stale-before delete -> 409, photos and product both intact | `tests/e2e/` photo cascade file |
| E05 | injected sweep failure -> delete 200, marker present; next owner photo action drains it | `tests/e2e/` photo cascade file |
| E06 | recreate same productId before drain -> marker dropped, new photos intact | `tests/e2e/` photo cascade file |
| E07 | upload to a deleted product -> 404, zero objects | `tests/e2e/` photo cascade file |
| E08 | two products: delete A, B photos untouched (prefix-widening guard) | `tests/e2e/` photo cascade file |
| E09 | two tenants, same productId: delete in one leaves the other intact | `tests/e2e/` photo cascade file |
| E10 | batch inventory delete -> 400 end to end | `tests/e2e/` photo cascade file |
| E11 | photo cap reached -> 409, zero extra objects | `tests/e2e/` photo cascade file |
| E12 | MONKEY 30 random interleavings of create/upload/delete/recreate over 3 products; invariant: no Storage object belongs to a deleted product except the documented race | `tests/e2e/` photo cascade file |

## 5. Client QML (S4) — 25 planned, CI only (no Qt in the sandbox)
`tests/tst_PhotoQueueLogic.qml`, `tests/tst_StorageService*.qml`, `tests/tst_InventoryStore_deleteProductCascade.qml`, gallery test. Status: planned, CI only.

| ID | Case | File |
|---|---|---|
| C01 | classify 403 -> terminal | QML test files above |
| C02 | 400/404/409/413 still terminal (regression) | QML test files above |
| C03 | 500/502/503/0 still transient | QML test files above |
| C04 | reduceQueueItem failed 403 -> state failed on attempt 1, no backoff scheduled | QML test files above |
| C05 | failed 403 then retry() -> enqueued again (Retry UI works) | QML test files above |
| C06 | breaker still counts a 403 failure | QML test files above |
| C07 | _nextPhotoId matches `^photo-[A-Za-z0-9_-]{36}$` | QML test files above |
| C08 | _nextPhotoId strips braces when Qt.uuid is stubbed with braces | QML test files above |
| C09 | _nextPhotoId length <= 64 | QML test files above |
| C10 | 1000 ids all unique | QML test files above |
| C11 | id passes a mirror of the server whitelist regex (parity test) | QML test files above |
| C12 | MONKEY stubbed Qt.uuid uppercase/odd canonical forms -> still whitelist-safe | QML test files above |
| C13 | deleteProduct with 3 photoIds: zero removeProductPhoto calls | QML test files above |
| C14 | deleteProduct: only THIS product's queued photos discarded, others remain | QML test files above |
| C15 | deleteProduct: queue purge throws -> delete and batch cascade still complete | QML test files above |
| C16 | deleteProduct with no photoIds and empty queue -> no error | QML test files above |
| C17 | deleteProduct: no ImageProcessor.removeLocalCopy(productId) (legacy branch gone) | QML test files above |
| C18 | deleteProduct queues exactly one delete mutation with correct before | QML test files above |
| C19 | delete then 409 conflict -> row restored, removeProductPhoto never called | QML test files above |
| C20 | headless env, ImageProcessor undefined -> no throw | QML test files above |
| C21 | stock-batch cascade unaffected (existing cases still pass) | QML test files above |
| C22 | L1 (only if folded): breaker open -> timer armed once at cooldownUntil, not 250 ms | QML test files above |
| C23 | L1 (only if folded): after cooldown the queue drains | QML test files above |
| C24 | gallery remove fails with 403 -> removeFailed emitted with status text | QML test files above |
| C25 | gallery remove ok -> applyPhotoIds called with remaining ids | QML test files above |

## 6. Client QML (S5, legacy removal) — 12 planned, CI only

| ID | Case | File |
|---|---|---|
| S01 | normalize does not create photoUrl/photoUpdatedAt | `tst_InventoryStore_*`, import/export, dialog tests |
| S02 | doc already carrying photoUrl loads without error and the field is not propagated on save | `tst_InventoryStore_*`, import/export, dialog tests |
| S03 | clone and upsert payloads contain no photoUrl | `tst_InventoryStore_*`, import/export, dialog tests |
| S04 | import without a Photo URL column parses | `tst_InventoryStore_*`, import/export, dialog tests |
| S05 | import with a stale Photo URL column ignores it without error | `tst_InventoryStore_*`, import/export, dialog tests |
| S06 | export has no Photo URL column; later columns aligned (or blank, per S5 decision): pin | `tst_InventoryStore_*`, import/export, dialog tests |
| S07 | EditProductDialog has no 'Upload this photo' control | `tst_InventoryStore_*`, import/export, dialog tests |
| S08 | InventoryPage card shows placeholder when no photoIds | `tst_InventoryStore_*`, import/export, dialog tests |
| S09 | REGRESSION profile photoUrl still saved and loaded (AuthStore/AuthService) | `tst_InventoryStore_*`, import/export, dialog tests |
| S10 | guard test: no `photoUrl` token in InventoryStore, EditProductDialog, InventoryPage, ImportPreviewDialog | `tst_InventoryStore_*`, import/export, dialog tests |
| S11 | setPhoto removed, no callers | `tst_InventoryStore_*`, import/export, dialog tests |
| S12 | C++ XlsxService builds on CI | `tst_InventoryStore_*`, import/export, dialog tests |

## 7. Regression coverage (why these exist)
Defects this work pins, by case id: F22, E04, C19 (destroy-before-ack) | F37-F39 (F5 pin) | R01-R05, R11 (rules wildcard trap) | U15, U45, E08, E09 (prefix widening) | F07, F08 (F3 orphans) | C01, C05 (403 retry loop) | S09 (profile photo).

## 8. Mutation checks to run in the sandbox for S3 (Node side, planned)
Remove role gate; skip preflight; write marker outside the txn; write marker on CAS conflict; sweep without the product-absent re-check; drop the `/` suffix guard; widen whitelist to allow `/`; drain without the age filter; drain limit 4; batch/ops reject removed. Each must turn at least one case red.

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
- [ ] Delete fails with a conflict (edit the product on device B first): photos on device A's product are still visible afterwards (destroy-before-ack fixed).
- [ ] Product with 5 photos deleted: all 10 objects (main + thumb) gone.

### Multiple scenarios
- [ ] Two devices deleting two different products at once.
- [ ] Delete on A while B is mid-upload to the same product.
- [ ] Owner on A, admin on B, both uploading to different products.

### Monkey Testing
- [ ] 10 rapid add-photo / delete-product / recreate cycles across 3 products; no crash, no broken tile, Storage console shows no prefix of a deleted product.
- [ ] Kill the app right after tapping delete (before the toast): relaunch, the outbox finishes the delete; later do any photo action; the marker is gone.
- [ ] Toggle airplane mode mid-upload: app disables itself; on reconnect the queue resumes or fails cleanly.
- [ ] Spam the remove-photo button; rotate the device during a delete.

### Affected Areas (regression)
| Area | Automated | On-device check |
|---|---|---|
| `uploadProductPhoto`, `deleteProductPhoto` | sections 1, 2, 4 | upload/remove as owner |
| `recordMutation` inventory delete | sections 2, 4 | delete product |
| `recordMutationsBatch` (import) | F31-F36 | import a spreadsheet of products |
| `recordOperation` | F34, F35 | complete an order (ops path must still work) |
| `firestore.rules` wildcard | section 3 | normal inventory edit still works |
| `PhotoQueueLogic`, `PhotoQueue` | section 5 | failed-tile Retry/Discard |
| `InventoryStore.deleteProduct` | section 5 | delete product with batches |
| S5: edit dialog, inventory card, import/export | section 6 | open edit dialog, export, import |
| Profile photo | S09 | change profile photo |

### Regression Tests (manual counterpart)
- [ ] Delete a product: stock batches also disappear (older cascade).
- [ ] Order reopen/reversal does not resurrect a deleted batch.
- [ ] Bulk import still creates products.

### DV: device verification gap to close
- [ ] Confirm on the real Storage plan (not the emulator) that the prefix sweep removes objects.
- [ ] Read Cloud Functions logs: one drained-count line per photo/delete call; no sweep error for a normal delete.
- [ ] Check no `pending_cleanup` doc is older than a few minutes after normal use.

### Known unknowns
`Qt.uuid()` in headless `qmltestrunner`; whether the inventory 409 shows a toast; whether dropping export column 11 shifts later columns; how Storage emulator can be made to fail a delete (E05).
