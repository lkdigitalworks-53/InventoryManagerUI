# Test plan — Product photos in Firebase Storage

**Branch/feature:** `feature/2026-09-21-product-photos-firebase-storage` (PR #84)
**Design:** `docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md`
**Plan:** `docs/superpowers/plans/2026-09-21-product-photos-firebase-storage.md`

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

## On-Device Test Plan

Everything below needs a real Qt/Felgo build on Android or iOS, or a desktop build with a camera/
gallery available. Deploy `storage.rules` and both Cloud Functions (`uploadProductPhoto`,
`deleteProductPhoto`) first — none of this works against production until that happens.

### Happy Path

- [ ] Add a new product, open it, tap the "+" tile in the photo gallery, take a photo with the
      camera. Confirm a spinner shows on the new tile immediately (before any network activity is
      visible) and the photo appears as the cover once upload completes.
- [ ] Add a second photo to the same product from the gallery/library picker. Confirm both photos
      show, first one still marked "Cover".
- [ ] On a **second device** (or the same account in a second app instance/emulator), open the same
      product. Confirm both photos appear — this is the actual "sync across every device" check;
      nothing above it proves this without a second device.
- [ ] Remove one photo via its (×) button. Confirm it disappears from both devices after a refresh.
- [ ] Force-close the app immediately after taking a photo (before the spinner clears). Reopen.
      Confirm the photo resumes uploading and completes — this is the "survive app close" check for
      the exact bug this feature's review sweep found and fixed
      (`PhotoQueue._load()`/`_reschedule()`).

### Negative Cases

- [ ] Turn on airplane mode, add a photo. Confirm it stays queued with a spinner (not an error) and
      uploads automatically once airplane mode turns off — no manual retry needed.
- [ ] Attempt to add an 11th photo to a product that already has 10. Confirm a clear error, not a
      crash or a silently-dropped photo.
- [ ] Kill the network mid-upload (not before starting it). Confirm the item moves to a visible
      Retry/Discard state after enough failed attempts, rather than spinning forever.
- [ ] Tap Discard on a failed item. Confirm it disappears and does not reappear on relaunch.
- [ ] Tap Retry on a failed item. Confirm it re-attempts and can still succeed.

### Edge Cases

- [ ] Add a photo to a product that was itself just created while offline (both offline). Confirm
      the photo waits until the product sync lands, then uploads — this is Trap 1 from the design
      spec; the automated tests only prove the *gating logic*, not the real timing.
- [ ] Sign out with a photo still uploading, sign in as a different user on the same device. Confirm
      the pending photo does **not** appear or upload under the new account (the sign-out
      `PhotoQueue.clear()` wiring this review sweep added).
- [ ] Open a product with a legacy (pre-feature) single photo. Confirm the "Sync old photo to the
      cloud" affordance appears and works, and the legacy photo remains visible (via the local file)
      while the migration upload is in flight.
- [ ] Very poor/flaky connection (throttled, not fully offline): confirm the circuit breaker doesn't
      make the UI feel stuck — a failed attempt should still show progress (spinner→retry state),
      not silence.

### Affected Areas (regression — confirm nothing else broke)

- [ ] Product create/edit/delete flows unrelated to photos still work normally (name, price, stock,
      supplier fields).
- [ ] Deleting a product with several photos removes them from Storage (check the Firebase console
      or re-add a product with the same SKU and confirm no leftover images appear).
- [ ] The inventory list's product cards still render correctly for products with zero photos, one
      legacy photo, and multiple new-style photos, side by side.
- [ ] Sign-out/sign-in still clears pending Gateway writes and locks as before (`Gateway.clear()`,
      `LockManager.clear()`) — the new `PhotoQueue.clear()` call was added alongside them, not in
      place of them.

### Monkey Testing

- [ ] Rapidly tap add-photo → discard → add-photo → retry in quick succession on the same product.
      Confirm the queue never ends up with duplicate entries for the same photo and the UI never
      shows a stuck or contradictory state (e.g., a tile that's simultaneously "uploading" and
      showing a Retry button).
- [ ] Toggle airplane mode on and off repeatedly while multiple photos are queued for different
      products. Confirm all of them eventually upload, in no particular guaranteed order, with none
      lost or duplicated.
- [ ] Background the app (don't force-close) for several minutes with a photo mid-upload, then
      foreground it. Confirm it either completed or is still cleanly in progress, not stuck.
