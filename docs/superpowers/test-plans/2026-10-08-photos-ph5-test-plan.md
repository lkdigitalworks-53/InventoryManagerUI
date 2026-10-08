# Test plan — photos PH5 (remove legacy product `photoUrl` / `photoUpdatedAt`)

**Branch (planned):** `feat/2026-10-08-photos-ph5-legacy-removal`. **Design:** `docs/superpowers/specs/2026-10-08-photos-ph5-legacy-removal-design.md` (decisions Q-P5-1..6 OPEN; this plan assumes the recommended defaults: A remove column, B import warning, a fresh tenants only, B edit `_mergeRecord`, A Node guards).
**Supersedes section 6 of** `2026-09-30-photos-s3-s4-s5-test-plan.md` (its S-ids are mapped below; "decide at PH5" is decided here).
**Written before implementation. NOTHING here has been run.** Design session: no code, no Qt toolchain (standing rule), Node suite not run. Every status is `planned`; the implementation PR replaces it with the CI result. Counts were counted by hand from the lists below (not generated): recount at implementation.
**Environment:** dev only, new tenant per PR, no offline operation, no legacy product `photoUrl`.
**Coverage bar (Taher):** 100% of new/changed code; happy + negative + edge + multi-scenario + monkey. Node cases run in the sandbox (`cd functions && npm ci && node --test`); QML, e2e, C++ build are CI-only. `test/felgo-dependent/*` is NOT run by CI (`checks.yml` runs `qmltestrunner -input tests`), so nothing that needs the dialog or page rendered can be an automated case: those are device cases.

**Totals (planned):** Node 12 (guards 11, server pin 1) + QML 14 (import helper 7, store 7) + e2e 3 + CI C++ build 1 = **30 automated**, plus the device plan.

## 1. Node source guards + server pin (`functions/test/ph5LegacyPhotoUrl.guard.test.js`, `gatewayLogic.test.js`) — 12 planned
Scanner rule: case-SENSITIVE `\bphotoUrl\b` or `photoUpdatedAt` anywhere in the file, comments included. The module alias `PhotoUrl` (capital P, `import ".../PhotoUrl.js" as PhotoUrl`) is allowed.
| ID | Case | Maps old |
|---|---|---|
| G01 | `qml/model/InventoryStore.qml` has no legacy token | S10 |
| G02 | `qml/pages/EditProductDialog.qml` has no legacy token and no "Upload this photo" / `clearLegacyPhotoUrl` | S07, S10 |
| G03 | `qml/pages/InventoryPage.qml` has no legacy token | S08, S10 |
| G04 | `qml/pages/ImportPreviewDialog.qml` has no legacy token (warning helper lives in `ImportMath.js`) | S10 |
| G05 | `qml/model/StorageService.qml` comments no longer describe a single `photoUrl` string | S10 |
| G06 | `XlsxService.cpp` `kProductHeaders` has exactly 14 entries and no "Photo URL" | S06 |
| G07 | `writeProductsSheet` has exactly 14 `doc.write(row, N, ...)` calls, N contiguous 1..14 | S06 |
| G08 | `writeProductsSheet` has exactly 14 `setColumnWidth(N, ...)` calls, N contiguous 1..14 | S06 |
| G09 | product template ("Notes" sheet) lists exactly 14 columns and no "Photo URL" row | S06 |
| G10 | REGRESSION positive control: `AuthStore.qml` and `AuthService.qml` still contain `photoUrl` (profile photo untouched) | S09 |
| G11 | MONKEY / guard self-test: the scanner flags `photoUrl`, `p.photoUrl \|\| ""`, `photoUrl:`, `"photoUrl"`, `photoUpdatedAt`, with CRLF, tabs, inside `//` and `/* */`; ignores `PhotoUrl.` alias; flags nothing in an empty string | — |
| F42 | SERVER PIN (Q-P5-3 a): `applyMutation` with `before` lacking `photoUrl`/`photoUpdatedAt` vs a stored doc that has them returns 409 and writes nothing; with both sides lacking them it commits | new |
Mutation checks to run in the sandbox: re-add one `doc.write` without a header (G07 must fail); re-add one comment containing `photoUrl` (G01/G05 must fail); delete `photoUrl` from `AuthStore.qml` (G10 must fail); change F42 so `_deepEqual` ignores the two keys (F42 must fail).

