# BusinessManagement – Felgo QML App

A cross-platform inventory and business management application built with **Felgo SDK** and **QML**, targeting Android and iOS (with desktop support during development).

---

## Features

| Module | Capabilities |
|--------|-------------|
| **Orders** | Create, view, approve, and track customer orders; stock-checked order completion; batch approval ("Approve all pending" banner: pressed colour, one run at a time, `done / total` progress bar and a short "All approved" hold; logic in `qml/helper/BulkApproveProgress.js`); an order completion that is queued or unconfirmed shows a quiet "Saved. Syncing…" caption in the order dialog until the server answers |
| **Inventory** | Product catalog, stock level tracking, low-stock alerts, restock workflows; multi-photo product gallery synced via Cloud Storage (see "Firebase Configuration" for `storage.rules`) |
| **Sales** | Revenue analytics, order volume charts, top-selling products, cumulative sales metrics |
| **Staff** | Team member management, department distribution, activity feed, leave tracking |

Data is synced to **Cloud Firestore** via a REST API layer (`FirebaseService.qml`), with one
Firestore database per environment (dev/test/prd — see "Environments" below).

---

## Tech Stack

- **Framework**: Felgo SDK (Qt-based cross-platform)
- **Language**: QML + JavaScript
- **Database**: Cloud Firestore (REST, one database per env — dev/test/prd)
- **Build**: CMake 3.16+, Ninja
- **Targets**: Android (min SDK 28, target SDK 34), iOS, Desktop

---

## Project Structure

```
App_UI/
├── CMakeLists.txt          # Felgo build configuration
├── main.cpp                # Felgo application bootstrap
├── assets/                 # Static assets (images, fonts)
├── src/
│   └── main.cpp            # (legacy Qt bootstrap – superseded)
└── qml/
    ├── Main.qml            # Felgo App root: theme → logic → dataModel → navigation
    ├── model/              # Data layer (singletons + orchestrator)
    │   ├── qmldir
    │   ├── DataModel.qml   # Orchestrator, cross-store coordination
    │   ├── OrdersStore.qml
    │   ├── InventoryStore.qml
    │   ├── SalesStore.qml
    │   ├── StaffStore.qml
    │   └── FirebaseService.qml
    ├── logic/              # Signal bus and view utilities
    │   ├── Logic.qml       # Pure signal relay (action dispatcher)
    │   └── ViewHelper.qml  # Formatting helpers
    ├── helper/             # Reusable UI components and constants
    │   ├── qmldir
    │   ├── Constants.qml   # Singleton: colors, breakpoints, URLs
    │   ├── CustomeTheme.qml
    │   ├── CardKPI.qml
    │   ├── StatusBadge.qml
    │   ├── OrderRow.qml
    │   ├── SegmentedNav.qml
    │   ├── InlineDatePicker.qml
    │   └── PlaceholderPage.qml
    └── pages/              # Feature pages and dialogs
        ├── OrdersPage.qml
        ├── InventoryPage.qml
        ├── SalesPage.qml
        ├── StaffPage.qml
        ├── NewOrderDialog.qml
        ├── OrderDetailDialog.qml
        ├── AddProductDialog.qml
        ├── AddStaffDialog.qml
        └── RestockDialog.qml
```

---

## Architecture

The app follows a layered architecture aligned with the **InventoryManagerUI** Felgo pattern:

```
App (Main.qml)
├── CustomeTheme          – global style/color tokens
├── Logic                 – signal bus (pure dispatcher, no logic)
├── DataModel             – state orchestrator, wired to Logic
│   ├── OrdersStore       – order CRUD + Firebase sync
│   ├── InventoryStore    – product CRUD + stock management
│   ├── SalesStore        – aggregated sales metrics
│   └── StaffStore        – staff CRUD
├── ViewHelper            – formatting utilities (currency, numbers)
└── Navigation            – Felgo tabbed navigation
    ├── NavigationItem: Orders   → NavigationStack → OrdersPage
    ├── NavigationItem: Inventory → NavigationStack → InventoryPage
    ├── NavigationItem: Sales     → NavigationStack → SalesPage
    └── NavigationItem: Staff     → NavigationStack → StaffPage
```

### Data Flow

```
User action on Page
  → emits signal via Logic (e.g. logic.addOrder(...))
    → DataModel Connections handler receives signal
      → delegates to appropriate Store
        → Store updates local state + persists to Settings + pushes to Firebase
          → UI binding updates reactively
```

---

## Building

### Prerequisites

