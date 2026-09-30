# Test plan — Product photos in Firebase Storage

**Branch/feature:** `feature/2026-09-21-product-photos-firebase-storage` (PR #84)
**Design:** `docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md`
**Later rounds (2026-09-28 → 09-29):** folded into the "Follow-up rounds" and "On-Device Test Plan" sections below (former separate addendum plans deleted; see git history of PR #84).

This plan is explicit, per test, about which of two very different claims it's making: **"run for
real, in this session, and passed"** (a number you can trust right now), or **"written, and will be
proven by CI or a device"** (correct by construction and by review, unverified by execution in this
session). Conflating the two is the single most common way a test plan overstates coverage — see
`SKILLS.md` Skill 40/67/68 for why this project is careful about the distinction specifically for
anything touching a native context property, a real network call, or the Firebase emulator, none of
which are available in the sandbox that wrote this feature.

## 1. Unit test coverage — run for real in this session

| File | Cases | Result |
|---|---|---|
| `functions/lib/photoValidation.js` + `functions/test/photoValidation.test.js` | JPEG magic-byte + size-ceiling validation; `isSafePathSegment` (path-traversal rejection, added during review) | 12/12 |
| `qml/helper/PhotoUrl.js` (Node mirror: `functions/test/testSupport/photoUrlParity.js`) + `functions/test/photoUrl.parity.test.js` | Download-URL construction, thumb suffix, %2F encoding, env separation, missing-field errors | 5/5 |
| `qml/helper/PhotoQueueLogic.js` (Node mirror: `functions/test/testSupport/photoQueueLogicParity.js`) + `functions/test/photoQueueLogic.parity.test.js` | Error classification, backoff schedule, queue-item reducer (incl. the stale-failure-event guard found by the monkey test), circuit breaker (incl. cooldown escalation/reset), 2 monkey tests (500 runs each) | 23/23, stable across 5 consecutive runs |
| `functions/index.js` `uploadProductPhoto`/`deleteProductPhoto` + `functions/test/index.handlers.photos.test.js` (extends `testSupport/handlerHarness.js` with a Storage mock) | Happy path, idempotent replay, invalid/oversized image, product-not-found, photo-limit, auth failures, path-traversal rejection (both handlers), delete no-op-on-absent-id, delete tolerates a missing product doc, delete Storage cleanup skipped on replay, a photoIds-list-invariant monkey test | 22/22 |
| Full `functions/` suite (everything above plus every pre-existing test in the repo, including the parallel `recordOperation` work merged in via this branch's two rebases) | — | **296/296, stable across 3 consecutive runs**, confirmed after each of the two rebases onto `main` |

`npm ci` inside `functions/` was required once per session to make these runnable — confirmed this
session (not assumed from prior sessions' notes) that the Firebase emulator itself (Firestore
**and** Storage) cannot start in this sandbox: `firebase emulators:exec` fails downloading the
emulator jar because `storage.googleapis.com` is not in the sandbox's network egress allowlist.

## 2. Functional / QML test coverage — written, NOT run in this session (no `qmltestrunner`
toolchain in this sandbox); CI is the first real execution

| File | Cases | Covers |
|---|---|---|
| `tests/tst_PhotoUrl.qml` | 6 | QML-side mirror of the Node `PhotoUrl.js` parity tests — proves the actual `.pragma library` file loads and agrees |
| `tests/tst_PhotoQueueLogic.qml` | 23 (incl. 2 monkey tests, deterministic LCG seed for reproducibility) | QML-side mirror of `PhotoQueueLogic.js`'s parity tests |
| `tests/tst_OutboxStore.qml` (8 new cases) | `hasPendingForEntity`: fresh enqueue, sent, unrelated id, unrelated entity, in-flight, inside a batch item, inside a delta item, empty queue | The Trap 1 gate (an offline-created product's photo waits for that product's own create mutation) |
| `tests/tst_PhotoQueue.qml` | 21 (persistence-across-relaunch, discard, retry, `drainCandidates()`'s full gating matrix — due time, in-flight, wrong identity resuming on sign-in, Trap 1 blocking and resuming, a mixed queue, plus 2 regression tests added during the review sweep for the `_load()`→`_reschedule()` and `drainNow()`→`ensureFreshToken()` bugs) | `PhotoQueue.qml`'s queue-management logic — **explicitly does NOT cover `_upload()`** (native file read + real XHR); see the file's own TESTABILITY NOTE |
| `tests/tst_EnvConfig.qml` (1 new test, 3 assertion cases) | `storagePrefixForEnv`: prd, test, the dev→dev1 quirk | The client-side Storage-path env mapping |
| `tests/tst_InventoryStore_deleteProductCascade.qml` (2 new cases, 1 existing comment corrected) | Multi-photoIds cascade loop; legacy-photoUrl-only fallback | `deleteProduct`'s photo-cleanup cascade |

**Not covered by any automated test, anywhere in this repository, and not coverable without a real
Qt/device build**: `StorageService.addProductPhoto`'s native steps (`NativeFile.toReadablePath`,
`ImageProcessor.compressForUpload`/`persistLocalCopy`), `PhotoQueue._upload`'s
`NativeFile.readFileBase64` + real XHR round-trip, `NativeFile::readFileBase64` itself (C++, no Qt
toolchain in this sandbox), and every visual/interaction behavior of
`qml/components/ProductPhotoGallery.qml` (it `import`s `Felgo`, so it cannot load under the "QML
Tests" CI job at all — see `AGENTS.md`'s Testing & QA Agent section). This is not a gap specific to
this feature; it's the same wall `StorageService.qml`'s old code and `Gateway._send`'s real XHR call
have always been on the far side of in this codebase (`SKILLS.md` Skill 58/68) — the On-Device
section below is where this gets exercised.

## 3. Firestore + Storage rules test coverage — written, NOT run in this session (emulator
unavailable here, confirmed by a failed download, not assumed)

| File | Cases |
|---|---|
| `test/storage.rules.test.js` | Unauthenticated read succeeds; authenticated-owner read succeeds (read is unconditional); unauthenticated write denied; authenticated-owner write denied; delete denied; an unmapped path denies both, for anyone; an explicit case documenting there is no per-tenant check at all (access is by path shape only, per design decision Q2) |

## 4. End-to-end test coverage — written, NOT run in this session (no network egress to the
Firebase emulator distribution)

