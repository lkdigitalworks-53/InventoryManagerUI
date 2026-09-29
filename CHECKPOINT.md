# CHECKPOINT — 2026-09-29 PR #84 device-test round 4: photo arrangement + rounded-corner overflow

**Branch:** `feature/2026-09-21-product-photos-firebase-storage` (PR #84 head; fixes in the SAME PR per owner).
**Commit identity:** `Taher (via Claude session) <lkdwtaher@gmail.com>` (owner instruction this session — supersedes
both `<taher.lkdw@gmail.com>` and `<tsadmin@gmail.com>` seen in earlier commits on this branch; use this one going forward until told otherwise).
**Skills invoked:** superpowers:brainstorming, qt-development-skills:qt-qml, qt-development-skills:qt-ui-design, ponytail:ponytail (+ caveman chat style).
**Rules:** no build/run, no Qt tooling in sandbox, CI is the signal; push without asking; PAT only in push URL — **owner: rotate it, it sits in plaintext in chat (flagged again this session, same as round 3 — still unrotated as far as this session can tell).**

## Two real bugs, neither touched by the 2026-09-28 round

| # | Symptom (owner, testing PR #84 on-device) | Root cause | Status |
|---|---|---|---|
| 1 | "Photos goes out of the rectangle" | `clip: true` on a `Rectangle` clips children to the axis-aligned bounding box, NOT to `radius`. The tile's `Image` (`PreserveAspectCrop`, filling the box) is a plain rectangle — its square corners sit past the rounded frame's arc at all four corners. The 2026-09-28 round fixed a *different* overflow (tiles running off the right edge, via `Flow`) and never attempted rounded-corner clipping at all. | FIXED — new `RoundedThumb.qml`, `MultiEffect` mask. On-device/visual verification only: no CI job reaches this file (Felgo-gated), see test plan |
| 2 | "I don't like the UI arrangement of the photos" | The Flow-wrap grid (2026-09-28's own fix) reflows into uneven rows and grows vertically as photos are added, pushing the rest of the edit form down — a working but boxy pattern, not the horizontal-filmstrip pattern this kind of multi-photo UI usually uses. | ADDRESSED — rewritten as a horizontal `ListView` filmstrip |

## What changed

- `qml/components/ProductPhotoGallery.qml` rewritten: `RowLayout { ListView (horizontal,
  Layout.fillWidth, clip) ; + tile (Layout.preferredWidth, fixed) }`. The `+` tile is deliberately
  kept OUTSIDE the scrollable `ListView` at a fixed position — the 2026-09-28 test plan explicitly
  rejected a horizontal `Flickable` because it would hide the `+` tile until scrolled; pinning it
  outside the scroll region keeps that guarantee while still fixing the overflow/arrangement
  complaint. Model is now one precomputed `_combined` array (confirmed photos, cover flagged at
  build time, then queued items) instead of two separate Repeaters relying on the delegate's own
  `index` — this also structurally removes the entire bug class the 2026-09-28 "Cover on every
  tile" bug came from (a `required property` on a delegate silently drops implicit `index`
  injection), since cover-ness is no longer inferred from `index` at all.
- New `qml/components/RoundedThumb.qml`: `MultiEffect`-masked `Image`, reused at both tile call
  sites (confirmed + queued) instead of duplicating the mask boilerplate. Requires Qt 6.5+
  (`QtQuick.Effects`); CI is pinned to 6.8 (`.github/workflows/checks.yml`) so that's fine for CI,
  but this file is never actually exercised by CI (see below) — first real proof is on-device. If
  corners still look square there, check for a `QtQuick.Effects` shader-compile console warning;
  that would mean the Qt install is missing `qtshadertools`.
- Cover badge: small corner star pill (top-left) instead of the old full-width bottom banner —
  part of the arrangement rework, not a separate ask.
- Swapped two hardcoded hex colors (`#dc2626`, `#2563eb`) for the existing `Constants.danger` /
  `Constants.accentBlue` tokens already used elsewhere in the app — same idea, now themed instead
  of a stray literal (`Constants.danger` is `#ef4444`, a slightly different red than the old
  `#dc2626`; flagging the exact-shade change here in case it matters to owner, since it's the one
  visible pixel difference not explicitly asked for).
- `tests/tst_PhotoGalleryLayout.qml` rewritten (16 tests): the old file's 9 tests specifically
  proved `Flow`-wrap row math, which no longer applies to a `ListView`. New tests mirror
  `_refreshAll`'s combined-array construction (ordering, cover flag, empty/queued-only cases) and
  reproduce the real `RowLayout`+`ListView`+fixed-tile composition to prove the `+` tile can never
  leave the container regardless of photo count, scroll state, or container width (100-iteration
  monkey test included).
- `README.md` and the design spec's "UI" section both had the 2026-09-28 `Flow` arrangement
  documented as current fact — updated to match.
- New test plan: `docs/superpowers/test-plans/2026-09-29-photo-gallery-filmstrip-rearrange-test-plan.md`,
  README index + chain note added.
- `EditProductDialog.qml`: **no change** — `ProductPhotoGallery`'s public properties/signals
  (`productId`, `photoIds`, `editable`, `addPhotoRequested`, `removeFailed`) are unchanged, so its
  one embed site didn't need touching. Confirmed via grep before starting (single embed site, no
  other file references `tileSize` or gallery internals) — kept the blast radius to the two
  component files + the test file.