- [Felgo SDK](https://felgo.com/download) installed
- CMake 3.16+
- Ninja build system
- Android NDK (for Android builds)

### Development Build (Desktop)

```bash
cmake -S . -B build -G "Ninja"
cmake --build build
```

### Android Build

```bash
cmake -S . -B build-android -G "Ninja" \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-28
cmake --build build-android
```

### Publishing Mode

Before publishing to app stores:

1. Set your Felgo license key in `CMakeLists.txt`:
   ```cmake
   set(PRODUCT_LICENSE_KEY "your-key-here")
   ```
2. In `CMakeLists.txt`, comment `deploy_resources(...)` and uncomment `QML_FILES`/`RESOURCES`
3. In `main.cpp`, switch to the `qrc:/` path:
   ```cpp
   felgo.setMainQmlFileName(QStringLiteral("qrc:/qml/Main.qml"));
   ```
4. Set `PRODUCT_STAGE "publish"` in `CMakeLists.txt`

---

## Firebase Configuration

Cloud Firestore is accessed via its v1 REST API (`FirebaseService.qml`), env-aware — see
"Environments" below for the full dev/test/prd resolution chain.

The database URL is built in `FirebaseService.qml` from the resolved `databaseId`:
```qml
readonly property string databaseUrl:
    "https://firestore.googleapis.com/v1/projects/" + projectId + "/databases/" + databaseId + "/documents"
```

Top-level collections (all tenant-scoped under `tenants/{tenantId}/...`):
- `orders/` – order records
- `inventory/` – product records
- `staff/` – staff member records
- `suppliers/` – supplier records
- `transactions/` – immutable ledger event log (see `AGENTS.md`'s Compliance & Audit Agent)
- `stock_batches/` – FIFO stock batches
- `audit_log/` – compliance gateway's append-only mutation ledger, server-written only
  (`Gateway.recordMutation`/`recordMutations`/`recordDelta` → Cloud Functions). All 5 working-tier
  stores route through it, and it's live — every write goes through it (the `direct` fallback mode was deleted in P1 S2a-2). See
  AGENTS.md §8's "P0 implementation status."
- `locks/` – short-lived pessimistic locks (Component 2 of the async-write-sequencing design,
  below), server-written only. Not part of P0's compliance scope — a concurrency-control aid, not
  ledger data.
- `activity_log/` – staff activity feed
- `config/categories`, `config/orderChannels` – single-document settings, not paginated collections

All six growing collections (`orders`/`inventory`/`staff`/`suppliers`/`transactions`/
`stock_batches`) are read via bounded, cursor-paginated queries — see "Scaling" above and
`SKILLS.md` Skill 32.

**Cloud Storage** (added 2026-09-21, product photos): a product's photos live in Cloud Storage,
not as a URL string on the product doc — `tenants/{t}/inventory/{id}.photoIds` holds up to 10
photo ids (first = cover); the download URL is computed at display time (`qml/helper/PhotoUrl.js`)
from `{env}/tenants/{t}/products/{p}/{photoId}[_t].jpg`, never stored. `storage.rules` (repo root)
allows public read by path (the id is an unguessable random string, and there's no path listing)
and denies every client write — uploads and deletes go through two Cloud Functions,
`uploadProductPhoto`/`deleteProductPhoto`, the same idempotent-on-`requestId` pattern as
`recordMutation`. Deploy `storage.rules` and both functions before this does anything in
production; neither is automatic on merge. Full design:
`docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md`.
Local photo paths (2026-09-28): `ImageProcessor.persistLocalCopy` returns a `file://` URL, not a bare
path. `PhotoUrl.toLocalPath` (for `NativeFile.readFileBase64`) and `PhotoUrl.toFileUrl` (for QML
`Image.source`) accept either form; never concatenate `"file://" +` onto a stored path.
Gallery behaviour (2026-09-29): tiles live in a horizontal `ListView` filmstrip (`qml/components/
ProductPhotoGallery.qml`) with a `+` tile pinned outside it at a fixed position, so it's always
reachable without scrolling — a wrapping `Flow` was tried first (2026-09-28) but its square image
corners visibly overran the rounded tile frame (`clip: true` clips to the bounding box, not the
`radius`); thumbnails are now clipped to their rounded shape with a `MultiEffect` mask
(`qml/components/RoundedThumb.qml`). Only the first confirmed tile shows the cover badge (now a
small corner pill, not a full-width banner); the Edit dialog re-reads
`InventoryStore.photoIdsFor()` on every `InventoryStore.revision` change so a photo that finishes
uploading appears without reopening the dialog.

---

## Configuration

| CMake Variable | Default | Description |
|----------------|---------|-------------|
| `PRODUCT_IDENTIFIER` | `com.lkdigitalworks.business.management.app` | App bundle ID |
| `PRODUCT_VERSION_NAME` | `1.0.0` | Human-readable version |
| `PRODUCT_VERSION_CODE` | `1` | Numeric version for stores |
| `PRODUCT_STAGE` | `test` | `test` or `publish` |
| `PRODUCT_LICENSE_KEY` | _(empty)_ | Felgo license key |

---

## Development Tips

- **Hot Reload**: Uncomment `FelgoHotReload` lines in `CMakeLists.txt` and `main.cpp` for fast QML iteration without recompiling C++
- **Offline seed data**: Each store contains seed data so the app works without Firebase on first launch
- **Responsive design**: `compact: width < 520` breakpoint adapts layouts for mobile screen widths
- **Breakpoints and colors**: Centralised in `qml/helper/Constants.qml` — change once, applies everywhere

---

## Testing

Four independent layers, each with its own CI job in `.github/workflows/checks.yml`:

| Layer | Location | Runner |
|---|---|---|
| QML unit tests (pure logic) | `tests/` | `qmltestrunner -input tests -platform offscreen` |
| Cloud Functions logic | `functions/test/` | `cd functions && npm test` (`node:test`) |
| Firestore + Storage security rules | `test/firestore.rules.test.js`, `test/storage.rules.test.js` (see `FIRESTORE_RULES.md`, `storage.rules`) | `firebase emulators:exec --only firestore,storage` |
| End-to-end (real Store/DataModel code against the real Firebase Local Emulator Suite) | `test/e2e/` | `qmltestrunner -input test/e2e`, seeded via `node test/e2e/seed.js` |

See `AGENTS.md`'s **Testing & QA Agent** section for what each layer actually covers, and
`SKILLS.md` Skill 40 for the E2E layer's specific gotchas (Cloud Functions cold starts, singleton
construction order, per-function emulator URLs) before adding a new scenario there.

**PR status comment:** a fifth job, `pr-comment`, runs after the four above finish (`if: always()`,
`pull_request` events only) and posts a single PR comment summarizing results — pass/fail counts on
green, per-job failing-test name + reason + a direct link to that job's logs on red. Re-pushes
update the same comment (matched via an HTML marker) rather than piling up duplicates. Logic lives
in `.github/scripts/` (`parse-junit.js`, `resolve-job-url.js`, `build-summary.js`,
`post-ci-comment.js`, `skills-index.js`), unit/functional tested independently of any real GitHub Actions run — see
`SKILLS.md` Skill 56, `SKILLS-INDEX.md` (generated from SKILLS.md; `node .github/scripts/skills-index.js --write`) and `docs/superpowers/test-plans/2026-09-02-pr-ci-status-comment-test-plan.md`.

**Update 2026-08-29:** all 8 `functions/index.js` HTTPS handlers now have handler-level test
coverage (auth, request wiring, response-building — not just the `lib/` pure-logic layer the table
above already listed). `recordMutation`/`recordDelta`/`recordMutationsBatch` were covered first
(`functions/test/index.handlers.test.js`, Skill 46); `acquireLock`/`releaseLock`/`provisionMember`/
`runCutover`/`computeAnalysis` — the 5 explicitly deferred at the time — are now covered too
(`index.handlers.remaining.test.js`, Skill 52). `functions/` suite: 164 tests, all passing.
`provisionMember`/`computeAnalysis` had zero coverage anywhere before this, since their logic lives
directly in `index.js` rather than a testable `lib/` module.

**Update 2026-08-30:** `index.handlers.test.js`'s coverage across `recordMutation`/`recordDelta`/
`recordMutationsBatch` is now symmetric (Skill 53) — each has its own 401/403/405/500 case, not
just `recordMutation`. `functions/` suite: 174 tests, all passing. `index.js` line coverage
95.32% → 99.32%; the only two remaining uncovered lines are pre-existing, already-documented
unreachable code (`canAssignRole`'s dead `else` branch, `send()`'s unreachable serialization-failure
catch), not new gaps.

**Update 2026-09-01:** landed PR #49 — `index.js`'s `send()` response helper extracted to
`functions/lib/httpResponse.js` (Skill 55, same pattern as `gatewayLogic.js`),
with direct unit coverage (`functions/test/httpResponse.test.js`, 4 tests) for the
serialization-failure fallback that was previously only reachable via a live HTTPS round trip.
`functions/` suite: 178 tests, all passing. `index.js` line coverage 99.32% → 99.88% — those lines
now live (and are 100% covered) in `httpResponse.js` instead. The one remaining `index.js` gap
(`canAssignRole`'s dead `else`) is unchanged, out of scope here.

**Update 2026-09-02:** fixed a bug — a discount or price edit on a completed order's *taxable*
line left the order's authoritative tax stale (`TransactionStore.recordPriceAdjust` booked revenue
only, no tax delta), and a subsequent full return left a residual fraction of unreconciled
tax/revenue in the order. Bundled in a second, same-root-cause bug found while investigating the
first: `RealisedMath.js`'s Analysis/Reports aggregation (`_accumulatePriceAdjust`) had the
identical gap — a `price_adjust` event contributed revenue/profit/discount to every dimension but
never tax. Both fixed together, in both the QML original and its Node port
(`functions/lib/realisedMath.js`) to keep them byte-identical as designed. 26 new/extended test
cases total across 6 files (11 + 3 new files, 1 + 4 + 3 + 4 extended into existing ones — counted
via `git diff | grep -c`, not carried forward from memory, per Skill 49's own lesson about
re-checking a number rather than trusting it). The Node side could actually be executed in this session (unlike
QML): `node --test test/realisedMath.test.js` → 9/9 passing (4 new), and the full `functions/`
suite → **195/195 passing**, confirming no regression in `computeAnalysis` (the only other
`RealisedMath` consumer). QML-side tests (`tests/tst_TransactionStore_priceAdjustTax.qml`,
`tests/tst_DataModel_discountEditTax.qml`, extended `tests/tst_AdjustDiscountRepro.qml`,
`tests/tst_RealisedMath.qml`, `tests/tst_RealisedMathParityFixtures.qml`) written and hand-traced
against the implementation, plus a `node --check` syntax pass on the stripped `.js` helper files —
still pending a real `qmltestrunner` run via CI, same status as every other QML test in this repo.
See `SKILLS.md` Skill 59 (renumbered from 57 after rebasing onto main) and
`docs/superpowers/test-plans/2026-09-02-price-adjust-tax-delta-test-plan.md`.

---

**Update 2026-09-21:** added the `recordOperation` endpoint (`functions/index.js`, logic in
`functions/lib/operationLogic.js`): it applies a list of delta and mutation ops across several
working-tier docs in ONE Firestore transaction, all-or-nothing, with floors and CAS checked inside,
keyed by a stable `requestId`. A repeat of the same `requestId` returns the first result; a rejection
leaves no trace (no write, no audit entry, no marker), so the same key can be re-planned and resent.
Up to 200 ops per request (401 writes at most); `opType` is allowlisted (`completeOrder`). The
`requestId` must be `{opType}:...` (no `/` or `~`, at most 200 characters) and every entity id must be a
safe document id, so a bad id is a clean 400 rather than a write that fails and is retried forever;
per-op audit entries are `{requestId}~{index}`, which can never equal a marker id. Called from
`DataModel._tryCompleteOrder` as of C-3 phase 3 Task 10 (`docs/superpowers/plans/2026-09-20-atomic-operation-outbox.md`,
spec in `docs/superpowers/specs/`) — the function must be deployed to dev/prod for the client to reach it.
37 new unit tests (`operationLogic.test.js` 23, `index.handlers.recordOperation.test.js` 14);
`functions/` suite: 232 tests, all passing. `operationLogic.js` is 100% line/branch/function covered;
`index.js` stays at 99.89% (the one pre-existing uncovered line, unchanged). Also
`test/e2e/recordOperation.e2e.test.js` (10 tests, run in the E2E job after the QML tests): the same
endpoint against the Firestore emulator's real transaction semantics, including two devices completing at
once (exactly one wins) and concurrent retries of one request id (applied exactly once). Its results are
written next to the QML ones (`results-recordOperation.xml`), so they are counted in the E2E check.

**Update 2026-09-24 (design only, no code, rev 2):** P1 stock movements (CGST 56(2)) will be written **server-side**, inside the
same transaction as every stock change on `inventory`: explicit `movements` on `recordDelta` (signed quantities must sum to the
applied delta) or a server-derived default row (`adjustment`; `sale` inside `completeOrder`; `receipt` on create), so product create,
edit, bulk import and delete cannot bypass the ledger. The `stock_movement` entity will be closed to every client endpoint and
`MAX_BATCH_SIZE` / `Gateway.maxBatchSize` drop 200 -> 150. Everything is dev-only today. Spec:
`docs/superpowers/specs/2026-09-24-p1-server-side-stock-movements-design.md`; plans (S1a, S1b):
`docs/superpowers/plans/2026-09-24-p1-server-side-stock-movements-s1a.md` and `...-s1b.md`; test plan:
`docs/superpowers/test-plans/2026-09-24-p1-stock-movements-test-plan.md`. Roadmap status is in `CHECKPOINT.md`.

**Update 2026-10-16 (P1 slice S1a implemented, server only):** `functions/lib/movementLogic.js` (validate, derive, sum-check, row build) and its
wiring: `recordDelta` and `recordOperation` delta ops now write a server-built `stock_movements` row in the same transaction (client `movements`
must sum to the applied delta, else `409 movement-qty-mismatch`; no `movements` derives one `adjustment`, or `sale` inside `completeOrder`),
operations obey a 500-write budget (`operation-too-large`), `recordMutation` rejects `movements`, and `stock_movement` is no longer a client
entity. Nothing in QML changed. **Needs `firebase deploy --only functions` to dev before any row appears (R3).** Next: S1b (derived rows for
`recordMutation`, batch, mutation ops; batch cap 150).

**Update 2026-10-18 (P1 slice S1b implemented; server + client cap mirror):** `recordMutation`, `recordMutationsBatch` and `recordOperation`
mutation ops on `inventory` now also write a server-derived `stock_movements` row (create -> `receipt`, update/delete -> `adjustment`, a delete
counts as stock going to 0, no stock change = no row), in the same transaction, after the `before` conflict check. So every inventory write
path leaves a ledger row; the rules still let a member write `inventory` directly until S2 (R2). `MAX_BATCH_SIZE` and `Gateway.maxBatchSize`
are now 150 (inventory batch = 3 writes per item = 450). Review decision D-2 is in: `recordMutation`, `recordDelta` and `recordMutationsBatch`
reject a requestId containing `~` or `/` or longer than 200 chars (and the batch rejects such an entityId) with `400 invalid-request-id` /
`invalid-entity-id`, so none can forge a `recordOperation` audit or ledger id (those carry `~`). **Needs `firebase deploy --only functions`
to dev.** S1a/S1b on-device checklists done 2026-10-21 (Taher). S2a-2 done (`direct` mode + `Gateway.mode` deleted, on `feat/2026-10-23-p1-s2a2-delete-direct-mode`). S2c done (`inventory` is read-only to clients in `firestore.rules`, on `feat/2026-10-24-p1-s2c-lock-inventory-rules`; takes effect on `firebase deploy --only firestore:rules`, Rules tests 45 -> 52). Next: S2d, S2e. S2 design (split S2a-S2e, Q1-Q3 approved): `docs/superpowers/specs/2026-10-19-p1-s2-design.md`. **S2f authz hardening (2026-10-24): gateway now trusts the member doc only (S2f-1, PR-A), rules fix for `members` + suspended members (S2f-2, PR-B); plan and findings in `docs/superpowers/specs/2026-10-24-s2f-authz-hardening-design.md`.** **S2b done (server `runCutover` + `cutoverLogic.js` deleted; the client `Gateway.runCutover` was deleted in S2a-1 on `feat/2026-10-21-p1-s2a1-client-cutover-delete`; `direct` mode was deleted in S2a-2). The deployed `runCutover` was deleted by hand in the Firebase console on 2026-10-23 (Taher), so `firebase deploy --only functions` will not ask about it; check with a POST to the old URL, expect `404`.**

**Update 2026-10-26 (S2f-7: `provisionMember` only adds members):** the function that creates staff and invited members writes with the Admin SDK, so `firestore.rules` could not stop it from merging into a member doc that already existed: an admin could demote the owner or a peer admin, a suspended member came back active, and `joinedAt` / `invitedBy` were overwritten. It now reads the target's member doc inside the transaction and only creates; an exact repeat (same role, already active) answers 200 with no write, anything else answers 409 `member-exists`. Role and status changes of an existing member stay on the Team Members path (rules `canManageTarget`). The app cannot reach this endpoint yet (`Gateway.provisioningAvailable` is `false`), so nothing changes on the phone except one clearer message. Needs `firebase deploy --only functions`. Design `docs/superpowers/specs/2026-10-26-s2f7-provision-member-design.md`, test plan `docs/superpowers/test-plans/2026-10-26-s2f7-provision-member-test-plan.md`, Skill 132. Open: membership changes leave no `audit_log` row (KNOWN-ISSUES).

## Qt Skills Cheat Sheet

This repository now includes local Copilot agents mapped from the Qt skills repo:

- `.github/agents/qt-qml.agent.md`
- `.github/agents/qt-qml-review.agent.md`
- `.github/agents/qt-qml-docs.agent.md`
- `.github/agents/qt-cpp-review.agent.md`

Use these ready-to-paste prompts in chat.

### QML implementation prompts

```text
Use @qt-qml to update qml/pages/OrdersPage.qml and add a compact-friendly filter row for Pending/Approved/Completed orders. Keep existing project conventions.
```

```text
Use @qt-qml to implement a reusable low-stock warning banner in qml/helper and integrate it in qml/pages/InventoryPage.qml.
```

### Store + DataModel prompts

```text
Use @qt-qml to add delete-order flow across qml/logic/Logic.qml, qml/model/DataModel.qml, and qml/model/OrdersStore.qml, then wire the action in qml/pages/OrdersPage.qml.
```

```text
Use @qt-qml to add supplier support with a new store and DataModel wiring, following the existing singleton + logic-signal pattern.
```

### Review prompts

```text
Use @qt-qml-review to review all changed QML files in this branch and report only high-confidence findings with file and line references.
```

```text
Use @qt-cpp-review to review CMakeLists.txt and main.cpp for Qt/Felgo correctness and integration risks.
```

### Documentation prompts

```text
Use @qt-qml-docs to generate Markdown docs for qml/pages/OrdersPage.qml and qml/pages/NewOrderDialog.qml.
```

```text
Use @qt-qml-docs to document all components listed in qml/pages/DOCS_CHECKLIST.md and update completion checkboxes.
```

---

## Changed-Files Review Template

Use this helper to auto-generate a review prompt based on currently changed QML files:

```powershell
powershell -ExecutionPolicy Bypass -File .vscode/process/review-changed-qml.ps1
```

Outputs:

- Changed QML file list (staged + unstaged)
- A ready-to-paste `@qt-qml-review` prompt

Optional flags:

```powershell
powershell -ExecutionPolicy Bypass -File .vscode/process/review-changed-qml.ps1 -StagedOnly
powershell -ExecutionPolicy Bypass -File .vscode/process/review-changed-qml.ps1 -UnstagedOnly
```

---

## QML Pages Docs Checklist

Documentation checklist for all page/dialog components is tracked in:

- `qml/pages/DOCS_CHECKLIST.md`

Use it during feature completion to keep docs coverage consistent.

---

## Environments (dev / test / prd)

The app selects its Firestore database at **build time** from `PRODUCT_STAGE` in
`CMakeLists.txt`:

| PRODUCT_STAGE | env  | Firestore database |
|---------------|------|--------------------|
| `dev`         | dev  | `dev`              |
| `test`        | test | `test`             |
| `publish`     | prd  | `(default)`        |

Unknown/unset stage falls back to **prd** (`(default)`), so a misconfigured
release never points at an empty dev database. The resolution chain is
`PRODUCT_STAGE` → `PRODUCT_STAGE_DEF` (CMake compile def) → `APP_STAGE` (QML
context property, set in `main.cpp`) → `EnvConfig.js` → `FirebaseService.databaseId`.
On non-production builds a `DEV`/`TEST` badge shows in Profile settings.

### One-time backend setup (per non-default database)

> **Requires the Blaze (pay-as-you-go) billing plan.** The free Spark plan allows
> only the single `(default)` database; creating named databases returns HTTP 403
> "This API method requires billing to be enabled". Until Blaze is on, build with
> `PRODUCT_STAGE "publish"` (uses `(default)`).
>
> **Region: `asia-south1` (Mumbai), consistently across the whole project.**
> Confirmed via `gcloud firestore databases list --project=inventorymanager-48392`
> that `(default)` is genuinely in `asia-south1` — not `asia-southeast1` as an
> earlier version of this doc and `AGENTS.md` assumed. Cloud Functions
> (`recordMutation`, `provisionMember`, `computeAnalysis`,
> `recordMutationsBatch`; `runCutover` was deleted in P1 S2b) are not yet deployed and have been reconfigured to
> also target `asia-south1`, so DB, Functions, and every named environment
> database live in the same region — data never leaves India, and no
> cross-region latency between Functions and
> Firestore. (A non-default database's region does *not* have to match
> `(default)`'s per Firestore's own rules — we're choosing to match here for
> residency/latency consistency, not because it's required.)
>
> Note: `android/google-services.json`'s `firebase_url` field
> (`...asia-southeast1.firebasedatabase.app`) is the **Realtime Database**
> URL, an unrelated Firebase product this app doesn't use. It was the likely
> source of the earlier asia-southeast1 confusion — ignore it when reasoning
> about Firestore's region.
>
> **Database ids are 4–63 chars** (`[a-z0-9-]`), so `dev` (3 chars) is rejected —
> we use `dev1`. `test` is fine. The `PRODUCT_STAGE`→env→databaseId mapping in
> `qml/helper/EnvConfig.js` (and its mirror in `functions/index.js`) already maps
> the `dev` env to database id `dev1` — if you change the id again, update both.

```bash
firebase firestore:databases:create test --location=asia-south1
firebase firestore:databases:create dev1 --location=asia-south1   # 'dev' is too short
```

Then apply the same security rules (`FIRESTORE_RULES.md`) to each database
(Firebase console → Firestore → select database → Rules, or
`firebase deploy --only firestore:rules` targeting each database).

Auth users, Storage, and Cloud Functions are **shared** across environments —
only the Firestore database differs. `test`/`dev1` start empty (MVP fresh-data).
Since Storage itself has no per-environment split the way Firestore does, product photos rely on
an `{env}` path prefix (`prd`/`test`/`dev1`, via `EnvConfig.storagePrefixForEnv` — see "Firebase
Configuration" above) to keep the three environments' objects from colliding in the one shared
bucket; this is the reason that prefix exists, not an arbitrary choice.

All Cloud Functions (`recordMutation`, `provisionMember`, `computeAnalysis`,
`recordMutationsBatch`; `runCutover` deleted in P1 S2b) resolve their Firestore database **per request** from a client-declared
`env` field (`scopedDb(env)` in `functions/index.js`), mirroring this exact resolution chain — see
`SKILLS.md` Skill 33. This closes a real, confirmed gap: before this fix, every Cloud Function
always read/wrote the `(default)` (prd) database regardless of which env the calling client was
built for.

---

## Scaling: pagination & server-side analytics

Two problems, fixed separately (full design: `docs/superpowers/specs/
2026-07-06-scale-reads-writes-analytics-design.md`):

- **Reads** — every growing collection (`inventory`, `orders`, `staff`, `suppliers`,
  `transactions`, `stock_batches`) now pages in bounded chunks via `FirebaseService.query()`
  (Firestore's `:runQuery`, cursor-based) instead of one unbounded `get()`, which silently
  truncated once a collection crossed Firestore's internal response-size threshold. All six
  currently auto-page to exhaustion (full local data, same app behavior — several of them are read
  by correctness-critical logic today, like FIFO stock consumption and Dashboard KPIs, that assumes
  the complete set; see the spec §3.1 for why a "recent window" isn't safe for those yet). See
  `SKILLS.md` Skill 32.
- **Writes** — `OrdersStore`, `StaffStore.addStaff`, and `ActivityLog` used to rebuild their entire
  collection into one bulk Firestore commit on every single-record mutation, which hard-fails past
  Firestore's 500-write-per-commit cap. Fixed to single-doc writes. See `SKILLS.md` Skill 12.
  **Superseded 2026-07-11**: every store's mutations (`Inventory`/`StockBatch`/`Orders`/`Staff`/
  `Supplier`) now route through the compliance gateway (`Gateway.recordMutation`/`recordMutations`
  — see AGENTS.md §8, `SKILLS.md` Skill 35) instead of calling `FirebaseService` directly.
  `approveAllPending`'s bulk update specifically now uses `Gateway.recordMutations` (one atomic
  transaction, capped at 150 items since P1 S1b) — the old `FirebaseService.putMany()` call there is gone.
  Functionally live as of 2026-07-29 (the only mode; `direct` was deleted in P1 S2a-2), and this is the current code
  path, not the one described just above. As of the async-write-sequencing design (below),
  `InventoryStore.deductStock`/`StockBatchStore`'s FIFO functions route through
  `Gateway.recordDelta` instead — an atomic server-side delta, not a client-computed absolute value
  — for the same reason `approveAllPending` needed a batch endpoint: naive per-write races.
- **Analytics** — a new `computeAnalysis` Cloud Function runs Revenue/Profit/Sold/Purchased
  aggregation server-side (ported `RealisedMath`/`BreakdownMath`, parity-tested against the QML
  originals via shared fixtures), so this no longer needs the full transaction ledger resident on
  the phone. `AnalysisService.qml` is the client for it. **Not yet wired into `SalesPage.qml`** —
  that page currently calls the local `InventoryStore.realisedProfitByDimension`/etc. adapters
  synchronously at 15+ call sites, and `AnalysisService.compute` is necessarily async, so the
  cutover is a real rewrite of that page's data flow, deferred as its own future project (spec §9.1).
  See `SKILLS.md` Skill 34.

---

## Concurrency & Conflict Resolution

Full design: `docs/superpowers/specs/2026-07-29-async-write-sequencing-design.md`. Four pieces,
addressing three separate bugs found while investigating one reported symptom (an order silently
reverting from "completed" to "pending"):

- **Client single-flight-per-record** (`OutboxStore`/`Gateway.qml`) — a device's own outbox no
  longer fires overlapping writes at itself for the same record; a second write arriving while the
  first is still in flight coalesces into a held follow-up instead of racing it.
- **Pessimistic record locking** (`locks/` collection, `Gateway.acquireLock`/`releaseLock` Cloud
  Functions, `LockManager.qml`) — proactive cross-device conflict avoidance: opening an editable
  dialog (product, staff, order) acquires a lock first, so a second device finds out immediately
  rather than doing real edit work only to be rejected at save time. TTL + client renewal, no
  cleanup job — an abandoned session just expires.
- **Server-side compare-and-swap** (`applyMutation` in `gatewayLogic.js`) — a backstop, not the
  primary mechanism now that locking exists: rejects a mutation whose `before` doesn't match the
  record's actual current state, instead of blindly overwriting.
- **Atomic server-side deltas** (`applyDelta`, `Gateway.recordDelta`) — quantity fields
  (`inventory.stock`, `stock_batch.qtyRemaining`/`qtyReceived`) are adjusted by a server-computed
  delta inside the Firestore transaction, not a client-computed absolute value — two legitimate
  concurrent stock movements on the same product both apply correctly instead of one clobbering
  the other. Supports either rejecting (`floors`) or clamping (`clamps`) at a boundary, per caller.

**Update 2026-08-08:** the 5 Important findings from the 2026-08-06 review (I1-I5) plus 2 known
gaps and 1 newly-discovered gap are now all closed too (`fix/async-write-sequencing-review-fixes`
branch, design: `docs/superpowers/specs/2026-08-08-review-round2-design.md`):
- `functions/lib/batchMutationLogic.js`'s `applyMutationsBatch` now has a CAS check, matching
  `applyMutation`'s — this is the live path for every bulk import (Supplier/Order/StockBatch/
  Inventory/Transaction), not dead code as it first appeared. Whole batch rejects on any item
  conflicting, matching the module's own all-or-nothing design. The client (`Gateway._sendBatch`)
  now handles the resulting 409 the same way `_send` already handles a single-item conflict, reusing
  the same `mutationConflicted` signal every store already listens to.
- `StockBatchStore.consumeFifo`/`topUpOldest`/`restoreFifo` are now `recordDelta`-based (full async
  rewrite, not the smaller mechanical-swap alternative — chosen to close the per-batch attribution
  race under concurrency, not just the CAS-clobber risk). Rippled into `DataModel.qml`'s three
  retry-loop call sites and forced `completeImportedOrder` off its prior synchronous
  `return {ok, understocked}` contract.
- Bulk order approval (`OrdersPage._approveAllPending`) now acquires the per-order lock before
  completing each order, same as `OrderDetailDialog`.
- `acquireLock`/`releaseLock` now validate `entity` against the known allowlist (previously any
  string was accepted).
- All 3 dialogs' (`OrderDetailDialog`, `EditProductDialog`, `StaffDetailDialog`) "try again"
  lock-denial message now actually retries the lock acquisition, instead of re-showing the same
  stale message forever.

**Update 2026-08-27:** `StockBatchStore`'s batch-id minting (`BAT-<year>-NNN`) now closes the same
class of gap Staff/Supplier/Order/Product ids already had closed — a real Firestore-transaction-backed
counter (`counters/stockBatches-<year>`, year-scoped so the existing per-year reset stays intact)
instead of a local-array max-scan, which wasn't safe under concurrent access. Design:
`docs/superpowers/specs/2026-08-27-async-stock-batch-id-minting-design.md`; lesson: SKILLS Skill 50.
- `ConfirmReturnSheet` now holds the order lock through the user's actual confirm/cancel decision,
  not just until `OrderDetailDialog` closes.
- The partial-multi-line-completion gap (one line's successful stock deduction staying applied when
  a sibling line's fails) is fixed at both sites it occurs: `_tryCompleteOrder` and
  `_tryAdjustOrder`'s exchange path.

See SKILLS Skill 36's 2026-08-08 section for the reusable lessons from this round.

_Removed 2026-10-06 (each lesson lives in SKILLS.md, original text in git history): the 2026-08-06/10/12 concurrency fix notes (post-restart sync race, dual-trigger reset: Skills 36-39), the 2026-08-29 bulk-import chunking, 2026-09-14 order-completion double-submit, 2026-08-11 ledger-sync, 2026-09-16 busy-guard retest, 2026-09-19 stuck-writes and 2026-09-25 deleted-staff notes (Skills 57, 61, 38, 66, 67, 70). Find any skill with `grep -i keyword SKILLS-INDEX.md`._

**Update 2026-07-30:** `DataModel._tryAdjustOrder` (order returns/exchanges) now gets the same
async-await treatment `_tryCompleteOrder` got — added-unit stock deductions are confirmed before
the adjustment is finalized, reported honestly via callback instead of always claiming success.
Returns and price/discount changes stay synchronous (no network dependency). Known limitation kept
from the original scoping, **narrowed as of 2026-08-06**: the FIFO batch consumption itself now
rolls back correctly on a rejected delta (see above) — what's still explicitly out of scope is the
broader order-level side effects (refund amounts, price-adjustment ledger entries) not rolling
back; full compensating-write rollback across the whole multi-step flow remains a separate
initiative (§2 of the design doc), not something either fix round attempts.

**Resolved, list corrected 2026-10-13** (each item was re-read in the code that owns it; this block still called them open):
- `StockBatchStore.consumeFifo` / `topUpOldest` / `restoreFifo` go through `Gateway.recordDelta` (the only `recordMutation` left in the store is the batch `create`). Fixed 2026-08-26.
- `recordMutationsBatch` (`functions/lib/batchMutationLogic.js`) has a CAS check: it compares every item's `before` and returns 409 with all conflicts.
- Bulk order approval locks each order (`OrdersPage._approveAllPending` calls `LockManager.acquire("order", ...)`).
- `ConfirmReturnSheet` owns the order lock until it closes (`onClosed` releases; `OrderDetailDialog` hands the lock off).
- A sibling-line stock failure no longer leaves the successful line applied: `_tryCompleteOrder` is one atomic operation (PR #90) and `_tryAdjustOrder`'s exchange path has its own compensation.

**Also found and fixed 2026-07-30 (Taher's own testing, then confirmed via
`/superpowers:systematic-debugging`):** two real bugs, more serious than either sounds in
isolation —
1. `LockManager`/`Gateway._sendDelta` treated ANY failed request (including an undeployed Cloud
   Function's 404) as if the server had made a real decision, showing a lone tester a false
   "someone else is editing this" message and silently stranding orders at "pending" forever.
   Fixed by extracting pure `_classify*Response()` functions that only treat a response as
   decisive when it's actually valid JSON matching this app's own envelope shape.
2. `OrdersStore._clone()`'s field-reconstruction whitelist didn't match `addOrder`'s create
   payload — `adjustments` got silently added, `updatedAt` got silently dropped, on the very next
   clone after any order was created. This meant Component 3's CAS check would reject a
   completely ordinary single-user edit as a false conflict on the second touch of nearly every
   order, once live — not a rare race, closer to a certainty. Fixed with a single
   `_normalizeOrder()` used by both functions; audited all 4 other stores for the same pattern
   (only Orders had it — see SKILLS Skill 36 for the full mechanism and why the other stores were
   already safe).

**Update 2026-09-16 (NewOrderDialog double-submit, C-2):** after fixing the completion instance
above, a sweep for the same bug *pattern* elsewhere in the app
(`docs/superpowers/ASYNC-REENTRANCY-BUGS.md`) found the same shape on order **creation**:
`NewOrderDialog.trySubmit()` had no `busy` guard at all and called `dlg.close()` immediately after
firing the `orderCreated` signal — no wait for `OrdersStore.nextOrderId`'s real, server-coordinated
mint to resolve. Easier to hit than the original bug: a plain fast double-tap on "Place order" (no
need to reopen anything, no slow connection required) minted two separate orders, and — with
auto-approve on — double-deducted stock too, since both duplicates got auto-completed. Unlike
completion, there's no second call path into `OrdersStore.addOrder` for a `DataModel`-layer guard to
protect (no `_approveAllPending`-equivalent for creation), so this fix is entirely UI-layer:
`if (busy) return` + `busy = true` before the emit, and a `Connections { target: logic }` block
waiting for a real `orderAdded` (success) or the newly added `orderCreationFailed` (failure) signal
before closing — mirroring `OrderDetailDialog`'s PR #70 pattern. `orderCreationFailed` is new
(`Logic.qml`): the prior failure path used the shared generic `errorOccurred` bus, which carries no
correlation to which request failed and so isn't safe to gate a dialog's own `busy` reset on. See
SKILLS Skill 65 and the tracker doc's F-2 entry.

**Update 2026-09-21 (staff delete button, plus two adjacent gaps found while tracing it):**
`StaffPage` had the identical missing-row-button gap products and orders had before
`feature/product-order-delete-ui` — every piece of plumbing (`deleteStaffClicked`, the confirm dialog,
`DataModel.onDeleteStaff`, `StaffStore.deleteStaff`) already existed, so this is the same proven fix a third
time (`DELETE-FEATURE-ROADMAP` item 2). Along the way: `StaffStore._onMutationConflicted` gained the
delete-specific toast wording products/orders already have (deliberately deferred earlier since it was
unreachable without this button); a guard now blocks deleting your own staff record (dormant until login
provisioning ships — `Gateway.provisioningAvailable` is still `false` — but a self-lockout otherwise becomes
possible the day it does); and `functions/index.js`'s `recordMutation` now checks role for staff/delete
specifically, since the client-side check alone was not a trust boundary. That last fix is narrow on purpose —
every other entity/action still has no server-side role check, tracked as its own `KNOWN-ISSUES.md` entry
rather than fixed piecemeal here. See SKILLS Skill 68 and
`docs/superpowers/specs/2026-09-21-staff-delete-ui-design.md`.

**Update 2026-09-26 (Sales Analysis stops mislabeling a deleted product's history):** Purchased, Sold, Revenue
and Profit's Realised sub-mode used to dump a deleted product's historical rows into "(uncategorised)" and a raw
product id instead of its real category/name (`DELETE-FEATURE-ROADMAP` item 3, first documented 2026-09-02).
Traced to two different-sized bugs: `productName` was already stamped on every `TransactionStore` entry at
creation time, so the by-name half was a small read-side fix; `category` was genuinely never stamped anywhere,
so that half got the write-path change originally scoped — `recordPurchase`/`recordCreated`/`recordSaleFromOrder`
now stamp it, and `recordReturn`/`recordPriceAdjust` reuse the *original sale's* stamped category, since the
product a return references may already be deleted by return time. Read side (`BreakdownMath.js`/
`RealisedMath.js`) prefers the stamp only once the live product is confirmed gone — a still-existing,
recategorized product's history keeps showing its current category, unchanged. Applied identically to the
server-side parity port (`functions/lib/`), which had the same bug and is a live Cloud Function
(`computeAnalysis`) reading the same Firestore collections. A real precedence bug in the first pass of this fix
was caught by the Node test suite actually failing, not by tracing — see SKILLS Skill 72. Design:
`docs/superpowers/specs/2026-09-26-sales-analysis-deleted-product-labels-design.md`; test plan:
`docs/superpowers/test-plans/2026-09-26-sales-analysis-deleted-product-labels-test-plan.md`.

**Update 2026-09-29 (stuck state survives a relaunch, part B slice S2a):** the stuck-write state was in memory only, so closing the app hid the header line and the dialog rows, and because the outbox keeps its 10-minute backoff the alarm could stay dark for 40+ minutes. `Gateway` now saves each write's failure count, stuck flag and rejected label on its queued outbox item, restores them at launch (`Gateway.resumeStuck`, header line back before any retry, no toast), and re-checks stuck writes once at launch instead of waiting out the backoff. Park / Discard are still to come (S2b, S3). See SKILLS Skill 88 and `docs/superpowers/test-plans/2026-09-29-stuck-state-persist-s2a-test-plan.md`.

**Update 2026-09-28 (server write-error classification, roadmap item 1 part C):** every failed Firestore write is
now classified by `functions/lib/writeError.js` (`classifyWriteError`) into `write-rejected` (invalid-argument,
not-found, already-exists, permission-denied, failed-precondition: retrying can never succeed), `write-unavailable`
(deadline-exceeded, resource-exhausted, aborted, internal, unavailable) or `write-failed` (anything else). The HTTP
status stays 500 on purpose: the delta and operation senders drop a write on any 4xx (SKILLS Skill 84). `Gateway`
reads `body.error` only to label: `StuckWrites` tracks the server's latest answer per write, `Gateway.stuckTerminalCount`
feeds `syncStuckTerminalCount` in `Main.qml`, and `GlassHeader` shows "N change(s) rejected by the server. Still
retrying." Retry, backoff and dropping are unchanged. Test plan:
`docs/superpowers/test-plans/2026-09-28-gateway-write-error-classification-test-plan.md`.

**Update 2026-10-13 (cause of a failed order completion):** the stuck-writes sheet now shows WHY a write is stuck
(`FailureCause.forWriteError`, from the latest `{code, status}` that `StuckWrites` keeps and `OutboxStore` persists), and a
completion that was shown as done while offline but later fails for good raises one toast naming the customer and the cause
(`Logic.orderCompletionReverted`). Completion rows are labelled by customer, not by a stock batch id. Client-only: no server
change, no deploy. Design: `docs/superpowers/specs/2026-10-13-completion-error-cause-design.md`; test plan:
`docs/superpowers/test-plans/2026-10-13-completion-error-cause-test-plan.md`.

**Update 2026-10-26 (pending batch-id mints are tenant-scoped):** the durable queue of failed batch-id mints survived
sign-out but did not know its tenant, so a retry after another account signed in could write a batch into the wrong
tenant and hide the wrong product from order pickers. Items now carry their tenant (`qml/helper/PendingMints.js`),
only that tenant retries or sees them, and a result that arrives under another tenant is dropped (the success path of `addBatch` too). The retry waits until the tenant's batch ledger is loaded, and items the loader cannot replay are quarantined, not destroyed. Client-only. Design:
`docs/superpowers/specs/2026-10-26-pending-mints-tenant-scope-design.md`; test plan:
`docs/superpowers/test-plans/2026-10-26-pending-mints-tenant-scope-test-plan.md`.

**Update 2026-10-26 (sign-out guard, S0):** signing out or leaving a workspace used to drop every queued write and photo
upload with no word (`Main.qml onSignedOut` clears `Gateway` and `PhotoQueue`). `Main.qml askLeave()` now shows
`SignOutSheet` when anything is queued: the rows (labels from `DescribeItem`, state Waiting / Sending / Needs attention),
what is lost, **Stay signed in** as the primary button and a red **Sign out and discard**; with nothing queued the plain
confirm is unchanged. Warn-and-allow, not block (Taher, Q-A6). Client-only, no deploy. Design:
`docs/superpowers/specs/2026-10-26-signout-guard-design.md`; test plan:
`docs/superpowers/test-plans/2026-10-26-signout-guard-test-plan.md`.

**Update 2026-09-29 (stuck-writes dialog + Retry now, part B slice S1):** the `GlassHeader` stuck caption is now
underlined and tappable while online. It opens `StuckWritesSheet` (`qml/pages/`), one row per stuck write
(`Gateway.stuckRows()`, labels from `qml/helper/DescribeItem.js`) with a "Retry now" button. `Gateway.retryStuck`
calls `OutboxStore.retryNow` (attempts reset to 0, due immediately) and drains; the write stays flagged stuck until it
actually leaves the outbox, so a retry the server rejects again keeps the header line up and never re-toasts. No
parking, persistence or Discard yet (slices S2/S3). Design:
`docs/superpowers/specs/2026-09-29-stuck-writes-dialog-retry-now-design.md`; test plan:
`docs/superpowers/test-plans/2026-09-29-stuck-writes-dialog-retry-now-test-plan.md`.

**Update 2026-09-21 (C-3 phase 2, pure helpers):** added `qml/helper/SendPolicy.js` (10s foreground / 30s
background timeout starting values, not measured, and +-20% retry jitter), `OperationKeys.js`
(deterministic operation key and ids) and `CompletionPlan.js` (the pure planner that turns an order
completion into the write list), and taught `StuckWrites` that a timeout counts while the device is
online. Nothing calls them yet; `Gateway` and `DataModel` are wired once `recordOperation` (PR #78) is
deployed. 47 new headless tests. Plan: `docs/superpowers/plans/2026-09-20-atomic-operation-outbox.md`.

**Update 2026-09-25 (C-3 phase 3 PR 1, transport, PR #83):** `OutboxStore.enqueueOperation` + per-key
`dueItems()` ordering/jitter, and `Gateway.recordOperation` (await mode, `operationApplied`/
`operationRejected` signals, a settled-flag `Timer` per sender for the send timeout — not the phase 2 plan's
original shared-`_xhrPost` design, which was rejected as too risky against the real, more elaborate
`_send`/`_sendBatch`/`_sendDelta`). 32 new tests, verified in real CI. **Still nothing calls `recordOperation`
from `DataModel`** — see the next entry and `CHECKPOINT.md`.

**Update 2026-09-26 (C-3 phase 3 Task 9, store hooks):** added the local-only hooks each store needs so a
future atomic completion can plan against current state and later reconcile a server result, without any of
them sending anything themselves: `InventoryStore.applyRemoteStock`, `StockBatchStore.applyRemoteQty` /
`addLocalBatch` / `removeLocalBatch`, `OrdersStore.buildOrderUpdate` (the pure half of `updateOrder`, plus a
new `completionEpoch` order field) / `applyRemoteOrder`, `TransactionStore.buildSaleDocs` (the pure half of
`recordSaleFromOrder`, with a deterministic-id mode) / `addLocalEntries` / `removeLocalEntries`. 56 new tests.
Found and fixed one real bug while extracting these: `OrdersStore._normalizeOrder` silently drops any field
not in its literal, which would have quietly discarded `completionEpoch` on every order edit after the one
that set it (SKILLS Skill 71).

**Update 2026-09-26 (C-3 phase 3 Task 10, `DataModel._tryCompleteOrder` rewrite), after a design check-in
with Taher:** `_tryCompleteOrder` now sends one atomic `completeOrder` operation instead of the old per-line
FIFO-consume + deduct-stock chain (and its compensation logic — nothing left to compensate once the server
transaction is atomic). Keeps its signature, guard, and `stockErrorMsg`/`out of stock` behaviour. `maxReplans`
stays 3; a completion queued offline (or whose await window elapses) still shows as `completed` immediately,
per Taher's call in the check-in. One addition beyond the original plan draft, also from that check-in:
reopening an order while its completion is still open is now handled — `_reverseCompletedOrder` clears the
open-completion bookkeeping so a deferred server answer for a superseded completion can't re-apply the
original sale onto the reopened order. 20 test functions (`tests/tst_DataModel_completeOrderAtomic.qml`, counted with grep; the last 3 added in the 2026-10-13 sweep pin the Discard-of-a-parked-completion fix, Skill 115); the
existing `tst_DataModel_completeOrderReentrancy.qml` needed its "still in flight" test setup changed (not
just re-verified) since the new code resolves synchronously in cases where the old per-XHR chain used to hang
forever in this harness — see that file's header and SKILLS Skill 114. Written and pushed; CI result not yet
seen by this session (see `CHECKPOINT.md`).

---

**Update 2026-09-30 (rejected writes are parked, part B slice S2b):** a write the server has rejected (`write-rejected`) and that is already stuck no longer retries on its own: it is paused, the header says "N change(s) rejected by the server. Tap to retry.", and the dialog row has a Retry button. A rejected retry parks it again after one attempt; other stuck writes (outages) keep retrying. Later writes for the same record wait behind a parked one. Discard comes next (S3). See SKILLS Skill 89 and `docs/superpowers/test-plans/2026-09-30-s2b-park-terminal-writes-test-plan.md`.

**Update 2026-10-01 (rejected writes can be discarded, part B slice S3):** a parked write (the server rejected it) now has a Discard button in the "Changes not syncing" sheet, shown only for rejected rows and enabled only while online. A confirm explains that the change and any later edits to the same record are removed for good; then the app reloads the affected lists from the server so they match it again. Anything waiting on that write is told it was discarded. Known gaps: the name cache of a discarded staff removal refreshes on relaunch; queued photos of a discarded product create fail (roadmap item 4); there is still no verified way to force a real rejection on a device. Design: `docs/superpowers/specs/2026-09-30-s3-discard-resync-design.md`; test plan: `docs/superpowers/test-plans/2026-10-01-s3-discard-parked-writes-test-plan.md`.

**Update 2026-10-01 (final sweep of PR #110, Discard):** review found no functional bug in the discard path; fixes were copy only (the sheet row and the header line now say "Retry or Discard") plus one internal refactor. The device test plan now starts with a prerequisites section (environment, data, how to make a write get stuck, wait times) and the way to force a real server rejection (oversize Description) is now confirmed on device. See SKILLS Skill 91 and `docs/superpowers/test-plans/2026-10-01-s3-discard-parked-writes-test-plan.md`.


**Update 2026-10-05 (unsynced product edits, PR #121 follow-up):** when you edit a product, its history rows ("Selling: 25 to 30", stock adjustments) and the "Product updated" activity entry now appear only after the server has accepted the edit; if the server rejects the edit they never appear. While a product has an edit that has not synced yet, an order containing it cannot be completed ("This product has a change that hasn't synced yet. Wait for it to sync first").  Test plan: `docs/superpowers/test-plans/2026-10-05-unsynced-edit-ledger-test-plan.md`.

**Update 2026-10-05 (PR #122):** a product edit that has not synced now stays visible after you close and reopen the app, the product card shows a "Not synced" (or "Rejected", if the server refused it and it needs Retry or Discard) badge, and the edit dialog says so. A product bigger than 1 MiB (in practice a very long description) is refused on the spot with a message instead of being queued and retried. Still to do: the same history-row rule for the other kinds (restock, photo, sale, return, price adjustment), which is planned together with the atomic-operation work.
