# BusinessManagement – Felgo QML App

A cross-platform inventory and business management application built with **Felgo SDK** and **QML**, targeting Android and iOS (with desktop support during development).

---

## Features

| Module | Capabilities |
|--------|-------------|
| **Orders** | Create, view, approve, and track customer orders; stock-checked order completion; batch approval |
| **Inventory** | Product catalog, stock level tracking, low-stock alerts, restock workflows |
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
  stores route through it, and it's live — `Gateway.mode` is `"gateway"` (flipped 2026-07-29). See
  AGENTS.md §8's "P0 implementation status."
- `locks/` – short-lived pessimistic locks (Component 2 of the async-write-sequencing design,
  below), server-written only. Not part of P0's compliance scope — a concurrency-control aid, not
  ledger data.
- `activity_log/` – staff activity feed
- `config/categories`, `config/orderChannels` – single-document settings, not paginated collections

All six growing collections (`orders`/`inventory`/`staff`/`suppliers`/`transactions`/
`stock_batches`) are read via bounded, cursor-paginated queries — see "Scaling" above and
`SKILLS.md` Skill 32.

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
| Firestore security rules | `test/firestore.rules.test.js` (see `FIRESTORE_RULES.md`) | `firebase emulators:exec` |
| End-to-end (real Store/DataModel code against the real Firebase Local Emulator Suite) | `test/e2e/` | `qmltestrunner -input test/e2e`, seeded via `node test/e2e/seed.js` |

See `AGENTS.md`'s **Testing & QA Agent** section for what each layer actually covers, and
`SKILLS.md` Skill 40 for the E2E layer's specific gotchas (Cloud Functions cold starts, singleton
construction order, per-function emulator URLs) before adding a new scenario there.

---

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
> (`recordMutation`, `provisionMember`, `runCutover`, `computeAnalysis`,
> `recordMutationsBatch`) are not yet deployed and have been reconfigured to
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

All 5 Cloud Functions (`recordMutation`, `provisionMember`, `runCutover`, `computeAnalysis`,
`recordMutationsBatch`) resolve their Firestore database **per request** from a client-declared
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
  transaction, capped at 200 items) — the old `FirebaseService.putMany()` call there is gone.
  Functionally live as of 2026-07-29 (`Gateway.mode` is `"gateway"`), and this is the current code
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
- `ConfirmReturnSheet` now holds the order lock through the user's actual confirm/cancel decision,
  not just until `OrderDetailDialog` closes.
- The partial-multi-line-completion gap (one line's successful stock deduction staying applied when
  a sibling line's fails) is fixed at both sites it occurs: `_tryCompleteOrder` and
  `_tryAdjustOrder`'s exchange path.

See SKILLS Skill 36's 2026-08-08 section for the reusable lessons from this round.

**Update 2026-08-12:** Taher found this himself, on-device, immediately after the 2026-08-11 guard
shipped and still didn't reliably catch the sync-incomplete window — no "still syncing" message on
a prompt post-restart return, and Orders/Inventory screens showing inconsistent data that
self-resolved given enough time. Root cause: `TransactionStore.Component.onCompleted` and `Main.
qml`'s `onTenantContextReady` both call `_resetAndFetch()` on a cold start — both async, and since
nothing gated a second call while the first was still mid-fetch, whichever landed second wiped
`entries`/`_cursor` out from under the first, corrupting the rest of that pagination chain and
leaving `hasMore` able to read `false` while `entries` was genuinely still incomplete — which is
exactly why the 2026-08-11 guard (which only checks `hasMore`) didn't catch it. Fixed with
`if (loadingMore) return` at the top of `_resetAndFetch()`, applied to every paginated store, not
just `TransactionStore` (`InventoryStore`, `OrdersStore`, `StaffStore`, `StockBatchStore`,
`SupplierStore`). A follow-up full sweep of all 21 `qml/model/*.qml` singletons found three more
stores sharing the same dual-trigger exposure (`ActivityLog`, `CategoryStore`, `OrderChannelStore`)
— structurally immune to the corruption itself (single bounded fetches, not multi-page pagination),
but missing the same `AuthStore.tenantId.length > 0` guard on `Component.onCompleted` that every
other store already had, fixed for consistency. See SKILLS Skill 39 for the full sweep table and a
documented, not-yet-implemented residual edge case around account-switch timing.

**Update 2026-08-11:** found immediately after the fix directly above, testing the same branch —
complete an order, verify it in Firestore, close the app, reopen it, and return an item promptly:
the return "succeeded" locally, but the Orders list total didn't reduce and order-level history
looked incomplete. Root cause was different from 2026-08-10 despite the similar symptom:
`OrdersStore.applyAdjustment`'s completed-order total trusts `TransactionStore.totalsForOrder`
unconditionally, and `TransactionStore` re-fetches its entire transaction history from Firestore on
every cold start, paginated, ordered ascending by document ID — and because transaction IDs are
locally generated with an embedded, increasing timestamp, that means the NEWEST transactions
(including a just-completed order's own sale) load LAST. Acting before that sync finished meant
computing the ledger total against data that was missing its own base sale event. Verified this
wasn't an arithmetic bug by Node-porting the actual allocation/ledger-sum logic (both are portable
`.pragma library` JS) against three scenarios (simple, tax+discount+multi-line, sequential returns)
— all correct given a complete ledger. Fixed by refusing completed-order adjustments while
`TransactionStore.hasMore` is true (checked in `DataModel._tryAdjustOrder`, which both the normal
return flow and the import-adjustment path route through, plus proactively in
`OrderDetailDialog._save()` so the user finds out before filling out the whole return form) —
scoped to that one action specifically (`grep -rn "totalsForOrder(" qml/` turns up exactly one
caller), not a blanket "block the whole app while any store syncs," since order completion and
everything else here don't read this ledger at all. Also added retry-with-backoff to
`TransactionStore`'s sync — without it, a single failed page left `hasMore` stuck at `true` forever,
which would have turned the new guard into a permanent lockout after one dropped request instead of
a brief, correct wait. See SKILLS Skill 38 and `docs/superpowers/specs/
2026-08-11-ledger-sync-race-CHECKPOINT.md` for the full investigation.

**Update 2026-08-10:** found via Taher's own manual testing of the round-2 branch — a real order
edit (add, complete, adjust price, save) hit a spurious "updated elsewhere" conflict toast with
nobody else touching the order. `OrdersStore.applyAdjustment` built its CAS `before` snapshot as a
shallow copy of the order, then mutated a nested field (`adjustments`) in place with `.push()` —
since a shallow copy shares nested arrays by reference, that mutation leaked into `before` too, so
the server's `_deepEqual(current, before)` check rejected the write (the whole write, not just the
adjustment — nothing persisted, including the price change). Fixed by reassigning a new array
(`.concat()`) instead of mutating the existing one in place, matching the replace-don't-mutate
convention already used everywhere else in this codebase for this exact reason. A full sweep of
every `Object.assign` call site in the project (25 total) confirmed this was the only instance of
the pattern — see SKILLS Skill 37 and `docs/superpowers/specs/
2026-08-10-before-snapshot-aliasing-CHECKPOINT.md` for the full investigation.

