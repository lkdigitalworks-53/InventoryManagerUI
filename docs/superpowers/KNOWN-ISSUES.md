# Known Issues

Running log of accepted, non-blocking issues deferred for later. Each entry: what's
broken, where, why it was deferred, and leads for a future fix.

---

## Async re-entrancy / double-submit bug class — tracked separately, severity-ranked

Found via the 2026-09-14 order-completion double-submit fix (PR #70): a whole *class* of bugs where
a fire-and-forget signal into an async `DataModel` orchestration function, with no busy state and
no re-entrancy guard, lets a repeated user action (double-tap, reopen-and-retry) run the same
mutation twice against stale local state. A full-codebase sweep (2026-09-15) found two more
Critical instances (`ConfirmReturnSheet`/`_tryAdjustOrder` exchanges, `NewOrderDialog` duplicate
order creation) and one Medium (`InviteMemberDialog`). Full trace, severity ranking, and the
checklist used to find them: `docs/superpowers/ASYNC-REENTRANCY-BUGS.md` — kept separate from this
file since it's one specific, well-defined pattern with its own severity structure, not a grab-bag
entry.

---

## Leave-workspace: self-leave rule staged but not deployed

**Status:** Update (2026-07-29) — the deploy this entry was blocked on has now happened.
`Gateway.mode` flipped to `"gateway"` (commit `649046d`), and Taher confirms Cloud Functions +
`firestore.rules` are deployed and working. Since `firestore.rules` ships as one unit, the
self-leave clause described below should now be live for free. **Not independently re-verified
in a session** (i.e. nobody has confirmed the leaver's member doc actually gets auto-removed
post-deploy) — treat as likely-resolved, not confirmed-resolved, until someone checks it on
live data.

**Original issue (2026-06-12), kept for context:** Re-login bug was fixed in code from the start
(`leaveCurrentTenant()` clears the tenant pointer on the leaver's own `users/{uid}` doc — a
self-write allowed even under the old rules). What was blocked on this deploy specifically: a
`firestore.rules` clause letting a member delete their OWN non-owner membership
(`tenants/{tid}/members/{uid}` where `uid == request.auth.uid`); before this deploy, that
self-delete was denied (403) and the leaver's member doc lingered as `status: active` (cosmetic
only — the owner could always remove the ghost member manually via Member Management).

---

## Order returns: cross-period temporal netting mismatch

When a completed order is returned/modified in a *different month* than the original sale, the
Analysis reports net the reversal in **different periods** depending on the surface:

- **Sold / Profit** are ledger-sourced (`TransactionStore` sale + return events). A return event is
  dated when the return happens, so Sold/Profit reduce the **return-month** bucket.
- **Revenue** is order-sourced (`OrdersStore.orders`, bucketed by `order.date`). `applyAdjustment`
  updates the order's lines/total but not `order.date`, so Revenue reduces the **original-sale-month**
  bucket retroactively.

Net effect for a sale in month A returned in month B: month A's Revenue drops while its Sold/Profit
stay full; month B shows the Sold/Profit reversal with no Revenue change. The "this year" hero and
all-time totals reconcile correctly; only narrower period buckets (and period-scoped exports) show
the split.

**Decision:** Accepted limitation for now (chosen during the returns/exchange brainstorm — the
"preserve consumption[] on adjusted lines" fix closed the by-supplier ₹0 bug; the temporal split was
explicitly logged here rather than re-sourcing Revenue from the ledger). Revisit when Revenue moves
to a ledger-sourced read (natural fit with the P0 immutable-ledger roadmap), at which point all three
surfaces would net in the same period.

**Related, 2026-08-20:** a second, different site of the same consumption-loss bug class was found
and fixed — `OrderDetailDialog._save()`'s plain metadata-edit path (customer/email/phone/status/
channel/staff, no line changes) was silently dropping `consumption[]` on every save to a completed
order, independent of the adjustment path referenced above. See SKILLS.md Skill 42 for the full
writeup.

---

## Delete: `Gateway._send` terminal-failure black hole applies to deletes too

