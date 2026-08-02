# Checkpoint — Background Processing / Worker Threads (Import/Export)

**Date:** 2026-07-18
**Branch:** `feature/background-worker-threads` (off `main` @ `58891f7`)
**Status:** Brainstorming complete for import/export scope (`/superpowers:brainstorming`). Design
approved across all 4 sections. No implementation code written yet — spec + roadmap doc are the
next deliverable.
**Note:** sandbox reset mid-session; this checkpoint was reconstructed from the conversation
record after a fresh re-clone. No decisions were lost, just redone on disk.

## Context

Taher's original ask: move heavy operations off the UI thread — network ops, import/export,
analysis math, "you be the judge" for the full list — plus UI progress-indicator design for each.

## Scope decision (confirmed with Taher)

This brainstorm covers **import/export only** (`XlsxService` native read/write +
`ImportPreviewDialog.qml`'s validation logic). Explicitly out of scope, by Taher's own call:
- Analysis math (`RealisedMath` local scan) — separate decision needed on finishing the
  `AnalysisService` Cloud Function cutover vs. local threading.
- Firestore/Gateway network operations broadly — left to the offline-handling design.

## Exploration findings

- No threading exists anywhere in the repo today (`WorkerScript`/`QThread`/`QtConcurrent`/
  `moveToThread` all zero hits) — greenfield.
- Native C++ layer (`XlsxService`, `ImageProcessor`, etc.) already exists as registered QML
  context properties, so both a C++ and a QML-only threading path are available.
- `XlsxService` methods (`writeProducts/writeOrders/writeStaff/writeAnalysis*/readWorkbook`) are
  `Q_INVOKABLE`, run **synchronously on the calling (UI) thread** today.
- `ImportPreviewDialog._validateProductRows`/`_validateOrderRows` are **not quadratic** (corrected
  an earlier overstatement) — hash-map build O(n) + single pass O(m). Real cost, likely a smaller
  contributor to the freeze than initially assumed.
- **Read vs. write asymmetry in `XlsxService.cpp`:** write path is our own loop (full progress +
  real cooperative cancel possible); `readWorkbook`'s `QXlsx::Document::load()` is one opaque call
  into a vendored third-party lib — no progress/cancel hook, won't patch vendored QXlsx. Cancel
  during `load()` can only mean "let it finish, then discard the result."
- **Clean choke points:** all 4 exports funnel through one function in `Main.qml`
  (`_deliverExport`); import has exactly one call site (`ImportPreviewDialog.qml:365`).
- **Major finding — the real observed freeze is in `ImportPreviewDialog._apply()`, not the
  read/validate phase this spec covers.** Verified by reading the actual code:
  - `InventoryStore.upsertMany()` calls `Gateway.recordMutation()` **once per row inside the
    loop**, not the batched `Gateway.recordMutations()` — violates the already-documented "batch
    imports via `recordMutations()`" principle. Confirmed live in shipped code, not hypothetical.
  - Same function reassigns the reactive `products` property **once per new row** lacking a
    pre-existing Product ID (most rows in a typical import) — likely storms every dependent
    binding/model N times over. Very plausibly the dominant real-world freeze cause.
  - `OrdersStore.upsertMany()` has the identical shape (per-row `Gateway.recordMutation("order",
    ...)`, per-row `orders = arr` reassignment).
  - **Implication, stated plainly to Taher:** threading `_apply()` wouldn't even be the most
    effective fix — the loop itself is inefficient independent of which thread it runs on.

## Sequencing (requested by Taher — goes in a separate roadmap doc, not this spec)

Decision: **a separate cross-cutting roadmap doc**, referenced by this spec and by future ones
(offline-handling, analysis cutover, apply/write-layer threading), rather than a section buried in
this spec. The `upsertMany` per-row-Gateway + per-row-reactive-property bug: **folded into the
sequencing as part of the eventual apply/write-layer work**, not fixed independently/sooner.

Verified spec names and status for the roadmap doc:
- `docs/superpowers/specs/2026-06-06-india-compliance-roadmap-design.md` /
  `2026-06-06-P0-compliance-gateway-design.md` — Orders/Staff/Suppliers Gateway *routing* merged.
  Full compliance cutover (deploy Cloud Functions + rules, `runCutover`, flip `Gateway.mode` to
  `"gateway"`) **not done** — still `"direct"` mode today.
- `docs/superpowers/specs/2026-07-09-offline-handling-design.md` (v4) — not implemented, now
  unblocked (dependency merged). This is the design that actually introduces durable-outbox +
  enqueue-time coalescing — the real mechanism for bulk writes without hammering Firestore/the
  main thread. **Apply/write-layer threading (including the `upsertMany` fix) should wait for
  this to land**, to avoid rework.
- `docs/superpowers/specs/2026-07-06-scale-reads-writes-analytics-design.md` — `AnalysisService`
  Cloud Function exists, not wired into `SalesPage.qml`. Separate track, doesn't gate import/export.

## Approved design (4 sections, all signed off by Taher)

**1. Architecture & components:**
- Native: new `XlsxWorker` QObject run via `QtConcurrent::run()` (thread pool, not hand-rolled
  `QThread`). Signals: `progress(int done,int total)`, `writeFinished(QString url)` /
  `readFinished(QVariantMap result)`, `failed(QString error)`, `cancelled()`. `XlsxService`'s
  `Q_INVOKABLE` methods change from blocking-return (`QString writeProducts(...)`) to fire-and
  -return (`void startWriteProducts(...)`) — a breaking API change, every call site updates.
  `Q_INVOKABLE void cancelCurrent()` flips a shared atomic bool checked every N rows/chunks.
- QML: `qml/helper/ImportValidation.js` (`.pragma library`, pure functions, extracted from
  `ImportPreviewDialog.qml`'s current inline logic) + `qml/workers/ImportValidationWorker.js`
  (WorkerScript entry point), processes in ~500-row chunks for progress ticks + cooperative cancel.
- Shared: one new `qml/components/ProgressOverlay.qml` used by both export (`Main.qml`) and
  import (`ImportPreviewDialog.qml`) — one visual language, not two bespoke ones.
- **Accepted risk (Taher agreed explicitly):** no Qt toolchain in this sandbox — native C++ code
  written + manually reviewed, not compiled, this session. Needs on-device build+run before merge.

**2. Data flow:**
- Export: existing trigger → lightweight synchronous data-prep (stays main-thread, not worth
  threading) → `startWriteProducts()` → `ProgressOverlay` (determinate) → `writeFinished` →
  unchanged `_deliverExport(url,label)`. Single in-flight op only (modal already prevents a second).
- Import: file picked → overlay "Opening file…" (indeterminate, un-cancellable) →
  `startReadWorkbook()` → cancel flag checked immediately once `load()` returns → determinate
  "Reading row X of Y" → `readFinished` → hands off to `ImportValidationWorker` (chunked,
  determinate "Validating X of Y rows") → final chunk assembles `{ready,issues,warns}` → overlay
  hides → existing `ImportPreviewDialog` preview screen, unchanged. **Everything from `_apply()`
  onward is explicitly unchanged/deferred** per the sequencing above.

**3. Progress UI:** `ProgressOverlay.qml` styled to match the existing `AlertDialog.qml`
bottom-sheet pattern (drag-handle pill, `Constants` tokens — `brand1` indigo, `radiusXl`,
`space3`, `durMed`), reusing the existing `GhostButton` for Cancel rather than a new button style.
Determinate bar (brand1-filled) wherever we control the loop; indeterminate (brand1-tinted) only
for the `load()` phase, honestly labeled "Opening file…" rather than a fake percentage. `cancelling`
state disables the button + shows "Cancelling…" with a spinner (cancellation is cooperative, not
instant — a live-but-inert button would read as broken). Terminal states reuse existing UI
(`_deliverExport`'s share flow, existing preview screen, existing `AlertDialog` for errors,
existing `Toast` singleton for cancelled). **Nice-to-have, explicitly not in the base design:** a
3-dot phase-tracker for import's multi-phase label — cut for now per YAGNI, noted for later.

**4. Error handling / cancellation / testing:**
- Native write/read failures → `failed()`, partial file deleted first (same cleanup as cancel),
  existing `AlertDialog` (variant: error).
- Structural read errors (missing sheet etc.) — unchanged from today, stay inside the successful
  result's `errors` array, shown as an issue row in preview, not a blocking alert.
- WorkerScript chunk handlers wrapped in try/catch, **always** call `sendMessage()` (success or
  `{error}`) — an uncaught exception would otherwise silently hang the overlay forever with no
  response ever sent back.
- Cancel granularity: native write — true per-N-rows; native `load()` — none possible (vendored
  lib), honored at next checkpoint after `load()` returns; native row-extraction — per-N-rows;
  WorkerScript validation — free, driver just stops dispatching next chunk and discards results.
- Testing: `ImportValidation.js` — Node-runnable first, then ported to `tests/tst_ImportValidation.qml`
  (matches `tst_ImportMath.qml` convention). Native code — written/reviewed only, on-device
  build+run required, no toolchain here. `ProgressOverlay.qml` — proposing an on-device test plan
  doc (matches existing `*-on-device-test-plan-*.md` convention) rather than claiming
  `qmltestrunner` coverage for visual/animation correctness.

## Next action

1. Commit this checkpoint, rebase (no-op — branched fresh off current `main`), push using
   Taher-provided token (**one-off, to be revoked/regenerated by Taher immediately after this
   session** — treat as compromised once used, per established convention).
2. Write `docs/superpowers/specs/2026-07-18-import-export-background-threading-design.md` (the
   approved 4-section design above, formalized).
3. Write the separate roadmap/sequencing doc referenced by this spec.
4. Commit + push both once written (pending Taher's go-ahead — token already provided covers this
   session, but confirm before each additional push).