`test/e2e/tst_ProductPhotosE2E.qml`, 7 cases, against the real Firebase Local Emulator Suite
(Firestore + Auth + Functions + Storage): upload happy path (verifies Firestore `photoIds` **and**
both Storage objects independently, via raw REST polls against each emulator, not the client's own
cache), idempotent replay, invalid-image rejection, the path-traversal fix (proves the real deployed
function rejects it, not just the mocked unit tests), the 10-photo limit, delete happy path
(Firestore emptied + both Storage objects actually gone), and tolerating a delete of an
already-absent id. Deliberately bypasses `StorageService`/`PhotoQueue` with raw POSTs to the
emulated functions — same established pattern as `tst_InventoryE2E.qml`'s own `recordMutation`
diagnostic — because the real client path needs native context properties this sandbox doesn't
have. Two new `E2EHelpers.js` functions (`pollEmulatorStorageObject`/`pollEmulatorStorageObjectAbsent`)
added, mirroring `pollEmulatorDoc`'s exact structure against the Storage emulator's REST API.

## What was genuinely run

Everything in section 1 (unit tests) — the entire `functions/` suite, 296/296, stable across 3
consecutive runs, confirmed independently after each of this session's two rebases onto `main`.
Nothing in sections 2, 3, or 4 has executed anywhere yet. CI (`.github/workflows/checks.yml` — the
Storage emulator was added to both the rules-tests job and the e2e-tests job during this feature) is
the first real execution for all of it. If CI's first run on this branch disagrees with anything
written here, CI is right and this plan is wrong until updated.

## Review sweep (2026-09-25) — four bugs found after the tests above were already written and
passing, none caught by them

Running `requesting-code-review`/`ponytail-review`/`qt-development-skills:qt-qml-review` against
the full diff (done by hand — no subagent-dispatch tool in this environment) found: (1)
`PhotoQueue.clear()` never wired into sign-out; (2) `productId`/`photoId` unvalidated before use in
a Firestore path *and* a new Storage object path (real path-traversal surface, fixed with
`isSafePathSegment`, now covered by 8 new unit tests plus one e2e test); (3) `PhotoQueue` never
actually calling `AuthService.ensureFreshToken()` despite the design saying it would; (4)
`PhotoQueue._load()` never calling `_reschedule()`, silently breaking "survive app close" — the most
serious of the four. All four are now fixed and covered (see sections 1–2 above for exactly which
new test proves which fix). The lesson generalizes past this feature: a function's own unit test
proves it behaves correctly in isolation, not that anything actually calls it — see `SKILLS.md`
Skill 74's review-sweep addendum.