## 2. QML client (CI only, `tests/`) — 14 planned
### 2a. Import warning helper (`tests/tst_ImportMath.qml`) — 7
| ID | Case | Maps old |
|---|---|---|
| H01 | `hasLegacyPhotoColumn([])` is false | S04 |
| H02 | rows without a "Photo URL" key: false (import without the column parses) | S04 |
| H03 | column present, every cell empty string / undefined: false | S05 |
| H04 | column present, one non-empty cell: true | S05 |
| H05 | column present, only whitespace cells: false | S05 |
| H06 | NEGATIVE: `null`, `undefined`, a string, a number as input: false, no throw | — |
| H07 | EDGE: header text must match exactly ("photo url", "PHOTO URL" give false, pins the importer's exact-match behaviour) | — |
### 2b. Store (`tests/tst_InventoryStore_photoIds.qml`, `tests/tst_InventoryStore_deleteProductCascade.qml`) — 7
| ID | Case | Maps old |
|---|---|---|
| S01 | normalize does not create `photoUrl` / `photoUpdatedAt` | S01 |
| S02 | a loaded doc that carries both keys loads without error and `_clone()` output has neither key | S02 |
| S03 | default product, `_clone` and new-record payloads contain neither key | S03 |
| S11 | `InventoryStore.setPhoto` and `clearLegacyPhotoUrl` are undefined | S11 |
| S13 | `upsertMany` new row from a record carrying `photoUrl: "http://x"`: stored doc has no `photoUrl`, no throw, counts correct | new |
| S14 | REGRESSION: `upsertMany` overwrite still updates name/price/stock and keeps `photoIds` | new |
| D1 | `deleteProduct` on a row carrying a stray `photoUrl` key still completes (replaces the legacy-photoUrl test at `deleteProductCascade.qml` L158) | — |

## 3. Rules — 0 planned
No `firestore.rules` / `storage.rules` change. Existing rules suite must stay green.

## 4. E2E, emulator (`test/e2e/`) — 3 planned
| ID | Case |
|---|---|
| E01 | HAPPY: create a product through the store/gateway on a fresh tenant; the Firestore doc has NO `photoUrl` / `photoUpdatedAt` key |
| E02 | HAPPY: update that product (price) then delete it: both succeed, no 409 (proves the removal does not break CAS on fresh docs) |
| E03 | NEGATIVE (pins Q-P5-3 a): seed a doc WITH `photoUrl: ""` and `photoUpdatedAt: ""` directly as emulator admin, then update it from the client: 409, doc unchanged. Dropped if the e2e harness cannot seed a raw product doc (then F42 is the only pin) |

## 5. CI build
S12: C++ `XlsxService` compiles on the CI build job (14 headers, shifted writes).

## 6. On-Device Test Plan (new tenant per PR; app disabled offline). Nothing ticked.
### Happy Path
- [ ] Create a product, add a photo: card avatar shows the photo; edit dialog shows the gallery and NO "Upload this photo" button.
- [ ] Product with no photo: card shows the letter badge (no broken image, no empty box).
- [ ] Export products: open the .xlsx: 14 columns, no "Photo URL", columns after "Min Stock" are Supplier, Size, Taxable, Tax % with correct values and widths.
- [ ] Import the file you just exported: all rows match, no warning.
### Negative Cases
- [ ] Import an OLD 15-column export (keep a copy from before PH5) whose Photo URL cells are filled: import succeeds, products created without photos, ONE warning mentions the ignored column (Q-P5-2 B).
- [ ] Import an old export whose Photo URL column is all empty: no warning.
- [ ] Import a file with a column called "photo" or "Image": ignored silently, as before.
- [ ] Open a tenant created BEFORE PH5 (expected broken, Q-P5-3 a): edit a product, expect a conflict toast every time. This is the documented limit, not a bug; verify the PR/KNOWN-ISSUES text says so.
### Edge Cases
- [ ] 120 products (more than 2 pages of 50): export has 120 rows and 14 columns.
- [ ] Template download ("Notes" sheet): product table has 14 rows, none for Photo URL.
- [ ] Profile page: change profile photo, relaunch: still saved (S09).
### Multiple scenarios
- [ ] Device A exports, device B imports it into a second fresh tenant.
- [ ] Owner on A edits a product while admin on B uploads a photo to it (accepted F5 409, unchanged).
### Monkey Testing
- [ ] Import the same file 5 times in a row with skip / overwrite / rename: no crash, counts consistent, no Photo URL anywhere.
- [ ] Open and close the edit dialog 20 times on a product with and without photos: no stale legacy control appears.

### Affected Areas (regression)
| Area | Automated | On-device check |
|---|---|---|
| Product export / template | G06-G09, S12 | export, open file |
| Product import | H01-H07, S13, S14 | import old and new files |
| `InventoryStore` clone / normalize / upsert | S01-S03, S11, S13, S14, E01, E02 | create, edit, delete product |
| `EditProductDialog` | G02 | open dialog |
| `InventoryPage` card | G03 | list with and without photos |
| `deleteProduct` | D1 | delete product |
| Profile photo | G10 | change profile photo |
| CAS on stored docs | F42, E03 | pre-PH5 tenant behaviour (expected broken) |

### Regression Tests (manual counterpart)
- [ ] Delete a product: batches and photos gone (older cascade).
- [ ] Bulk import still creates products with opening stock batches.