## Deliberately NOT done (flagged, not guessed)

- No hero/large cover image above the filmstrip. Considered it (common on customer-facing product
  pages) and rejected it for THIS screen specifically: this is an inventory edit *form*, not a
  customer product page — a large hero would eat vertical space better spent on the form fields
  below it (Progressive Disclosure / Performance Load). Said here so it's a visible decision, not
  a silent omission, in case owner disagrees.
- Did not fix the pre-existing `tileSize` unit inconsistency (`root.tileSize` used as a raw pixel
  value in most places, `dp(160)` used for the failed-tile width) — it predates this round, isn't
  what was reported, and touching it would change on-screen sizes as an unrelated side effect.
  Flagging it here rather than silently fixing or silently ignoring it.
- Did not add per-tile drop shadows or other extra visual flourish beyond what fixes the two
  reported complaints — the rest of this dialog uses flat 1px borders, not shadows, and matching
  that existing local convention seemed more "theme-consistent" than adding a new visual language.

## Steps

1. Read memory (project files), loaded 5 skills (caveman, qt-ui-design, qt-qml, ponytail,
   brainstorming-adjacent reasoning — no separate brainstorm doc written, reasoning captured here
   instead per lean-session judgment).
2. Cloned fresh, checked out PR #84 head (`27293fc`), read the last 3 checkpoint entries + the
   2026-09-28 test plan in full (found the "rejected scrollable + tile" decision there — this is
   why the redesign pins the `+` tile outside the list instead of just switching to a plain
   `Flickable`).
3. Read `ProductPhotoGallery.qml`, `EditProductDialog.qml`'s embed site, `Constants.qml` (design
   tokens), confirmed CI's Qt version (6.8) and that no CI job actually compiles/renders this file
   (Felgo-gated, qmltestrunner-only CI).
4. Wrote `RoundedThumb.qml`, rewrote `ProductPhotoGallery.qml`, rewrote the test file, updated
   README + design spec + test-plan README index, wrote the new test plan.
5. Corrected commit identity mid-session per owner's explicit instruction this session
   (`lkdwtaher@gmail.com` — see "Commit identity" above; an earlier reply in this same session had
   guessed `taher.lkdw@gmail.com` from the branch's own git history before owner corrected it).

## Next steps (resume here)

1. Wait for CI on the new push (qml-tests job; the other two jobs — functions, firestore-rules —
   are untouched by this change and should be unaffected).
2. Owner: on-device check per the new test plan, section 5 — corners actually rounded, `+` tile
   reachable at every photo count, failed-tile Retry/Discard row not clipped.
3. The 2026-09-28 round's OPEN item (R3 / Bug 3 — list-cover thumbnail not showing, diagnostics
   added but root cause not yet confirmed) is still open and untouched by this session — see the
   "round 3" entry immediately below for its own diagnosis checklist. Not forgotten, just a
   different area of the same PR.
4. Rotate the GitHub PAT — flagged again, still appears to be the same one from round 3.

---

# CHECKPOINT — 2026-09-28 (round 3) PR #84: CI red test + list-cover (no thumbnail) investigation