**Update 2026-08-06:** a dedicated code review (`docs/superpowers/specs/
2026-08-06-async-write-sequencing-code-review.md`, 8 Critical + 5 Important findings) found every
mechanism above was individually correct but not fully wired end-to-end — the server-side CAS
backstop, for instance, was fully implemented and tested, but the client never actually handled its
409 conflict response, so a real conflict retried forever instead of resolving. All 8 Critical
findings are now fixed:
- The client now handles a CAS conflict properly: `Gateway.mutationConflicted(entity, entityId,
  current)` fires when a write is dropped (not retried) due to a conflict, and all five stores that
  call `recordMutation` (`OrdersStore`, `InventoryStore`, `StaffStore`, `SupplierStore`,
  `StockBatchStore`) reconcile their local cache from `current` and notify the user.
- `InventoryStore.restock`/`creditStockNoBatch` are now genuinely converted to `recordDelta` (a
  prior checkpoint had asserted `restock` was already converted — it wasn't).
- `firestore.rules` now denies client read/write on the `locks/**` collection — previously
  unenforced, despite the design calling for it; any client could read/write lock documents
  directly, bypassing `acquireLock`/`releaseLock` entirely.
- `StockBatchStore.consumeFifo`/`topUpOldest` now roll back via `restoreFifo` when the
  corresponding stock delta is rejected, in both `_tryCompleteOrder` and `_tryAdjustOrder` — FIFO
  batches no longer stay decremented for units no completed sale/exchange accounts for.
- `LockManager._classifyAcquireResponse` is now status-aware (only a real 409 means "someone else
  holds this lock" — a 400/401/403/500 no longer shows a fabricated version of that message).
- A regression introduced the same day it landed: `OrdersStore._normalizeOrder` was reading FIFO
  consumption lineage off the wrong object, silently discarding it on every order and crashing on
  any line whose product had been deleted — found and fixed same-session.
- Removed a dead, dangerous duplicate order-approval code path that bypassed every mechanism above.

See SKILLS Skill 36 for the full mechanism-by-mechanism detail and the reusable lessons from this
round.

**Update 2026-07-30:** `DataModel._tryAdjustOrder` (order returns/exchanges) now gets the same
async-await treatment `_tryCompleteOrder` got — added-unit stock deductions are confirmed before
the adjustment is finalized, reported honestly via callback instead of always claiming success.
Returns and price/discount changes stay synchronous (no network dependency). Known limitation kept
from the original scoping, **narrowed as of 2026-08-06**: the FIFO batch consumption itself now
rolls back correctly on a rejected delta (see above) — what's still explicitly out of scope is the
broader order-level side effects (refund amounts, price-adjustment ledger entries) not rolling
back; full compensating-write rollback across the whole multi-step flow remains a separate
initiative (§2 of the design doc), not something either fix round attempts.

**Still open** (Important-severity, tracked in the 2026-08-06 review, not silently dropped):
- `StockBatchStore.consumeFifo`/`topUpOldest`/`restoreFifo` still route through the old whole-record
  `recordMutation`, not `recordDelta` — still exposed to the original concurrent-clobber bug for
  the batch ledger specifically (unlike `InventoryStore`, which is now fully converted).
- `recordMutationsBatch` (`functions/lib/batchMutationLogic.js`) has no CAS check at all — the CAS
  guarantee isn't uniform across every write path in the app.
- Bulk order approval never acquires a per-order lock.
- `OrderDetailDialog`'s lock releases the instant the dialog closes, which is before
  `ConfirmReturnSheet`'s confirmation step actually runs the adjustment — the lock doesn't span
  that window. Flagged in the design doc, still not solved.
- When one order line's stock delta succeeds and a sibling line's is rejected, the successful
  line's delta stays applied even though the whole order reports failure — a partial-completion
  gap found while fixing the FIFO rollback above, needing a compensating delta call, deliberately
  left out of that fix's scope.

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

---