## Follow-up rounds (PR #84 device testing, 2026-09-28 → 09-29)

Nothing here was run in the sandbox except where stated (no Qt toolchain; CI is the proof).
`ProductPhotoGallery.qml`, `RoundedThumb.qml`, `FailedTileOverlay.qml`, `EditProductDialog.qml`,
`AvatarBadge.qml` import Felgo and cannot load under `qmltestrunner`; rendering and gestures are
on-device only. Coverage is therefore NOT 100% for those files; the pure logic they use is covered.

| Round | Symptom (owner, on device) | Root cause | Fix / automated proof |
|---|---|---|---|
| 1 | Nothing ever uploaded | `persistLocalCopy` returns `file://`; gallery re-prefixed it; `_upload` read it as a bare path -> "file gone" -> terminal 400 | Idempotent `PhotoUrl.toLocalPath/toFileUrl`. `tst_PhotoUrl.qml`, Node parity 19/19 (run) |
| 1 | Spinner forever on offline-created product | Drain never re-armed when the product's outbox create landed | `_outboxWatcher` re-arms. `tst_PhotoQueue.qml` |
| 2 | "Cover" on every tile | Delegate with `required property` loses implicit `index` | `required property int index`; later replaced by precomputed `isCover` in `_combined`. `tst_PhotoGalleryLayout.qml` |
| 2 | New photo not shown in open dialog | `photoIds` snapshot copied in `openFor()` | `Connections` on `InventoryStore.revisionChanged` -> `photoIdsFor()`. `tst_InventoryStore_photoIds.qml` |
| 2-5 | No cover/thumbnail in Inventory list | Round 2: unproven, diagnostics added. Later commits: list card wiring (`InventoryPage`) and the `MultiEffect` source problem (round 5 row) | `Image.Error` logs in `AvatarBadge`/gallery; no automated test (Felgo import) |
| 3 | Photos overran rounded corners; arrangement "boxy" | `clip:true` clips to bounding box, not `radius` | `RoundedThumb.qml` (`MultiEffect` mask); `Flow` -> horizontal `ListView` filmstrip, `+` tile pinned outside scroll region |
| 5 | No photo rendered at all (round-3 regression) | `visible:false` source/mask gives `MultiEffect` nothing to sample | `layer.enabled: true` on both (SKILLS.md Skill 80). Monkey-test flake fixed (`_settle()`) |
| 6 | Failed tile widened to 160dp and grew the row; 9px buttons | Old text-button row below tile | In-tile `FailedTileOverlay` over a 72dp tile. `tst_FailedTileGeometry.qml` (22), layout tests flipped to "footprint unchanged" |

Rules / functions / e2e: unchanged by rounds 2-6. Regression set that must stay green: `tst_PhotoQueue`,
`tst_PhotoQueueLogic`, `tst_PhotoUrl`, `tst_InventoryStore_photoIds`, `tst_OutboxStore`,
`test/e2e/tst_ProductPhotosE2E.qml`, `functions/` Node suite.

## Final-sweep findings (2026-09-29, PR #84 review)

Each is a real gap found by reading the code. Status column is updated as they are fixed; tests are
written but NOT run here (no Qt toolchain), CI is the proof.

| # | Gap | Test | Status |
|---|---|---|---|
| F1 | Item persisted as `uploading` (app killed/OS-suspended mid-upload) is never drained or re-armed on relaunch; no Retry/Discard because state is not `failed` | `tst_PhotoQueue`: `_load()` with a persisted `uploading` item -> becomes `enqueued` and is a drain candidate | FIXED: `tst_PhotoQueue` `test_relaunch_recovers_*`, `..._leaves_failed_and_retrying_*`, `..._only_the_uploading_items_of_a_mixed_queue`, `..._corrupt_storage_*`, `test_an_in_session_uploading_item_is_still_excluded_*` |
| F2 | Deleting a product does not purge its queued/failed photos; they later 404 (terminal) and stay in the queue with no UI to discard | `tst_InventoryStore_deleteProductCascade`: queued items for the product are discarded (files removed) | FIXED: `tst_InventoryStore_deleteProductCascade` `test_deleteProduct_discards_*` (queued, every state, with cascade, none, unknown id, empty queue, monkey) |
| F3 | `uploadProductPhoto` writes Storage objects before the 404/409 checks, so those outcomes orphan both objects | `index.handlers.photos.test.js`: 404 and 409 paths write nothing (or delete what they wrote) | open |
| F4 | `idToken`-empty branch in `_upload` returns without re-arming the drain | `tst_PhotoQueue`: token-empty pass leaves item drainable on next trigger | FIXED as a token watcher: `tst_PhotoQueue` `test_token_arrival_*` (drains, respects outbox gate, respects identity, empty queue), `test_token_cleared_does_not_drain` |
| F5 | Full-doc inventory `update` carries `before.photoIds`; a photo confirmed between edit and drain makes the edit 409 | Server test: `applyMutation` ignores/preserves `photoIds` in the `before` comparison | open |

