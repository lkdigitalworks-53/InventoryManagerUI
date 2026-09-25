# CHECKPOINT — Product photos in Firebase Storage

**Branch:** `feature/2026-09-21-product-photos-firebase-storage`, PR #84, rebased onto `main` @
`2c1e5f6` (2026-09-22). **Commit identity:** `Taher (via Claude session) <lkdwtaher@gmail.com>`.

**A note on this file's own history:** an earlier version of this checkpoint, tracking progress
commit-by-commit, was lost during the `git rebase onto main` step -- `git rebase`'s `--ours`/
`--theirs` are inverted from a normal merge (`--ours` means "the branch being rebased onto", i.e.
main's unrelated checkpoint content, not this branch's own history), and that was used by mistake
to resolve every CHECKPOINT.md conflict during the rebase. The real code, tests, and docs commits
were unaffected (verified: `git log --oneline origin/main..HEAD` shows all 15 feature commits
intact with correct diffs; `functions/` test suite re-run clean, 288/288, after the rebase) -- only
this file's narrative was silently overwritten repeatedly. This is a rewritten, accurate version,
not a historical replay. If resuming and something here seems to skip detail, `git log` on this
branch is the ground truth for what actually happened, in far more detail than fits here.

## Original ask (2026-09-21, Taher)

Clone the repo, store product photos in Firebase Storage instead of a URL string on the product,
sync photos across every device (not limited to the uploading device), support multiple photos per
product for a future catalogue. Then: atomic upload+id-creation where possible, idempotency, retry,
circuit breaker, timeout, background upload with a spinner, survive app close and network glitches,
offline uploads queue and resume when online. Standing instructions: branch, never touch `main`
directly; push after every commit without asking; don't build/run the app; advise honestly and grill
before deciding, don't just agree; commit author email `lkdwtaher@gmail.com`; update skills/agents/
docs as needed; write tests aiming at full coverage plus a test plan; rely on CI, not local Qt/
emulator tooling, for anything this sandbox can't run.

## Decisions (approved by Taher, 2026-09-21)

- **Data model:** `photoIds: string[]` on the product doc (max 10, first = cover), not a URL. No
  stored download URL anywhere -- computed at display time from bucket/env/tenant/product/photoId.
- **Q2 -- access:** public-by-unguessable-path reads (random photoId, no path listing). Chosen over
  private/signed-URL access, which would need either a server round trip per photo or a new C++ HTTP
  cache -- not worth it for product photos with no stated privacy need.
- **Q3 -- background model:** uploads while the app process is alive, resuming on next launch if
  killed. True OS-level background upload (WorkManager/iOS background sessions) explicitly rejected
  -- unbuildable and untestable in this sandbox.
- **Atomicity:** not literally possible across Storage + Firestore (two systems, no shared
  transaction). Closest achievable: write bytes first, then one Firestore transaction that both
  records the id and its idempotency marker -- an id is never visible without its bytes; worst case
  on crash is an orphaned, unreferenced Storage object, not a corrupted product.
- Defaults not vetoed: max 10 photos/product; any tenant member may upload/remove; no bulk migration
  of existing legacy `photoUrl` values (a one-tap "sync old photo" affordance instead); delete
  cascade cleans up Storage; work split into 3 PRs (server+rules+CI / client queue+UI / docs+e2e).

Full design: `docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md`
Full plan: `docs/superpowers/plans/2026-09-21-product-photos-firebase-storage.md` (16 tasks, 3 PRs)

## Status: PR 1 and PR 2 complete and pushed. PR 3 (docs + e2e test) not started.

### PR 1 -- server, rules, CI (complete)

- `functions/lib/photoValidation.js` -- pure JPEG validation. 7/7 real tests.
- `qml/helper/PhotoUrl.js` (+ Node parity mirror) -- pure download-URL builder. 5/5 real tests. (A
  real off-by-one was caught and fixed in my *own test*, not the implementation.)
- `qml/helper/PhotoQueueLogic.js` (+ Node parity mirror) -- classification/backoff/breaker/reducer.
  23/23 real tests incl. 2 monkey tests, stable x5. Caught and fixed a **real bug**: a stale
  `'failed'` event against an already-`failed` item kept incrementing `attempts` past the cap.
- `storage.rules` + `test/storage.rules.test.js` -- public read, no client writes. API verified
  against the actually-installed `@firebase/rules-unit-testing@5.0.1` package's own `.d.ts` files.
- `functions/index.js`: `uploadProductPhoto`, `deleteProductPhoto` -- idempotent on `requestId`
  (same `audit_log` mechanism as every other mutation). 19/19 real tests via the existing
  `handlerHarness.js` (extended with a Storage mock). Two real bugs caught and fixed: (1)
  `deleteProductPhoto`'s Storage cleanup ran on *every* idempotent replay, unbounded; (2) it
  originally 404'd on a missing product doc, which would've broken the delete cascade depending on
  call order -- now tolerant of that case (design spec corrected to match).