**Branch:** `feature/2026-09-21-product-photos-firebase-storage` (PR #84 head; fixes in the SAME PR per owner).
**Commit identity:** `Taher (via Claude session) <taher.lkdw@gmail.com>` (owner instruction this session).
**Skills invoked:** superpowers:systematic-debugging, qt-development-skills:qt-qml, qt-development-skills:qt-ui-design, ponytail:ponytail (+ caveman chat style).
**Rules:** no build/run, no Qt tooling in sandbox, CI is the signal; push without asking; PAT only in push URL — **owner: rotate it, it sits in plaintext in chat.**

## Findings

| # | Symptom | Root cause | Status |
|---|---|---|---|
| C1 | CI `QML Tests` red: `InventoryStore_photoIds::test_applyPhotoIds_never_enqueues_a_gateway_mutation` | PROVEN from code: `applyPhotoIds(...,"add")` -> `TransactionStore.recordPhotoChange` -> `_push` -> `Gateway.recordMutation("transaction",...)` => pendingCount 1. Test asserted 0. Prod code right, test wrong | FIXED (test), CI decides |
| R3 | Inventory list shows no cover thumbnail; owner's log inside the photo-URL function never prints | Function is only reached when `card.product.photoIds` is a non-empty array. Traced read path (Firestore decode -> `_normalizeProducts` -> `products` -> `_filteredProducts` -> Repeater -> `card.product`) and every `_clone()` write path: NONE drops photoIds. So list products have empty photoIds => most likely no upload was ever CONFIRMED (functions `uploadProductPhoto` not deployed / failing; gallery was showing PhotoQueue local copies). NOT PROVEN | OPEN — diagnostics added, needs owner's log lines (test plan §4 "Bug 3 diagnosis", Round 3) |

Diagnostics added: `[InventoryStore] Synced N products ..., M with photoIds` and `[PhotoQueue] upload confirmed <pid> <photoId> photoIds: n`.

## Suspected, UNVERIFIED (separate from this PR's bugs)
`InventoryStore._normalizeRecord` and `_mergeRecord` (bulk import) have no `photoIds` key; an import that overwrites an existing product may send a whole-record CAS `after` without photoIds and wipe them. Verify before touching.

## Steps
1. Read memory, 4 skills; cloned; checked out PR #84 head `c56801f`.
2. CI via API: only `QML Tests` red, 1 test (PR comment).
3. Fixed test; added 1 extra test (no changedPhotoId => 0 enqueued).
4. Added 2 diagnostic logs; test plan Round 3 checklist; Skill 77.

## Next steps (resume here)
1. Wait for CI on the new push.
2. Owner: run app, send the two log lines above + Firebase console check (`photoIds` on the inventory doc, Storage folder). If M=0 / no "upload confirmed": check functions deployment + `[PhotoQueue] upload failed` status, NOT the list UI.
3. If M>0 but no cover: then it IS the list binding; next hypothesis is `Array.isArray` on modelData arrays in Repeater — add log in `ProductCard`.

---

# CHECKPOINT — 2026-09-28 (round 2) PR #84 device-test bugs: Cover label, dialog refresh, strip overflow, list cover

**Branch:** `feature/2026-09-21-product-photos-firebase-storage` (PR #84 head; fixes go in the SAME PR).
**Commit identity:** `tsadmin <tsadmin@gmail.com>` (matches the PR's latest commit). Push after each step; PAT only in the push URL, never in the repo — **owner: rotate it, it sits in plaintext in chat.**
**Skills invoked:** qt-development-skills:qt-qml, qt-development-skills:qt-ui-design, ponytail:ponytail, superpowers:systematic-debugging (+ caveman chat style).
**Rules:** no build/run, no Qt tooling in sandbox, CI is the signal; tests + test plan + docs per change.

## Round-2 bugs (owner, on device)

| # | Symptom | Root cause | Status |
|---|---|---|---|
| R1 | "Cover" on every photo | delegate has `required property modelData` but no `required property int index` -> `index` unresolved -> binding dead -> `visible` default true | FIXED (gallery) |
| R2 | New photo not shown in open Edit dialog | `photoIds` snapshot copied in `openFor()`, never refreshed | FIXED (`Connections` + `InventoryStore.photoIdsFor`) |
| R3 | No cover photo in Inventory list | NOT PROVEN from code (same URL helper as gallery; list reads store live). Candidates E1 thumb URL fails on device, E2 list products lack photoIds | OPEN — `Image.Error` logging added to `AvatarBadge` + gallery; needs the log line (test plan §4 "Bug 3 diagnosis") |
| R4 | 5+ photos run off-screen, + hidden | `RowLayout` cannot wrap/scroll | FIXED (`Flow`) |

## Steps (in order)

1. Read project notes + 4 skills; cloned repo; checked out PR #84 branch `feature/2026-09-21-product-photos-firebase-storage` @ `09ac9e2`.
2. Phase 1 traced gallery, dialog, InventoryPage, InventoryStore, PhotoQueue, StorageService, server upload, storage.rules, gatewayLogic.
3. Fixed R1/R4 in `ProductPhotoGallery.qml`; R2 in `EditProductDialog.qml` + `InventoryStore.photoIdsFor`; R3 diagnostics in `AvatarBadge.qml`.
4. Tests: `tests/tst_InventoryStore_photoIds.qml`, `tests/tst_PhotoGalleryLayout.qml` (both unrun locally; CI decides).
5. Docs: test plan `2026-09-28-photo-gallery-cover-scroll-list-test-plan.md` (+ index row), Skill 76 in SKILLS.md, README gallery note. AGENTS.md: no change needed.
6. Committed and pushed (see git log).

## Next steps (resume here)

1. Wait for CI on the new push; fix any round the two new QML tests need (unrun-test corrections are normal, see learnings).
2. Owner: on-device pass of the test plan; for R3 send the `[AvatarBadge] image failed to load:` log line (or say there is none).
3. If R3 is E1: check `storage.rules` deployed, object exists at `{env}/tenants/{t}/products/{p}/{photoId}_t.jpg`.
4. Pending from before: functions `uploadProductPhoto`/`deleteProductPhoto` deployment not confirmed.

---

# CHECKPOINT — 2026-09-28 device-test bug-fix round on PR #84 (product photos) — IN PROGRESS

**Branch:** `feature/2026-09-21-product-photos-firebase-storage` (PR #84 head; fixes go in the SAME PR per owner).
**Commit identity:** `tsadmin <tsadmin@gmail.com>`. Push after every step; PAT is supplied per session by the
owner in chat and is NEVER written to the repo (owner was told to rotate it, it sits in plaintext in chat).
**Standing rules this session:** no build/run, no Qt tooling in sandbox (CI is the signal), tests + test plan +
docs per change, be an honest advisor, caveman-terse chat replies.

## Bugs reported on device (owner, PR #84)

| # | Symptom | Status |
|---|---|---|
| B1 | Add product w/ photo, reopen: spinner forever; log `Cannot open: file://file///C:/...photo-....jpg` | root cause found |
| B2 | Nothing in Firebase Storage | same root cause as B1/B3 (XHR never sent) |
| B3 | Photo on another product fails instantly, Retry/Discard | same root cause |
| B4 | Retry/Discard inside the 72px tile, too cramped | UI fix planned |
| B5 | Log: `[PhotoQueue] upload failed ... 400` | same root cause (local read failure reported as terminal 400) |
| B6 | After discard + re-add: huge gap between tile and + | root cause NOT proven yet |

## Root causes (systematic-debugging Phase 1, from code — nothing was run)

1. `ImageProcessor::persistLocalCopy` returns `QUrl::fromLocalFile(...).toString()` = `file:///C:/...`. That URL is
   stored verbatim as `mainFilePath`/`thumbFilePath` in `PhotoQueue`. Consumers assume a bare path:
   - `ProductPhotoGallery`: `"file://" + mainFilePath` -> `file://file:///C:/..` (B1 log line).
   - `PhotoQueue._upload`: `NativeFile.readFileBase64(url)` -> `QFile("file:///..")` does not exist -> `""` ->
     "persisted file is gone" branch -> terminal status 400, XHR never sent (B2, B3, B5).
   Persisted queue items on the owner's device already hold the URL form -> fix must tolerate both forms.
2. `PhotoQueue` never re-drains when the product's own OutboxStore create lands. `_reschedule()` arms a one-shot
   timer; `drainNow()` finds the item gated (Trap 1) and does nothing; nothing re-arms. Item sits `enqueued`
   (spinner) until app restart / online flip (B1 spinner).

## Steps (in order)

1. Cloned repo, checked out PR #84 branch (up to date with `main` @ `e83cc6b`), read skills + code.
2. Root-caused 1 and 2 above. B6 (gap) not provable by reading code.
3. Checkpoint written + pushed (8cb810b).
4. S-A/S-B/S-C/S-D/S-E implemented in one batch (see files below). Node `functions/` suite 329/329 RUN.
   QML tests written, NOT run (CI is the signal).

## Files changed this round
`qml/helper/PhotoUrl.js` (+Node mirror `functions/test/testSupport/photoUrlParity.js`), `qml/model/PhotoQueue.qml`
(toLocalPath reads, unreadable-file log, `_outboxWatcher` re-arm), `qml/components/ProductPhotoGallery.qml`
(toFileUrl source, buttons below tile, AlignTop), `tests/tst_PhotoUrl.qml`, `tests/tst_PhotoQueue.qml`,
`functions/test/photoUrl.parity.test.js`, `SKILLS.md` Skill 75, `README.md`, test plan + index row.

## Next steps (resume here)
- WAIT for CI on PR #84; fix any QML test/lint failures it reports.
- Owner re-tests on device per `docs/superpowers/test-plans/2026-09-28-photo-device-bugfix-test-plan.md`.
- B6 (gap) still unproven: if it persists, need a screenshot / the dialog's layout tree.
- Open decision for owner: fix path form at C++ source (`persistLocalCopy` return bare path) vs. QML-tolerant
  helpers (chosen: helpers, because old queued items already hold URL form and QML is CI-testable).

## Original next-step list (superseded, kept for trace)

- S-A `PhotoUrl.js`: `toLocalPath` / `toFileUrl` (+ Node parity mirror + QML + Node tests).
- S-B `PhotoQueue._upload` reads via `toLocalPath`; gallery source via `toFileUrl`.
- S-C `PhotoQueue`: re-arm drain on `OutboxStore.revision` change (property watcher, NOT Connections — Skill 74).
- S-D Gallery: failed tile actions moved OUTSIDE the tile, real touch targets, top-aligned deterministic layout.
- S-E Test plan `docs/superpowers/test-plans/2026-09-28-photo-device-bugfix-test-plan.md` + README index row,
  SKILLS.md new Skill, README changelog. Push, then wait for CI.

---

# (previous checkpoint below — original PR #84 feature work)

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

## Status (updated 2026-09-27): PR 1, PR 2, and PR 3 are all code-complete and pushed
(22 commits). **Not yet true:** the "final push, mark done" step (plan Task 16) was never done —
this file was left saying "PR 3 not started" for two extra commits after PR 3 actually landed. See
the 2026-09-27 session note below for what that drift caused and what's actually still open.

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

## PR 3 -- docs + e2e (plan Tasks 13-16) -- actually done, just never marked so

- Task 13: `test/e2e/tst_ProductPhotosE2E.qml` shipped in `e9b29b7`. Not runnable here; written for
  CI.
- Task 14: `SKILLS.md`/`AGENTS.md`/`README.md` shipped in `b46b0f8`.
- Task 15: the test plan shipped in `19a10ad`
  (`docs/superpowers/test-plans/2026-09-21-product-photos-firebase-storage-test-plan.md`) --
  read it this session; it correctly separates "run for real" from "written, CI/device is the
  proof" per file, has the On-Device Test Plan (Happy Path / Negative / Edge / Regression /
  Monkey) Taher's standing instructions ask for, and is genuinely thorough. No changes made to it.
- Task 16 ("final push, update CHECKPOINT.md to done") is the one piece that was never done --
  this file kept saying "not started" through the last four commits. That's a paperwork gap, not
  a code gap, but see below for what it hid.

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

## Session (2026-09-27, new account/session, commit identity `tsadmin@gmail.com`) -- review of PR
#84 for "what's pending," not new feature work

Asked to review PR #84 and say what's left before it's ready for on-device testing. Findings, most
important first:

1. **CI has not run on this branch's last 4 commits at all** (`80874f7`, `e9b29b7`, `b46b0f8`,
   `19a10ad`). Checked via the Actions API, not assumed: the only two green runs for this branch are
   on `470b7e672d` (2026-09-24) and `43108ae`/`9b7f4af` (2026-09-25) -- the e2e test, the
   docs/skills/agents updates, and the test plan itself have **never been through CI**. The repo's
   workflow trigger (`.github/workflows/checks.yml`) is `pull_request: [opened, synchronize,
   reopened]` plus `push: main` only, so a push to an open PR's branch should fire `synchronize` --
   it's not obvious from here why it didn't for these four. This CHECKPOINT.md commit is a real
   code-free push to this branch specifically to re-trigger that `synchronize` event and get a real
   CI read on the current tip; if it still doesn't fire, that's a repo/Actions-config problem to
   raise with GitHub, not a code problem.
2. **PR #84 is `mergeable_state: dirty` against current `main`, not just `unstable`.** `main` has
   moved 22 commits since this branch's last rebase (2026-09-25): PR #83 (atomic order completion,
   Gateway send-timeout, `OutboxStore` gained operation items / per-key `dueItems` ordering / retry
   jitter) and PR #87 (completion-store hooks) both landed, plus the staff-delete-UI and P1
   stock-movement docs work. A dry-run merge (`git merge-tree`) against current `main` shows real
   conflicts in 10 files, not just doc drift:
   - `functions/index.js` -- adjacent, not overlapping: main added a staff-delete role check next to
     where this branch's photo handlers sit. Mechanical to combine.
   - `qml/model/InventoryStore.qml` -- adjacent additions (photoIds vs. unrelated store changes).
     Looks mechanical but wasn't traced line-by-line this session.
   - **`qml/model/OutboxStore.qml` and `tests/tst_OutboxStore.qml`** -- this is the one I'd flag as
     genuinely risky, not mechanical: PR #83 changed `OutboxStore`'s internal shape (operation items,
     `dueItems` ordering, retry jitter) in the same area this branch's `hasPendingForEntity` (Task 9,
     PhotoQueue's Trap 1 gate) reads from. A careless resolution could silently make Trap 1 pass or
     fail against the wrong internal state, and nothing in this sandbox (`qmltestrunner` unavailable)
     would catch that -- only CI or a device would.
   - **`qml/Main.qml`** -- 36 changed hunks on each side; both branches wire new things into the same
     file (sign-out handling, new store hookups). Also needs care, not a quick auto-merge.
   - `AGENTS.md`, `README.md`, `SKILLS.md`, `docs/superpowers/test-plans/README.md` -- doc-only,
     genuinely mechanical (different sections/list entries on each side).