`feature/product-order-delete-ui` (2026-08-30) added the missing row-level UI for the
already-implemented product/order delete logic. Tracing the full failure surface for that ticket
surfaced this: a delete is applied **optimistically** to local state the moment the user confirms,
before the network call resolves. `Gateway._send`'s non-conflict failure path
(`OutboxStore.markFailed()`) retries with backoff **indefinitely** — no terminal-vs-transient
classification, no signal back to any caller, ever. If a delete hits a persistent failure (bad
Firestore rules, a bug, a genuinely-terminal 403/5xx), the item is gone from the UI forever while
the server-side working doc — and the compliance `audit_log` entry — may still exist, silently
diverging from what the user believes happened.

**Not delete-specific** — this is the same latent infinite-retry bug already named as an
out-of-scope follow-up during the `fix/bulk-import-chunking-durable-status` work (chunked-batch
imports hit the identical `_send` code path). A real fix touches shared retry/classification logic
used by every mutation of every entity, not just deletes.

**Decision:** deferred again, same reasoning as the chunked-import branch's original deferral —
should ride together with (or immediately after) whatever session finally rewrites `_send`'s
retry/terminal-classification behavior, as one piece of work rather than two partial ones. Full
trace: `docs/superpowers/specs/2026-08-30-product-order-delete-ui.md`.

---

## Delete: staff delete has the identical missing-UI gap as products/orders had

Same root cause `feature/product-order-delete-ui` fixed for products and orders:
`StaffPage.qml` declares `signal deleteStaffClicked(string staffId)` and `Main.qml` already has a
confirm-dialog handler wired to it (`onDeleteStaffClicked` → `confirmDlg.ask(...)` →
`logic.deleteStaff(...)`) — but no visible element in the row template ever emits it. Identical
shape, identical fix (a small trash-icon button in the row, same `Rectangle`+`MouseArea` idiom now
used in `ProductCard` and the orders row).

`StaffStore._onMutationConflicted` was also deliberately left with the old (pre-`action`-param)
conflict-toast wording during the products/orders fix, for the same reason: unreachable from UI
right now, so the wording is moot until this gap closes.

**Decision:** not built — out of the original ask's scope (products and orders only). Low effort
to close once prioritized; the pattern is fully proven in the two entities that already have it.

---

## Delete: product delete doesn't clean up stock batches or the product photo — RESOLVED 2026-09-02

`InventoryStore.deleteProduct()` splices the product from the local array and routes the delete
through `Gateway.recordMutation`, but does **not** clean up that product's `StockBatchStore`
entries or call `StorageService.deleteProductPhoto()`. Both become orphaned after a product delete
— a stock batch pointing at a productId that no longer resolves to anything, and an unreferenced
image left in Firebase Storage.

**Original decision:** not touched by `feature/product-order-delete-ui` — this changes the blast
radius of what "delete a product" actually does (cascading deletes across two more subsystems)
and deserves its own review, not a drive-by inside a UI ticket that was scoped to "add the
missing button."