- CI (`.github/workflows/checks.yml`): Storage emulator wired into the rules-tests job and the e2e
  job.
- **Full `functions/` suite: 288/288, run for real, stable, as of the post-rebase merge with
  upstream's `recordOperation` work.**

### PR 2 -- client queue + UI (complete)

- `src/NativeFile::readFileBase64` -- native, **not buildable/testable in this sandbox** (no Qt
  toolchain). Flagged plainly; on-device/CI build is the only proof.
- `OutboxStore.hasPendingForEntity` -- gates PhotoQueue's Trap 1 (a photo for a product created
  offline waits for that product's own create mutation to land). 8 new tests (not runnable here).
- `PhotoQueue.qml` -- durable, resumable upload queue, sibling to Gateway/OutboxStore, registered in
  `qml/model/qmldir`. **Caught a real crash-class bug before it ever ran**, by reading SKILLS.md
  Skill 20 rather than by a test: a `Connections{}` block watching online status would have crashed
  the entire singleton chain (any `pragma Singleton QtObject` root can't host `Connections{}`) --
  would have broken every screen in the app, not just photos. Fixed with the property-binding-
  watcher pattern Skill 20 prescribes. Also discovered `NativeFile`/`ImageProcessor` are root
  context properties, not QML singletons -- undefined under `qmltestrunner` -- so `drainCandidates()`
  (the gating decision) is a separate, genuinely-testable function from `_upload()` (native+XHR,
  untested at this level, same precedent as `Gateway._send`). 20 tests (not runnable here).
- `StorageService.qml` -- rewritten entirely (not extended) for the new model: `addProductPhoto`,
  `removeProductPhoto`, `photoDownloadUrl`. The old single-device `useCloud`/local-URL model is
  gone.
- `EnvConfig.storagePrefixForEnv` -- new, mirrors `databaseIdForEnv`'s pattern (Storage paths spell
  `prd` literally where Firestore's database id is `(default)`). 3 tests.
- `InventoryStore.qml` -- `photoIds` added to `_normalizeProducts`/`_clone()`/`_newProductDoc()`
  (kept in exact sync per this file's own documented CAS-conflict-prevention invariant);
  `applyPhotoIds`/`clearLegacyPhotoUrl` (new); `deleteProduct`'s cascade now loops
  `removeProductPhoto` per remaining photoId plus a legacy-file fallback. Updated
  `tst_InventoryStore_deleteProductCascade.qml` (fixed a comment that would have gone stale, added
  2 new cases for the actual multi-photo/legacy-fallback paths).
- `qml/components/ProductPhotoGallery.qml` -- new: cover + thumbnail strip, per-tile spinner/Retry/
  Discard/remove. Caught two more real bugs before they could break loading: `Icon` lives in
  `qml/components/` not `qml/helper/` (missing import); and a `Repeater` model bound through a
  function call (`_queuedForProduct()`) can't be trusted to re-evaluate reactively without a way to
  test it here -- matched this codebase's own established pattern (`DataModel.qml`'s explicit
  `revision`-driven refresh) instead of assuming.
- `EditProductDialog.qml`, `AddProductDialog.qml`, `Main.qml` -- wired to the gallery/queue. The
  shared `PhotoSourceSheet` contract (`applyPhotoSource`/`clearPhotoSource`/`photoPickRequested`,
  hoisted to `Main.qml`, shared with `AddProductDialog`) is preserved; removal moved from the sheet
  into the gallery's own per-photo buttons. `PhotoQueue.photoUploaded -> InventoryStore.applyPhotoIds`
  wiring lives in `Main.qml` (can't live inside `InventoryStore` itself -- Skill 20 again).
- `InventoryPage.qml` -- card cover photo prefers `photoIds[0]`'s thumbnail, falls back to legacy
  `photoUrl`.
- **Everything QML/native in PR 2 is written and, where genuinely separable from native/network
  calls, unit-tested -- but none of it has run under `qmltestrunner` or on a device. CI is the first
  real proof.**

### Rebase (this session, after PR 2)

PR #84 was `mergeable_state: dirty` against `main` (19 commits of drift, including CI-workflow and
`functions/index.js` changes from upstream's `recordOperation` work). Rebased successfully. One real
conflict, in `.github/workflows/checks.yml` (upstream added `recordOperation` e2e reporting; this
branch added the Storage emulator) -- merged both by hand, not by picking a side. Verified: 288/288
`functions/` tests pass post-rebase; 15 feature commits intact with correct diffs. CHECKPOINT.md
itself was the casualty of a `--ours`/`--theirs` mistake during the CHECKPOINT-only conflicts (see
the note at the top of this file) -- fixed by rewriting this file, not by redoing the rebase.
Force-pushed.

## Not started: PR 3 -- docs + e2e (plan Tasks 13-16)

- Task 13: `test/e2e/tst_ProductPhotosE2E.qml` -- real emulator, service-level, proves the delete
  cascade end to end. Not runnable here; written for CI.
- Task 14: `SKILLS.md` (one new numbered entry -- the atomicity/traps/parity-test findings),
  `AGENTS.md` (Store & Firebase Agent, Testing & QA Agent sections), `README.md` (features,
  `storage.rules`, emulator port).
- Task 15: `docs/superpowers/test-plans/2026-09-21-product-photos-firebase-storage-test-plan.md`,
  following the repo's template, honest about what ran for real (288 functions tests, stable) vs.
  what's written-but-unverified (everything QML/native/rules-emulator/e2e).
- Task 16: final push.

## What Taher needs to do (not automatable from here)

- **Deploy `storage.rules` and the two new functions before any of this does anything in
  production** -- PR 1/2 merging doesn't deploy by itself.
- Confirm the bucket name/region assumptions (`inventorymanager-48392.firebasestorage.app`,
  `asia-south1`) still match the Firebase console.
- Review PR #84 on GitHub; CI is the first real test run for everything QML/native/rules-emulator.

## Review sweep (2026-09-25): requesting-code-review + ponytail-review + qt-qml-review

No subagent-dispatch tool available in this environment, so the review was done directly rather
than via the skills' own dispatched-subagent flow -- same checklists, applied by hand.

- **qt-qml-review's linter**, run against only the lines this PR actually added (diff-filtered, not
  whole files -- these are large pre-existing files). 205 raw findings, all but one were false
  positives *for this codebase specifically*, verified against real precedent rather than assumed
  (var-everywhere, no `id: root` in any of 73 existing test files, dot-notation anchors, `property
  var` for list-shaped state, `Qt.createQmlObject` as the Skill-20 timer workaround Gateway.qml
  itself already uses, and a linter regex bug on `!==`/`===` mistaken for loose equality). One real
  fix applied: `sourceSize` added to both `Image` elements in `ProductPhotoGallery.qml` (decoding
  full-resolution photos into 72px tiles wastes memory on mobile).
- **ponytail-review**: one real dead-code item -- `ProductPhotoGallery`'s `photoRemoved` signal was
  emitted with zero listeners anywhere. Removed rather than inventing new Toast wiring nobody asked
  for.
- **Manual correctness pass** (requesting-code-review's lens) found **four real, independent bugs**,
  none caught by this feature's own tests:
  1. `PhotoQueue.clear()` existed but was never wired into sign-out -- a pending photo would have
     replayed under the next signed-in account on a shared device. Wired into `Main.qml`'s sign-out
     handler alongside `Gateway.clear()`/`LockManager.clear()`.
  2. **Path-traversal gap**: `productId`/`photoId` from the request body went straight into a
     Firestore path and a new Storage object path, unvalidated. Added
     `PhotoValidation.isSafePathSegment()` (rejects `/`, `..`, empty, non-string, >200 chars),
     wired into both `uploadProductPhoto` and `deleteProductPhoto` before either id touches
     anything. 8 new tests.
  3. `PhotoQueue` never actually called `AuthService.ensureFreshToken()`, despite the design saying
     it would -- an item stuck on a stale token could stall indefinitely. Added to `drainNow()`,
     matching `Gateway.drainNow()`'s exact placement.
  4. **The most serious one**: `PhotoQueue._load()` (`Component.onCompleted` on every real app
     launch) loaded persisted items but never called `_reschedule()` -- a photo queued in a
     *previous* session just sat frozen forever unless something else happened to trigger a drain.
     This silently broke "survive app close", which Taher stated explicitly as a requirement. Fixed.
- `functions/` suite after all review fixes: **296/296, stable across 3 runs** (was 288 before this
  pass). Two regression tests added for findings 3+4 in `tests/tst_PhotoQueue.qml` (not runnable
  here, CI is the proof).

## Second rebase (2026-09-25)

`main` moved 3 more commits (a merged docs PR, #85) between the first rebase and pushing the review
fixes, making PR #84 `dirty` again -- not something this session broke, ordinary drift. Rebased a
second time onto the new tip. This time, to avoid repeating the earlier `--ours`/`--theirs` mistake,
`CHECKPOINT.md`'s one conflict was resolved by capturing the file's known-good content *before*
starting the rebase and forcing that exact content back at the conflict, rather than trusting
git's merge-side semantics again. Verified byte-identical after. `functions/` suite re-run clean,
296/296. Force-pushed. **PR #84: `mergeable: true`, `mergeable_state: unstable`** (GitHub's term
for "mergeable, CI hasn't reported back yet" -- not a conflict) as of this push.