3. **Re-verified, not assumed:** `cd functions && node --test` on this exact commit (`19a10ad`),
   this session -- **296/296, real, just run.** The functions-layer number in the test plan still
   holds on the current tip.

**Recommendation, not yet acted on:** don't rebase blind. Get a fresh CI signal on the current tip
first (this commit should trigger it); if CI is green on today's actual code, the mechanical
conflicts (functions/index.js, InventoryStore.qml, the four doc files) are safe to resolve in one
pass, but `OutboxStore.qml`/`tests/tst_OutboxStore.qml` and `Main.qml` deserve a slower, side-by-side
resolution against both PRs' intent -- and ideally a second pass through `qt-qml-review` and
`requesting-code-review` after, the same way the 2026-09-25 review sweep caught four real bugs that
tests alone hadn't. That's the next session's/next account's task if this one's budget runs out
first; nothing above has been changed in a way that risks the currently-green `main` -- this commit
only touches `CHECKPOINT.md`.

## Merge with `main` (2026-09-27, same session) -- done as a merge, not a rebase

Asked to rebase; did a merge of `origin/main` into this branch instead and said so before doing it
(this branch's own history above already documents two rebase mishaps against this exact file, and
the branch is an open, already-pushed PR -- a merge is one commit, non-destructive, no force-push).