## On-Device Test Plan (current behaviour, replaces the per-round checklists)

Deploy `storage.rules` and both functions (`uploadProductPhoto`, `deleteProductPhoto`) first. Needs a real
Felgo build on Android or iOS.

### Happy Path
- [ ] New product, "+" tile, take a photo: spinner tile immediately; photo becomes the cover on completion; log has no `Cannot open: file://` / `file://file`.
- [ ] Second photo from library: both show; exactly ONE tile has the cover star (first tile, top-left); rounded corners on every tile with no square corner past the frame; a real photo renders (not grey).
- [ ] Dialog stays open while a photo finishes: queued tile is replaced in place by the confirmed thumbnail, no reopen.
- [ ] Filmstrip scrolls horizontally past ~4-5 tiles; nothing wraps; "+" tile visible without scrolling at 0-9 photos and gone at 10.
- [ ] Inventory list: product with photos shows its first photo as the avatar.
- [ ] Second device, same account: both photos appear. Remove one via (x): gone on both after refresh; if it was the cover, the next tile takes the star.
- [ ] Force-close right after picking a photo, reopen: it resumes and completes. Repeat killing the app ~3 s later (mid-upload) (F1, fixed 2026-09-29).

### Negative Cases
- [ ] Airplane mode + add photo: stays queued with spinner (no error), uploads on reconnect, resolves in place.
- [ ] Upload gives up (block function URL / bad token / kill network mid-upload): tile stays 72dp, red 2px border, dark scrim, gradient Retry circle, small frosted x top-right; neighbours and strip height do not move.
- [ ] Retry while online: press shrinks the circle, tile flips to spinner, then normal tile. Retry while offline: back to spinner, eventually failed again. Items `failed` from the old build (URL-form paths) succeed on Retry.
- [ ] Discard on a failed tile: removal animation, local file gone, does not return on relaunch, no gap.
- [ ] 11th photo: clear failure; delete another photo; Retry succeeds.
- [ ] TalkBack: controls announce as buttons "Retry upload" / "Discard photo".

### Edge Cases
- [ ] Product created offline + photo added, then online: photo waits for the product, then uploads (no restart needed).
- [ ] Sign out with a photo pending, sign in as another user: pending photo neither shows nor uploads.
- [ ] Legacy `photoUrl` product: list still shows it; "Sync old photo to the cloud" works; photo stays visible during migration.
- [ ] Read-only role: no x buttons, no "+" tile, strip still scrolls.
- [ ] Bright and dark photos: Retry ring and x readable. Large system font / small phone: targets tappable, no overlap. Two or three failed tiles in one strip: not confused.
- [ ] Windows profile path containing a space (desktop build).
- [ ] **Delete a product while it has a queued/failed photo** (F2): expect no zombie failed item and no leftover local file. Known ceiling: an upload already in flight can still land server-side (Storage orphan until roadmap item 4).
- [ ] Cold start with an expired session and a photo queued from last run (F4): once sign-in/refresh completes the photo uploads without any other action.

### Affected Areas (regression)
- [ ] Product create/edit/delete unrelated to photos unchanged; deleting a product with photos removes both Storage objects (check console).
- [ ] List cards render for zero photos, one legacy photo, and multiple new-style photos side by side.
- [ ] Sign-out still clears Gateway writes and locks, plus `PhotoQueue.clear()`.
- [ ] Price/stock edit while a photo is uploading does not raise a spurious conflict (F5).

### Monkey Testing
- [ ] Mash add / remove / Retry / Discard on a 6-photo product: no crash, no duplicate tile, no stuck spinner, no leftover overlay.
- [ ] Add 3 photos quickly with the dialog open: all appear in order, no duplicates. Open product A, add photo, close, open B at once: B never shows A's photos.
- [ ] Toggle airplane mode repeatedly with photos queued on several products: all eventually upload, none lost or duplicated.
- [ ] Background the app for several minutes mid-upload, foreground: completed or cleanly in progress (F1).
- [ ] Scroll the strip while a photo uploads: spinner keeps running, no reset.

