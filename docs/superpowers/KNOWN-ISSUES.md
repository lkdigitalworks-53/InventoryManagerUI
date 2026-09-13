# Known Issues

Running log of accepted, non-blocking issues deferred for later. Each entry: what's
broken, where, why it was deferred, and leads for a future fix.

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

## Delete: product delete doesn't clean up stock batches or the product photo

`InventoryStore.deleteProduct()` splices the product from the local array and routes the delete
through `Gateway.recordMutation`, but does **not** clean up that product's `StockBatchStore`
entries or call `StorageService.deleteProductPhoto()`. Both become orphaned after a product delete
— a stock batch pointing at a productId that no longer resolves to anything, and an unreferenced
image left in Firebase Storage.

**Decision:** not touched by `feature/product-order-delete-ui` — this changes the blast radius of
what "delete a product" actually does (cascading deletes across two more subsystems) and deserves
its own review, not a drive-by inside a UI ticket that was scoped to "add the missing button."

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

**A bigger question this raises, not decided or acted on**: should deleting a product with
remaining stock (`qtyRemaining > 0` in any batch) even be allowed in the first place? The existing
delete guard in `DataModel.onDeleteProduct` already blocks a delete when the product is referenced
by an *open order* — it does not check remaining stock at all. Every fix above makes the numbers
consistent by *excluding* a deleted product's leftover stock from every view, which is the right
symptom-level answer, but doesn't address whether letting a product with stock on hand disappear
from the catalog (while the physical goods presumably still sit in a warehouse somewhere) is the
right behavior to allow at all. That's a product/business decision, not a bug — flagging it, not
deciding it.

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