**Conflicts:** only 4 of the 10 files `git merge-tree` had flagged actually conflicted textually --
`functions/index.js`, `qml/Main.qml`, `qml/model/InventoryStore.qml` merged clean on their own.
Resolved the remaining 4:
- `CHECKPOINT.md` -- kept ours whole (per instruction); main's version was an unrelated, already-
  merged feature's scratchpad (C-3 completion-store-hooks), not complementary content.
- `SKILLS.md` -- both sides had claimed "Skill 68". Kept main's Skills 68-71 (staff-delete,
  CI-counting, hard-delete tombstone, normalize-whitelist findings) as the authoritative sequence,
  renumbered this branch's atomicity/traps/Connections finding to **Skill 72** at merge time (later renumbered again, see the Rebase section at the end: now Skill 74).
- `docs/superpowers/test-plans/README.md` -- one index row (the P1 stock-movements test plan) had a
  stale summary carried on this branch vs. main's current one for the same file; kept main's (that
  work isn't this branch's own), kept this branch's own photos-test-plan row untouched.
- `tests/tst_OutboxStore.qml` -- two independent new test blocks landed at the same insertion point
  (this branch's `hasPendingForEntity` Trap-1 tests; main's `enqueueOperation`/atomic-operation tests
  from PR #83/#87). Non-overlapping, concatenated both, kept both intact.

**Checked, not just trusted, the two files flagged earlier as genuinely risky** (`OutboxStore.qml`
gained operation-item support from PR #83/#87 in the same area `hasPendingForEntity` reads):
`_keysForItem` already branches on `item.ops`/`item.items`/plain single-entity shape, and
`hasPendingForEntity` calls `_keysForItem` rather than re-deriving key logic -- so it now also
correctly treats a queued/in-flight *operation* item as "pending" for any entity it touches, which
is strictly more correct for Trap 1, not a regression. `markSent`/`markFailed` are keyed on
`requestId` uniformly across every item shape, unaffected. `Main.qml`'s sign-out block has
`Gateway.clear()`, `LockManager.clear()`, `StaffStore.clear()` (main's), and `PhotoQueue.clear()`
(this branch's) all present once, no duplication. Traced by reading the merged file, not assumed
from "git said no conflict."

**Re-ran the one real check available here after merging:** `functions/` suite, current merged
tree -- **307/307, real, just run** (up from 296 pre-merge; the difference is main's own new tests
for staff-delete role checks etc., not a regression in this feature's count).

**Still true after this merge:** nothing here proves the QML/native/rules-emulator/e2e layers --
that's still CI-or-device only, same as before. This commit is a merge commit; pushing it should
fire a fresh `synchronize` event same as the last one attempted to.

**Not given: a go-ahead for on-device testing.** "Feature-complete and never actually run through
CI" isn't the same claim as "ready to test," especially with two files whose merge resolution
genuinely affects the queue logic. On-device testing prerequisites (infra, independent of the
rebase) are listed in the test plan's own "On-Device Test Plan" preamble: deploy `storage.rules`
and both Cloud Functions (`uploadProductPhoto`, `deleteProductPhoto`) to a non-prod Firebase project
first, confirm the bucket/region assumptions (`inventorymanager-48392.firebasestorage.app`,
`asia-south1`) against the actual console, and have two devices/instances signed into the same
tenant available for the cross-device sync checks.

## CI failure on the merge commit, found and fixed (2026-09-27, same session)

Merge commit `3a94bea` triggered CI for real this time. Result: QML Tests (1178/1178), Functions
Tests (229/229), Firestore+Storage Rules (35/35) all green. **E2E Tests: 44/50, 6 failed** — all 6 in
`tst_ProductPhotosE2E.qml`, all 6 (and only) the tests calling `_createProduct()`; the 7th test in
the file (no `_createProduct()` call) passed. This was this test file's first-ever real execution
(it was written in `e9b29b7`, after this branch's last successful CI run, so nothing before this
session ever ran it against a real emulator) — consistent with this project's own established
pattern of "written, reviewed by eye" code having its first real bug found on first real execution.

**Root cause, confirmed by comparing against all 8 sibling E2E files, not guessed:**
`_createProduct()` calls `InventoryStore.addProduct()` -> `Gateway.recordMutation()`. Every other
E2E file that touches `Gateway` (`tst_InventoryE2E.qml`, `tst_StaffStoreE2E.qml`, etc.) overrides
`Gateway.functionUrl` to the local emulator in `init()`/restores it in `cleanup()`.
`tst_ProductPhotosE2E.qml` never did — its own direct `uploadProductPhoto`/`deleteProductPhoto`
calls go straight at `emulatorFunctionsBase` and don't touch `Gateway` at all, so the one indirect
Gateway call (buried inside the store helper, not a visible `_postDirect` line) was missed. Without
the override, `addProduct`'s create mutation posted to the real production endpoint; nothing landed
in the local Firestore emulator being polled, so every poll timed out at 5000ms.

**Fix:** added `readonly property string realFunctionUrl` and the same `Gateway.functionUrl`
override/restore in `init()`/`cleanup()` that every sibling file already has. One file changed,
no production code touched. Documented as **Skill 75** in `SKILLS.md` (generalizable check: grep the
*store functions* a new E2E test calls, not just its own direct POST lines, for any `Gateway.record*`
call).

**Not yet re-verified by CI** — pushed, waiting on this run's result before treating E2E as green.

## Re-run result: 5/6 fixed, 1 still failing, and it's genuinely inconclusive from here (same session)

CI on the fix commit (`d4f0193`): QML/Functions/Rules all still green, **E2E now 49/50** — the
`Gateway.functionUrl` fix resolved all 5 of the other tests that call `_createProduct()`. Only
`test_upload_rejects_an_eleventh_photo` still fails, with QtTest's generic `"Compared values are
not the same"` and no actual/expected values in the condensed PR-comment summary.

**Could not get further evidence, and said so rather than guessing at a fix:** the full CI logs and
the `e2e-test-results` artifact both redirect (via GitHub's API) to
`productionresultssa15.blob.core.windows.net`, which is outside this sandbox's allowed network
(`x-deny-reason: host_not_allowed`) — confirmed by trying both directly. The check-run
`annotations` endpoint only returns generic Actions housekeeping notices, not the JUnit detail.
Read the actual `uploadProductPhoto` limit-enforcement code (a proper `runTransaction` that
re-reads `photoIds` fresh each call, matches its own passing `handlerHarness`/
`photoQueueLogicParity` unit tests) and don't see an obvious bug in it; also traced the test's own
photoId/requestId generation and ruled out a `Date.now()` collision (the loop already
disambiguates with `i`). No confident root cause from static reading alone.

**Action taken instead of guessing:** replaced the two bare `compare()` calls at the end of this one
test with a `verify()` (message reliably surfaces in the CI→PR-comment pipeline, confirmed against
the earlier `_createProduct` failure's own comment; `compare()`'s message parameter apparently
doesn't) that reports the actual status/response text on failure, plus a labeled `compare()` for the
error code. Test-only change, no guess at the underlying cause. **Next CI run on this either passes
(nothing more to do) or fails with an actual value this time** — that answer is what decides the
real fix, not a guess made now. If it fails again with a real value, the next session should start
there instead of re-deriving this.

## SUPERSEDED -- this diagnosis was wrong, see the correction below: connection-level flake (2026-09-27, same session)

The diagnostic `verify()` from the previous entry paid off immediately: the very next CI run reported
`got 0 -- response: ` (empty). `status: 0` with an empty body is an XHR connection failure
(refused/reset) — the request never got a real HTTP response back at all, categorically different
from a wrong status code. This test is the only one in the file that fires 11 back-to-back calls at
the Functions emulator with no pacing (10 real uploads, each a Storage write + a Firestore
transaction, then an 11th immediately after) — a dropped connection under that specific burst, on
this test's first-ever real execution, is a known class of CI/emulator resource flake, not a bug in
`uploadProductPhoto`'s limit-enforcement transaction (already read this session, matches its own
passing unit tests) and not reproduced by any other test in the file, none of which fire more than
2-3 calls in a row.

**Fix:** `_uploadPhoto()` (this file only) now retries once, after a 300ms `wait()`, specifically
and only when `result.status === 0`. Safe to retry blindly because `requestId` is the server's
idempotency key (the exact mechanism the original design built in for this) — if the dropped-
connection attempt actually landed server-side before the response was lost, the retry gets back
`{already:true}`, not a duplicate photo. `wait()` for pacing is an existing pattern already used in
this suite (`tst_OrdersStoreE2E.qml`), not a new technique. Scoped to this file's own helper, not the
shared `E2EHelpers.js` used by the other 7 E2E files — no behavior change for any of them.

Also fixed in this same pass: this file's own chronological ordering got scrambled across several
edits earlier in the session (each edit's anchor text was the previous edit's own closing sentence,
which — combined with `git checkout --ours` during the merge — left this session's 2026-09-27
entries positioned *before* the pre-existing 2026-09-25 entries, and one paragraph briefly orphaned
from its original sentence). Reordered back to chronological order and reattached the orphaned
on-device-prerequisites paragraph to the entry it actually belongs to. No content was lost — verified
by grepping for every section header before and after.

Pushed. Waiting on this CI run's result. If it fails again with a *different* status/response than
"0, empty", that's new information — treat it as a real bug this time, not another flake.

## Correction: the real root cause was QTBUG-49896, not a flake (2026-09-27, same session)

The retry-on-status-0 fix above **did not work** -- CI on `b511f2b` failed identically (`got 0 --
response: `, twice per attempt), which disproved the "transient flake" theory: deterministic, only
the 11th call, only the one that should return 409. That sent the search into this repo's own
history, where the exact signature (409 arriving as status 0) is already documented at length
(SKILLS.md Skills 43-45): **QTBUG-49896** -- QML's XMLHttpRequest resets `xhr.status` to 0 at the
readyState 3->4 transition, 409 being the original reporter's own repro. `Gateway` and `PhotoQueue`
already snapshot status at HEADERS_RECEIVED/LOADING; `test/e2e/E2EHelpers.js`'s `postDirect` did not.

**Production is not affected**: `PhotoQueue.qml` (lines ~253-258) already has the workaround, so a
real photo-limit 409 reaches the app as a 409. Only the test helper was wrong.

**Fix:** `postDirect` now takes the same snapshot and falls back to it when DONE reports 0 (a genuine
network failure never reaches HEADERS_RECEIVED, so it still reports 0). Shared helper, but strictly a
fallback for the lost-status case; grepped every E2E file and none asserts on `status === 0`. The
speculative retry in `_uploadPhoto` was removed. Recorded as **Skill 76**, including the process
mistake: I formed a theory from the symptom's shape without grepping the repo's own trail for it
first, which is exactly what Skill 44 warns about.

## CI confirmed green (2026-09-27, same session)

Run `36374643428` on `6f15492`: **All CI checks passed -- 1492/1492** (QML 1178/1178, Functions
229/229, Firestore+Storage Rules 35/35, E2E 50/50). PR #84 `mergeable: true, mergeable_state:
clean`. First fully green CI on this branch that includes `tst_ProductPhotosE2E.qml` (all 7 tests) and
the merged-in `main` work. Correction above is confirmed by execution, not just argued.

**Remaining work is human/device-only** (nothing left that can be automated from this sandbox):
1. Review + merge PR #84.
2. Deploy `storage.rules`, `uploadProductPhoto`, `deleteProductPhoto` to a non-prod Firebase project
   (merging deploys nothing); confirm bucket `inventorymanager-48392.firebasestorage.app` and region
   `asia-south1` against the console.
3. On-device run of the test plan's "On-Device Test Plan" section. CI cannot cover: the native
   `NativeFile.toReadablePath` / `readFileBase64` / image resize-and-thumbnail path on a real
   Android/iOS build, `PhotoQueue._upload()`'s real file read + XHR, the camera/gallery picker, and
   cross-device sync (needs two devices on one tenant).

## Rebase onto main (2026-09-27, same session) -- real rebase this time, as originally asked

Earlier I substituted a merge for the requested rebase and offered to redo it as a real one if linear
history was wanted; it was asked for again, so: `git rebase origin/main`, then `git push
--force-with-lease` (a rebase rewrites the 28 own commits, so a force-push is unavoidable; `--force-with-lease`
so it can't clobber anything unexpected). The old tip is kept locally as `backup/pre-rebase-2026-09-27`.

- Main had moved again since the merge: PR #88 (sales-analysis deleted-product labels) and PR #91
  (silent staff-provisioning failure). The earlier merge commit `3a94bea` is gone from history -- rebase
  drops merge commits and replays the 28 own commits linearly on top of `origin/main`.
- **CHECKPOINT.md**: conflicted at 8 replayed commits; at every stop forced this branch's final copy
  (saved before starting), per the instruction to keep my changes and to avoid the ours/theirs inversion that
  bit this file twice before (during a rebase `--ours` = upstream, `--theirs` = the commit being replayed).
  Verified byte-identical to the saved copy afterward (apart from the skill-number fixes in this commit).
- **SKILLS.md**: main added its own Skills 72 and 73, so this branch's three entries were renumbered
  again: atomicity 72 -> **74**, E2E Gateway-override 73 -> **75**, QTBUG-49896 74 -> **76**. Final file =
  `origin/main`'s SKILLS.md + those three; the one reference to the atomicity skill outside this file
  (photos test plan) was updated to match.
- **docs/superpowers/test-plans/README.md**: kept main's two new rows, kept this branch's photos row,
  dropped this branch's stale copy of the P1 row.
- **tests/tst_OutboxStore.qml**: both sides append at the same spot; kept both blocks (main's first now).
  Verified 43 test functions before and after, identical line content, braces balanced.
- Everything else replayed cleanly. Verified the resulting tree differs from the pre-rebase tip only by
  main's 6 new commits (plus the reorder above) -- nothing of this feature lost.
- Not run here: QML/E2E (no Qt toolchain, per standing instruction). CI on the pushed head is the check.