### Known unknowns
- Upload path through the real Cloud Function is proven only by on-device runs; a 4xx/5xx now is server-side (`photoValidation`, size, auth) - bring the log line.
- `qt.network.http2: GOAWAY` is connection-level noise; status 0 is retried by design.

## PR #99 review additions (2026-09-30)

Written, NOT run (no Qt toolchain); CI is the proof.

| # | Finding | Coverage |
|---|---|---|
| R1 | Queue purge in `deleteProduct` shared one try/catch with confirmed-photo removal: a throw in `discard()` skipped Storage removals | Isolated in its own try/catch (`InventoryStore.qml`); no headless test can make `discard()` throw, so on-device check below |
| R2 | Monkey test never left state `enqueued` (LCG overflow) | Fixed LCG + asserts every state and both groups are reached (`test_deleteProduct_queue_purge_monkey`) |
| R3 | `PhotoQueue._breaker` shared across test files could trip open and starve the F4 drain test | Reset in `tst_PhotoQueue.init()` |
| R4 | Late upload confirmation for a deleted product | `test_late_upload_confirmation_for_a_deleted_product_is_a_noop` |
| R5 | Token watcher fired a redundant token refresh (stale expiry mid-`applyAuth`) | `drainNow(true)` from watcher. Not unit-testable (`ensureFreshToken` no-ops when unauthenticated); on-device check below |

On-device additions:
- [ ] Cold start, expired session, one queued photo: exactly ONE refresh request is made (log shows one `tokenRefreshed`), photo then uploads.
- [ ] Delete a product that has a queued photo AND confirmed photos while offline, go online: confirmed photos are removed from Storage, no zombie queue item, no crash.
- [ ] Hourly token refresh with a `failed` photo sitting in the gallery: no extra refresh, no state change, Retry still works.


## PR #99 sweep 2 additions (2026-09-30)

Written, NOT run (no Qt toolchain); CI is the proof. Counts re-verified with `git diff | grep -c` (`tst_PhotoQueue` +4 this pass = 38 total; `tst_InventoryStore_deleteProductCascade` has 8 added by PR #99, 16 total).

| Layer | Covered | Test |
|---|---|---|
| Unit | token arrival while the breaker is open sends nothing | `test_token_arrival_respects_an_open_circuit_breaker` |
| Unit / regression | hourly token refresh never revives a `failed` item | `test_hourly_token_refresh_leaves_a_failed_item_untouched` |
| Unit | token arrival respects `retrying` backoff | `test_token_arrival_respects_a_retrying_items_backoff` |
| Monkey | 60 random token set/clear events over a mixed queue: nothing lost, failed/in-flight/backed-off/other-identity items never move, eligible item drained | `test_token_churn_monkey_never_loses_or_revives_items` |
| Rules / functional | server-side dedupe returns current `photoIds` (already covered, `index.handlers.photos.test.js`) | n/a, verified by reading |
| E2E | not possible for F1/F2/F4: client-only, `NativeFile`/`ImageProcessor` are undefined under qmltestrunner | device checklist below |

Device (happy, negative, edge, multi-scenario, monkey):
- [ ] Happy: add a photo online, spinner then thumbnail, no duplicate ledger "photo added" row.
- [ ] F1 negative: airplane mode, add photo, force-close, relaunch offline: tile shows waiting spinner (not stuck), go online: uploads, one ledger row.
- [ ] F1 edge: force-close ~3 s into a real upload (mid-XHR), relaunch online: photo appears exactly once (server dedupe), no 409, photo count not doubled.
- [ ] F1 multi: 3 photos queued offline, kill app, relaunch online: all three upload, cap of 10 still enforced.
- [ ] F2 negative: delete a product with one queued, one failed and one confirmed photo: no zombie tile anywhere, no leftover local file, confirmed photo removed from Storage.
- [ ] F2 edge: delete the product while a photo is mid-upload: no crash, no error dialog (a Storage orphan is the known ceiling).
- [ ] F4 edge: cold start with an expired session and a queued photo: exactly one token refresh, photo uploads without any other action.
- [ ] F4 negative: sign out with a queued photo, sign in as another user: nothing uploads under the new account, queue empty.
- [ ] Monkey: 60 s of rapid airplane-mode toggling, add/discard/retry photos, background/foreground the app: no stuck spinner, no crash, tile count matches queue.