**Resolved.** Three candidate designs (do-nothing, centralize-the-read-filter, cascade-delete-
with-audit) were compared via `superpowers:brainstorming` + `ponytail:ponytail-audit` on three
throwaway branches (deleted after the decision — see
`docs/superpowers/specs/2026-09-02-cleanup-batches-photo-on-product-delete.md` for the full
comparison and the final, decided design). Cascade-delete was chosen. `deleteProduct()` now
removes every batch for the deleted product (audit-preserved via
`Gateway.recordMutation("stock_batch", ..., "delete", ...)`, mirroring the product's own delete)
and calls `StorageService.deleteProductPhoto()`, guarded in a `try/catch` since that call falls
through to a native singleton unavailable outside the real compiled app — same failure class as
the `logic`/`dispatcher` bug (Skill 58), guarded against directly this time rather than found the
hard way. The shared `InventoryStore._activeBatches()` filter (from the comparison's middle
tier) was implemented alongside it as a defensive backstop, replacing the four duplicated inline
guards added while fixing the two Sales Analysis bugs above. Full test plan:
`docs/superpowers/test-plans/2026-09-02-batch-cleanup-on-delete-test-plan.md`.

**Still open, not decided**: backfill for batches already orphaned by deletes that happened
before this shipped, and final confirm-dialog copy — both flagged in the spec doc, not blocking.

---

## CI ran `feature/product-order-delete-ui`'s tests — one real bug found and fixed, two tests reclassified

Update, 2026-09-01, to the entry that used to be here: this session flagged that qmltestrunner
*can* run (Skill 54) and recommended actually running this branch's new tests before merge.
That happened — real CI run, real `results.xml` — and it was worth doing:

**Real bug found and fixed:** all 9 `DataModel_deleteGuards` tests failed with
`ReferenceError: logic is not defined`, thrown from inside `DataModel.qml`'s own dispatcher
Connections block (`onDeleteOrder`, `onDeleteProduct`, and by the same pattern every other
handler in that block — `onAddOrder`, `onAdjustOrder`, `onUpdateStaff`, `onDeleteStaff`, etc.,
34 call sites total). `logic` was never declared anywhere in that file; the correctly-wired
property is `dispatcher` (`property alias dispatcher: _logicBus.target`, set from `Main.qml`'s
`DataModel { dispatcher: logic }`). This is **pre-existing on `main`**, not introduced by this
branch — `DataModel.qml` isn't part of this branch's diff. It went uncaught because no test had
ever exercised these handlers via a real signal dispatch before this branch's tests did; every
prior test either called a deeper private function directly (bypassing the buggy line, like the
existing `_tryAdjustOrder` precedent) or didn't touch this file at all.

**What this means beyond the test failure:** because the guard-refusal lines throw *before*
emitting anything, a blocked delete (wrong role, open-order reference, completed-order status)
was very likely failing **silently** in the real running app too — no crash, no error modal,
nothing visible, just a console `ReferenceError` nobody sees on a device. This directly
contradicts what this document's spec doc and test plan claimed about the permission/business-
rule error path being "already fully handled, verified" — that verification was a static code
trace, and a trace reading `logic.errorOccurred(...)` has no way to notice `logic` doesn't
resolve. Fixed: all 34 real call sites renamed `logic.` → `dispatcher.` in
`qml/model/DataModel.qml`.

**Two tests reclassified, not fixed as tests:** `tst_InventoryPage_deleteButton.qml` and
`tst_OrdersPage_deleteButton.qml` failed to *compile* — `InventoryPage.qml` → `GlassHeader` →
`Constants.qml` → `import Felgo`, and `.github/workflows/checks.yml`'s "QML Tests" job installs
plain Qt 6.8 only, confirmed by reading the workflow file rather than guessing. No full-Page QML
test can compile under that job, for any page, ever — not something fixable by editing the test.
Moved to `test/felgo-dependent/` (no CI job scans it; see that directory's README) rather than
deleted or left silently failing.

**Decision:** both closed out this session — bug fixed, tests relocated with their content
intact for manual runs on a Felgo-equipped machine. Full detail:
`docs/superpowers/test-plans/2026-08-30-product-order-delete-ui-test-plan.md`.

---

## Housekeeping: a memory-recorded active branch doesn't exist on the remote

Noticed, not chased down: prior-session memory records `fix/chunked-batch-import-over-200-rows` as
an active branch. It isn't on `origin` — the closest match by name and apparent scope is
`fix/bulk-import-chunking-durable-status`. Worth Taher confirming which one is actually current;
unrelated to `feature/product-order-delete-ui`, not investigated further here.


## Delete: Sales Analysis "Potential profit" went negative, "Inventory Value" didn't move at all — both fixed. Five other tabs' breakdown labels audited, not fixed

Bug report (2026-09-02): after deleting a product, a value in Sales Analysis wasn't updating
correctly. Followed `superpowers:systematic-debugging` — traced all 6 `SalesPage.qml` view
modes (Value, Purchased, Current, Revenue, Sold, Profit×2 sub-modes) rather than guessing at
the one tab mentioned, since the report asked for exactly that.

**Root cause, confirmed and fixed**: `InventoryStore.deleteProduct()` doesn't clean up that
product's `StockBatchStore` entries (already documented above, deliberately deferred). The
orphaned batch then gets walked by both `InventoryStore.potentialProfitByDimension()` (feeds the
xlsx export's Potential section) and `SalesPage.qml`'s on-screen "Potential" tab, which duplicates
that walk inline rather than calling the store function. Both priced the batch's revenue at 0
(`getById(productId)` returns nothing) while still charging its real `cogs` — a phantom loss that
dragged the "Potential profit on open stock" hero total down by the deleted product's full COGS,
for stock that, from the user's perspective, no longer exists.

**Fixed**: both places now skip a batch entirely once its product no longer resolves, instead of
pricing it at 0. Failing test written first (`tests/tst_InventoryStore_potentialProfitOrphanedBatch.qml`,
4 cases) against the store function — same import tier as `tst_InventoryStore_mutationConflicted.qml`,
which passed on a real CI run this session, so no reason to expect this one can't. The
`SalesPage.qml` mirror isn't independently tested (Felgo page, can't run in this CI job) — verified
by code symmetry with the tested fix instead, same discipline as the rest of this session.

**Follow-up report, same session (2026-09-02): "Inventory Value" tab wasn't affected by a delete
at all — not the total, not any chart.** Confirmed and fixed. Same upstream root cause (orphaned
`StockBatchStore` entries), different symptom: `totalValue()`, `valueByProduct()`, and
`valueBySupplier()` never called `getById()` at all — they only need `qtyRemaining × unitCost`
from the batch's own stamped fields, no live product required, so a deleted product's remaining
stock kept counting in full, forever, with zero visible effect. `valueByCategory()` did call
`getById()`, but only to pick the category label (falling back to "(uncategorised)") — it still
included the value either way, never excluded it. Fixed all four with the same defensive skip:
exclude a batch entirely once `getById(productId)` returns nothing. This also makes the Value tab
consistent with "Current," which already excludes a deleted product's stock (it walks
`InventoryStore.products` directly) — before this fix the two tabs disagreed with each other about
whether a deleted product's stock still existed. `SalesPage.qml`'s filtered `_valueMaps()` walk had
the identical unguarded pattern and got the same fix; the unfiltered path already delegates to the
now-fixed store functions. Failing test first: `tests/tst_InventoryStore_valueOrphanedBatch.qml`
(5 cases). Note: `totalValue()` itself currently has no live caller anywhere in the QML codebase
(checked) — fixed anyway since it's part of the same function group and is exercised by the new
test, but the actual user-visible path is the `_valueMaps` → `valueByProduct/valueBySupplier/
valueByCategory` chain.

**A bigger question this raised — answered 2026-09-02**: should deleting a product with
remaining stock (`qtyRemaining > 0` in any batch) even be allowed in the first place? Answered:
yes, allowed, with a warning — see the resolved entry above. `deleteProduct()` now shows the
remaining quantity and value in the confirm dialog and cascades the delete through the stock
batches rather than leaving them orphaned. Blocking the delete outright was considered and
rejected — there's no existing way to write off a batch's quantity to zero otherwise, which would
have trapped a user wanting to remove a discontinued or mis-entered product.

**Reconsidered again, 2026-09-14, on-device review**: proposed blocking delete until *every*
transaction referencing the product has been "reverted." Re-examined rather than implemented:
this doesn't actually solve the trapped-user problem it's aimed at, for two reasons. First,
there's no way to revert a *purchase* (a received batch) at all — `StockBatchStore` has no
"return to supplier" or remove-a-batch function — so this would make delete permanently
impossible for any product that was ever restocked, which is most of them. Second, reverting a
*sale* (reopening or reversing a completed order) increases remaining stock — it undoes the
consumption — it doesn't provide any path to reduce stock to zero. A product with genuinely
excess or unsellable stock would never become deletable under this rule, recreating the exact
problem blocking delete outright was rejected for the first time around. The actual fix for the
underlying concern — dangling references surviving a delete — is what shipped this same day: see
the entry below, which found and fixed a concrete instance of exactly that risk in the order-
reversal path, using the same "guard every consumer, don't block the action" approach rather than
restricting when delete is allowed.

**Second finding, audited but explicitly not fixed here — different, bigger root cause**: the
other five tabs (Value, Purchased, Revenue, Sold, Profit's Realised sub-mode) keep correct
*totals* after a delete — those walk the immutable event/batch ledger directly, no live-product
dependency for the number itself. But their **by-category** breakdown silently reclassifies a
deleted product's historical contribution into an "(uncategorised)" bucket, and their **by-name**
breakdown shows the raw `productId` instead of the product's name, because both resolve
category/name via a live lookup (`InventoryStore.getById`/`.products`) rather than data stamped on
the transaction record at the time of the sale/purchase. This is correct-by-design for the
"Current" tab (a live stock snapshot — a deleted product correctly vanishing from it is not a
bug) but wrong for anything meant to be permanent history. Real fix would mean stamping
category/name onto each transaction/consumption record at creation time — a schema-level change
across every write path that creates one, not a one-line defensive check, and a different root
cause from what's fixed above. Not attempted this pass — flagging it here rather than bundling a
second, much larger fix into the same change (Iron Law: one fix at a time).

**Decision**: fixed the total-corrupting bug (Potential profit). Documented, not fixed, the
breakdown-mislabeling issue across the other five tabs — worth its own dedicated design pass.

## Delete: cascade-deleting stock batches created a NEW dangling-reference path — found on-device review, fixed

Found during Taher's on-device review of the Tier C cascade-delete PR (2026-09-14), not by a test
— a real regression introduced by that same PR's own fix.

**The chain**: `deleteProduct()`'s cascade (see the entry above) correctly removes every batch for
a deleted product. But `StockBatchStore.restoreFifo`/`topUpOldest` — called from **11 places** in
`DataModel.qml` whenever a completed order gets reopened, reversed, or adjusted (a return or
exchange with restock, for instance) — fall through to synthesizing a brand-new
`"Adjustment (drift repair)"` batch at `unitCost: 0` when no batch exists for the productId
anymore. That fallback is correct for genuine drift on a product that still exists (its original,
intended purpose). It's wrong once the product has been deleted: it resurrects exactly the
orphaned-batch problem the cascade was built to prevent, except now with the wrong (zero) cost
basis, for a product a user explicitly removed. Concretely: sell 1 of 5 units via a completed
order, delete the product (batch correctly cascades away), later process a return/exchange or
reopen that order — a phantom batch reappears for a product that no longer exists in the catalog.

**Fixed**: two shared wrappers in `DataModel.qml` (`_restoreFifoSafe`, `_topUpOldestSafe`) check
`InventoryStore.getById(productId)` first and skip the call entirely — rather than letting it fall
through to the synthesize-a-batch path — when the product no longer exists. All 11 call sites
route through these instead of calling `StockBatchStore` directly, rather than guarding each one
individually (same "one place to get it right" reasoning as `_activeBatches()`). Test:
`tests/tst_DataModel_restoreFifoSafeGuards.qml` — only the skip path is independently testable;
the "product still exists, delegates through normally" path chains into a real network round-trip
to mint a batch id, same untestable-without-mock-HTTP territory as the rest of this session's
`Gateway`-adjacent tests.

**Worth naming as a pattern, not just this one instance**: this is the second time a fix aimed at
one symptom (orphaned batches breaking Sales Analysis) needed tracing into a completely different,
non-obvious corner of the codebase (order reversal/adjustment) to find where the SAME underlying
resource (a deleted product's batch data) gets touched again. A change that looks contained to
"what happens at delete time" can have consumers anywhere a productId outlives the product record
— reversal flows, exports, reports, anything that persists a productId and looks it up later.
Worth a deliberate sweep for other such consumers before considering this fully closed, not
assumed complete after one round.

## Delete: batch stays in Firestore after product delete — CAS-check failure, pre-existing bug found via on-device repro

Reported on-device, exactly reproducible: create a product with stock 10, sell 1 via a
completed order (batch now `qtyRemaining: 9`), delete the product — product disappears, batch
stays in Firestore at `qtyRemaining: 9`, confirmed directly in the Firestore console.

**Root cause, pre-existing, not introduced by the cascade-delete feature**: `StockBatchStore`'s
`consumeFifo`/`restoreFifo`/`topUpOldest` success handlers stamped a fresh, client-generated
`updatedAt: new Date().toISOString()` onto the local batch cache after every successful
`Gateway.recordDelta` call. Server-side, `applyDelta` never touches `updatedAt` at all — only the
delta's target field. So the local cache's `updatedAt` diverges from Firestore's actual stored
value the moment any batch is first consumed against, restored, or topped up, and stays diverged
forever. The cascade-delete feature was the first thing to ever send that locally-cached batch as
a CAS `before` for a delete — the server's `_deepEqual(current, before)` check fails on that one
field, the delete gets silently rejected as a 409 conflict (conflicts are never retried), and
`StockBatchStore._onMutationConflicted` quietly restores the batch to the local array with no
toast (by design) — invisible unless someone checks Firestore directly, exactly what happened
here. Full trace and the general lesson: SKILLS.md Skill 60.

**Fixed**: removed the synthetic `updatedAt` bump from all three success handlers — the field now
correctly stays whatever it was, matching what the server's delta-apply path actually does.

**Not independently unit tested** — verifying it needs a real `Gateway.recordDelta` network
round-trip to fire the success callback, same untestable-without-mock-HTTP territory as every
other Gateway-adjacent path this session. Verified by exact code trace instead; on-device
re-test of the original repro is the real confirmation, recommended before considering this
closed.

## Delete: reversal/reopen silently skipping stock restoration needed to be visible, not just safe

Follow-up report, on-device (2026-09-15): the Skill 60 fix (batch actually gets deleted now) was
confirmed working. But testing the *other* direction — reopening a completed order back to
pending, or reducing its quantities, when the product it referenced has since been deleted —
looked wrong: "it just vanishes... there's no product or batch to handle the return or revert of
status." That's `_restoreFifoSafe`/`_topUpOldestSafe` (see the entry above) doing exactly what
they were built to do — correctly refusing to resurrect a phantom batch — but doing it with only
a `console.warn`, invisible to whoever's actually processing the reversal. The order's own
status/quantity change still completes; the stock side of it silently becomes a no-op with no
indication why.

**Fixed**: both wrappers now also emit a new `Logic.stockRestorationSkipped(productId)` signal
(via `dispatcher.stockRestorationSkipped(...)`, the correct property post-Skill-58), which
`Main.qml` turns into a Toast — "Stock wasn't restored — a product on this order was deleted and
no longer exists." The reversal/reopen still completes either way (blocking it was already
considered and rejected, see the entry further above); this only makes the consequence visible
instead of silent. Test: `tests/tst_DataModel_restoreFifoSafeGuards.qml`, extended with 2 cases
verifying the signal fires with the right productId, using `SignalSpy` on the real `Logic`
signal — not a repeat of the `Gateway.recordMutation` monkey-patch mistake from earlier.

## Delete: the Activity feed never showed a delete happening at all

Reported same review pass: `product_added`/`product_updated`/`product_restocked`/`staff_added`/
`staff_updated` all call `ActivityLog.record(...)`; none of the three delete functions
(`InventoryStore.deleteProduct`, `OrdersStore.deleteOrder`, `StaffStore.deleteStaff`) ever did.
Deleting something left zero trace in the one place this app already shows a history of what
happened.

**Fixed**: added the same `ActivityLog.record(...)` call already used by every other mutation in
each of those three functions (`"product_deleted"`, `"order_deleted"`, `"staff_deleted"`), plus
matching icon/gradient entries in `ActivityPage.qml` for the three new kinds — reusing the
`"delete"` icon name, which already existed in `Constants.colorIconSet` for exactly this kind of
history-feed entry (the same lookup this session avoided for the row-level delete *buttons*,
which needed a different, tintable icon instead — see the `feature/product-order-delete-ui`
work). Test: `tests/tst_ActivityLog_deleteEntries.qml` (4 cases) — `ActivityLog.record`'s local
`entries` update is synchronous, only the Firestore push is fire-and-forget, so this one is
cleanly and fully testable, unlike most of this session's Gateway-adjacent fixes.

## Delete: pushing the stock-restoration-visibility fix broke a pre-existing, unrelated test on CI

The `Logic.stockRestorationSkipped` fix (entry above) shipped a bare
`dispatcher.stockRestorationSkipped(productId)` call inside `_restoreFifoSafe`/`_topUpOldestSafe`.
Real CI run: `tst_OrderMetadataEditPreservesConsumption.qml` failed with `Property
'stockRestorationSkipped' of object DataModel... is not a function`. That test (and 3 others —
`tst_DataModel_discountEditTax.qml`, `tst_DataModel_completeOrderReentrancy.qml`,
`tst_DataModel_adjustOrderSyncGuard.qml`) instantiate `DataModel { id: dm }` with no `dispatcher`
set at all. QML's `Connections` defaults `target` to its parent when unset — so `dispatcher`
there silently resolves to the `DataModel` instance itself, which has no such function. Real
production code is unaffected; `Main.qml` always wires a real `Logic` instance as `dispatcher`.

**Fixed**: guarded the call with `if (dispatcher && typeof dispatcher.stockRestorationSkipped ===
"function")` in both wrappers, rather than touching any of the 4 unrelated pre-existing test
files. New regression test added to `tests/tst_DataModel_restoreFifoSafeGuards.qml` reproducing
the exact no-dispatcher setup.
