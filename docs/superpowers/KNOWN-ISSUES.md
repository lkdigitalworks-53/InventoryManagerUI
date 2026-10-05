# Known Issues

Running log of accepted, non-blocking issues deferred for later. Each entry: what's
broken, where, why it was deferred, and leads for a future fix.

---

## Restock is two independent writes: a 4xx drops the stock delta but keeps the batch — DECIDED 2026-09-30, NOT BUILT

**Found on-device (Taher, PR #97 test).** Member `status` set to suspended, then restock a product: toast "Could not
restock", the stuck list showed one write. After setting the member active and tapping Retry now, the stock batch
appeared but the product's `stock` in Firestore did not change. Batch and stock disagree.

**Cause (code reading, plus Taher's two on-device confirmations: the toast, and `stock` unchanged in Firestore).**
`InventoryStore.restock` sends two unrelated writes in parallel: `StockBatchStore.addBatch` (`Gateway.recordMutation`,
sender `_send`) and `Gateway.recordDelta` (sender `_sendDelta`). A suspended member gets 403
`{ok:false, error:"no-tenant-context"}` on both. `_send` retries any non-2xx that is not a CAS conflict, so the batch
stays queued and stuck. `_classifyDeltaResponse` treats a 4xx with a well-formed `ok:false` body as a definitive
rejection, so the delta is removed from the outbox and its callback gets the failure (which is the toast). Retry now
then lands only the batch. Not caused by the stuck-writes dialog or state persistence (PR #97 / S2a); those only made it
visible. Any 4xx on the delta produces the same batch-without-stock state, not just a suspended member.

**Also lost in that path:** the ActivityLog "Restocked" entry and the purchase `TransactionStore` record, because they
run inside the delta callback. That callback lives in memory (`Gateway._deltaCallbacks`), so even a delta that is only
retried and then succeeds after a relaunch lands on the server without them.

**Decision (Taher, 2026-09-30): make batch + stock delta ONE atomic operation** (`Gateway.recordOperation`, the C-3
atomic outbox), so both land or neither does. Documented only; nothing built. Rejected for now: (A) retrying deltas on
403, which fixes this one path but leaves the two writes independent and the callback loss unchanged.

**Leads for whoever builds it** (not verified, open questions):
- `functions/lib/operationLogic.js` has `OP_TYPES = ["completeOrder"]`; a `restock` opType needs server logic and a
  deterministic `opKey` (`OperationKeys.js` has the pattern) so a re-run is exactly-once. This also bears on the
  RestockDialog double-submit item (ASYNC-REENTRANCY-BUGS C-4).
- The batch id comes from `StockBatchStore.nextBatchId`, a network mint that can itself fail (`_queuePendingMint`). Decide
  whether the id is minted before the operation or by the server.
- The ActivityLog / purchase record should follow the operation's applied signal, not an in-memory callback, or the
  relaunch loss stays.
- Supplier resolution (`_resolveSupplierId`) stays a separate step before the operation; its failure handling is unchanged.
- Not checked: other places that pair `addBatch` with `recordDelta` (for example product create with opening stock) and
  may have the same shape.

**Until built:** to force a stuck write in device tests use a single-write action (edit a product name), not Restock.

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

**Update 2026-09-19 (PR #75) — surfaced, not resolved.** The *silent* half is fixed: `Gateway` now counts
server-side failures per queued write in all three senders (`_send`, `_sendBatch`, `_sendDelta`) and, after
5, shows one toast and a persistent `GlassHeader` caption line until the write leaves the outbox (spec:
`docs/superpowers/specs/2026-09-19-gateway-stuck-write-indicator-design.md`). Taher chose surface-only over
drop + rollback, park, or server-side classification, so the *diverged* half remains: retry, backoff and
dropping are unchanged, local state still differs from the server while a write is stuck, and there is no
in-app Retry/Discard. Follow-ups, in the order they would pay off: (B) park a stuck write and offer
Retry/Discard, with Discard rolling back to the outbox item's `before`; (C) have `functions/index.js` map
Firestore error codes to distinct HTTP statuses (today every exception is `500 write-failed`) so the client
can classify precisely instead of counting.

**Update 2026-09-28 (part C landed, branch `fix/2026-09-28-gateway-write-error-classification`):** (C) is done, but
NOT as distinct statuses: the status stays 500 and the body `error` is `write-rejected` / `write-unavailable` /
`write-failed` (a 4xx would make the delta and operation senders drop the write, SKILLS Skill 74). The client labels
stuck writes the server rejected ("N change(s) rejected by the server. Still retrying."). Still open: (B) park +
Retry/Discard (Taher's Q2-Q4: re-pull on Discard, persisted parked flag, tappable caption -> dialog).

---

## Delete: staff delete has the identical missing-UI gap as products/orders had — RESOLVED 2026-09-21

Same root cause `feature/product-order-delete-ui` fixed for products and orders:
`StaffPage.qml` declares `signal deleteStaffClicked(string staffId)` and `Main.qml` already has a
confirm-dialog handler wired to it (`onDeleteStaffClicked` → `confirmDlg.ask(...)` →
`logic.deleteStaff(...)`) — but no visible element in the row template ever emitted it. Fixed
(`feat/2026-09-21-staff-delete-ui`) with the same trash-icon `Rectangle`+`MouseArea` idiom already
used in the orders row and `InventoryPage`.

`StaffStore._onMutationConflicted` also gained the `action` param and delete-specific toast wording
it was deliberately left without during the products/orders fix (it was unreachable from the UI
until this gap closed). Along the way, two adjacent findings: a client-side guard now blocks
deleting your own staff record (dormant until login provisioning ships, see the entry below), and
`recordMutation` gained a narrow server-side role check for staff/delete specifically (see "Delete:
recordMutation has no server-side role check for any entity/action" below — staff/delete is now the
one exception).

Design: `docs/superpowers/specs/2026-09-21-staff-delete-ui-design.md`.

### Follow-up found on-device, fixed on the same branch (2026-09-25): a deleted staff member's name vanished from history

Taher's on-device pass of PR #80 found what the "resolved" note above missed: orders and sale events keep only
a `staffId`, and every display path re-looked it up in the live roster. After a delete, the order detail
showed "Sold by (none)", the exported Orders sheet had a blank Staff column, and Sales Analysis showed a bare
"(removed)". Worse, `OrderDetailDialog`'s picker only offered *active* staff, so opening and saving such an
order **silently cleared `staffId`** (same for staff on leave / suspended), and re-adding a staff member with
the same name made the old order read as the new person's. The test plan's original case 8 had asserted the
blank/"(removed)" outcome was fine — an assumption from reading code, never exercised; corrected.

Fix: a `removed_staff` tombstone `{staffId, name, removedAt}` written through the Gateway when a staff
record is deleted, one resolver (`StaffStore.displayName` → `Name (removed)`) for the picker, export and
analysis, `nextStaffId` refuses a tombstoned id, and the picker keeps the order's current attribution
selectable. See test plan section 5 and Skill 70. **Still open:** orders attributed to a member deleted
*before* this fix have no tombstone (test data only — there was no delete UI before PR #80); a tombstone
freezes the name at deletion time; a low-priority follow-up would be to also stamp `staffName` on
orders/events at write time (the same schema-level change DELETE-FEATURE-ROADMAP item 3 describes for
products) if history must survive without the tombstone collection.

---

## Security: `recordMutation` has no server-side role check for any entity/action except staff/delete

Found while closing the staff-delete gap above (2026-09-21). `functions/index.js`'s `recordMutation`
derives `actorRole` from the caller's own tenant membership doc for the audit trail, but never uses
it to authorize the mutation itself — only `provisionMember` checks role
(`canAssignRole`/`role-not-allowed`). Every `DataModel.on*` role guard (`onDeleteOrder`,
`onDeleteProduct`, `onAdjustOrder`, etc.) is client-side only; a signed-in tenant member with a valid
ID token can call the gateway directly and bypass every one of them. Confirmed by a passing test:
`functions/test/index.handlers.test.js`'s "an ORDER delete by a non-owner/admin is unaffected" case
returns 200 for a `manager` role, by design of the current (unfixed) behavior.

Staff delete got a narrow, targeted fix (2026-09-21) because it carries real security weight — it
can cascade-revoke a teammate's Firebase Auth login via `AuthService.cleanupStaffAuthDocs`. Every
other entity/action is unfixed.

**Decision:** not built — a general authorization matrix (deriving the allowed actions per role,
server-side, for every entity) is a bigger design than any single delete-UI ticket should absorb
piecemeal; each narrow fix duplicates logic that belongs in one place. Needs its own session:
probably a shared `authorize(ctx.role, entity, action)` check called once per handler, sourced from
the same role/action rules `DataModel.qml`'s guards already encode client-side, so the two stay in
sync by construction rather than by two people remembering to update both.

**Update 2026-09-30 (photos design session):** the two product-photo endpoints (`uploadProductPhoto`,
`deleteProductPhoto`) get a narrow owner/admin gate, mirroring `AuthStore.canManageInventory`. This is partial
hardening only: a staff token can still edit or delete the product itself through `recordMutation`. When the general
`authorize(ctx.role, entity, action)` check above is built, replace the photo gate with it instead of keeping two copies.

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


## Delete: Sales Analysis "Potential profit" went negative, "Inventory Value" didn't move at all — both fixed. Five other tabs' breakdown labels — RESOLVED 2026-09-26

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

**Follow-up, RESOLVED 2026-09-26 (`fix/2026-09-26-sales-analysis-deleted-product-labels`)**: the
"schema-level change" framing above turned out to only be half true once traced to source.
`productName` was already stamped on every `TransactionStore` entry at creation time — the by-name
half was a small, contained **read-side** fix (`BreakdownMath._productNameKey` /
`SalesPage._namedProductMap` re-derived the name live instead of using what was already on the
entry). `category` genuinely was never stamped anywhere — that half needed the write-path change
as originally scoped: `recordPurchase` / `recordCreated` / `recordSaleFromOrder` now stamp
`category` at time-of-transaction; `recordReturn` / `recordPriceAdjust` reuse the *original sale's*
stamped category via a new `_stampedCategoryFor()` lookup, since the product referenced by a return
may already be deleted by return time. Read side (`BreakdownMath`/`RealisedMath`) now prefers the
stamped value **only** when the live product no longer exists — a still-existing, recategorized
product's history keeps showing its current category, unchanged. A real, pre-merge bug in this fix
itself is worth recording: the first pass got the precedence backwards for `RealisedMath` (used
`e.category || categoryOf(...)`, which let a stale stamp override a still-live product's *current*
category) — caught by the Node parity suite's `bydimension_category_live_product_wins_over_stale_stamp`
test actually failing (real `node --test` run, not a trace), fixed with a `_resolvedCategory()`
helper that checks live-product-existence first. See
`docs/superpowers/specs/2026-09-26-sales-analysis-deleted-product-labels-design.md` for full detail.
Also applied to the server-side parity port (`functions/lib/breakdownMath.js` / `realisedMath.js`),
which had the identical bug and is a live Cloud Function (`computeAnalysis`) reading the same
Firestore collections — would otherwise have kept mislabeling server-generated reports/exports
after the client-side fix shipped.

**Two adjacent, related findings — audited, deliberately not fixed here (Iron Law: one fix at a
time)**:
1. The category **filter** dropdown (`RealisedMath._passesScope`'s `scope.category` matching) is a
   separate mechanism from the breakdown **label** fixed above and stays live-only. A deleted
   product can no longer be chosen in the filter dropdown in the first place, so this doesn't
   reproduce the mislabeling bug — but if a *still-live* product is filtered by category while a
   *different, now-deleted* product's history should logically also match, that history is silently
   excluded from the filtered total. Low severity, no user report against it.
2. An order-wide price adjustment (no single `line.productId`) spreads its delta across every
   product in the order via `OrderMath.spreadOrderDelta(..., categoryOf)`, which is inherently
   per-split-product and doesn't have a single value to stamp — genuinely deleted-product entries
   from that path still resolve category live and can still show "(uncategorised)". Narrow: only
   affects an order-wide (not per-line) adjustment touching an already-deleted product.

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

---

## Photos PH3: accepted limits of the server cascade — BUILT 2026-10-03 (PR pending), PH3b/PH4 NOT BUILT

Built: owner/admin gate on both photo endpoints (the narrow gate from the 2026-09-30 update above), `pending_cleanup`
marker written in the product-delete transaction, post-commit prefix sweep, F3 upload preflight (no orphan objects on
404/409), strict id whitelist. Design: `specs/2026-09-30-photos-s3-s4-design.md`. Accepted, on purpose:

1. **F5 (strict CAS includes `photoIds`).** An edit whose `before.photoIds` is stale (a photo was confirmed on the
   server between edit and drain) gets 409 and the user's edit is parked. Pinned by F37-F39. Relaxing it needs the
   server to preserve `photoIds` itself; not done.
2. **Residual upload race.** A product deleted between the F3 preflight read and the Storage write can leave one orphan
   object pair (the transaction then returns 404). Pinned by F10. The marker sweep does not catch it (the marker was
   written before the upload). PH3b's scheduled sweeper is the intended fix.
3. **Failed sweep is only retried by PH3b.** Until the scheduled function is DEPLOYED (built 2026-10-05, see "PH3b scheduled sweeper: accepted limits"), a sweep that fails (Storage outage)
   leaves the marker with `attempts` and `lastError` and nothing re-drains it.
4. **Batch/ops reject inventory deletes** (400 `cascade-delete-not-allowed`, whole request, zero writes): they cannot
   write the marker without breaking their write-ceiling arithmetic. No client sends one today (bulk import is
   create-only). Revisit when an atomic product delete is built.
5. **Existing e2e `test_upload_rejects_a_productId_containing_a_path_traversal_slash`** still expects `invalid-request`;
   the whitelist did not change that error code.
6. **E2E helper vacuity (found 2026-10-03, PR #113 CI).** `E2EHelpers.pollEmulatorDoc` starts with `latest = null`, so a
   `d === null` ("doc is absent") predicate passed on the first tick, before any response arrived. It hid a real failure:
   the cascade test deleted from a client cache with no `photoIds` (photos were uploaded by direct POST), the server
   returned 409 and the Gateway dropped the delete as stale (same family as item 1). Fixed for the photos tests via the new
   optional `requireResponse` argument (absence checks must pass `true`). **Still vacuous, deliberately not touched in this
   PR:** `tst_InventoryE2E.qml` (the product-delete check, ~line 262) and `tst_BulkImportChunkingE2E.qml` (~line 154). Making
   `requireResponse` the default would make them honest but could turn them red; do it as its own small PR.

---

## Product delete is destroy-before-ack (found 2026-10-04, PR #113 device test) — photo part FIXED, batches/activity/queue NOT

**Symptom:** device A uploads a photo while device B deletes the product (9 photos). Result: product still listed, 3 photos shown,
4 objects in Storage, Activity says deleted, batches gone.

**Root cause:** `InventoryStore.deleteProduct` starts irreversible side effects without waiting for the server's answer to the
product delete. A's upload changes `photoIds`, B's CAS `before` is stale, the delete 409s and the product survives (the
`_onMutationConflicted` restore is the "reappeared"). Meanwhile B had already sent one `deleteProductPhoto` per cached photo
(PH4 item 3 of the design, not yet built in PH3-only PR #113), which removed ids and objects from the surviving product. The
server upload path is NOT at fault: it 404s on a missing product.

**Fixed (branch `fix/2026-10-04-pr113-upload-delete-race`):** removed the client photo loop; photos are removed only by the server
sweep after a committed delete. Pinned by e2e `test_stale_delete_409_keeps_the_product_and_every_photo`.

**BC1 (server) implemented 2026-10-05 (branch `feat/2026-10-05-bc1-server-batch-sweep`, not yet deployed):** after a committed
product delete the server now also removes the product's `stock_batches` (queried server side by `productId`, chunks of 100,
one `cascade~{productId}~{batchId}` audit entry per batch) before it sweeps the Storage prefix, driven by the same
`pending_cleanup` marker. The marker now carries `actorUid`/`actorRole`/`requestId`. `recordMutation` gained an owner/admin gate
on `inventory` delete (403 `role-not-allowed`). Items 1-3 below stay open until BC2 (client) lands AND BC1 is deployed.
**PH3b review 2026-10-05 (design only, nothing changed in code):** `index.js` `updateMarker` uses `set(patch, {merge:true})`, which re-creates a marker another sweeper just deleted as a partial doc. Dormant today (one sweeper); it becomes real the moment PH3b runs beside the handler, so the PH3b slice S-B fixes it with `update()`. Do not deploy a scheduler without that fix.
**PH3b second review 2026-10-05 (PR #125):** (R1, fixed in design) a single unordered `limit(500)` read would let parked markers starve new ones; now paged (`PAGE_SIZE` 200 x `MAX_PAGES` 10). (R2) PRODUCTION BLOCKER: the Cloud Monitoring alert on `PH3B_ALERT` logs must exist and pass test DV-9 before any production data (runbook `specs/2026-10-05-ph3b-alert-runbook.md`). Alerts reach email / Google Cloud console mobile app, not the Karobar app.
**New limits created by BC1:** (a) a failed batch sweep leaves the marker and WAITS for PH3b (no replay re-sweep, Q-BC-9 = no);
batches are money data, so PH3b must not silently abandon a capped marker. (b) Until BC2 ships, an old client still sends its own
`stock_batch` deletes; they answer 409 `current: null` after the sweep (harmless, no toast). (c) A direct token call by
manager/staff to delete a product now gets 403 (the UI never sends it). (d) PR #118 review C1: the `cascade~` audit-id prefix is reserved (400 `invalid-request-id`); `recordMutation` / `recordDelta` still do NOT validate the rest of `requestId` / `entityId` (no `/` or length check, unlike `operationLogic.isSafeDocId`): pre-existing, flagged here, fix on its own branch.

**Still open, same family (items 1-3 close with BC2; decide before PH4):**
1. Batch deletes are sent before the product delete is acked -> after a 409 the product has no stock batches. Options: (a) gate
   batch deletes on a Gateway "applied" signal (new ack plumbing, per-mutation); (b) one atomic `recordOperation` for product +
   batches (the delete roadmap item, larger, also removes the `photoIds` CAS problem); (c) accept for dev. (b) is correct, (a) is a patch.
2. `ActivityLog.record("product_deleted")` is written locally at click time even when the delete is rejected.
3. `PhotoQueue.discard` of this device's queued photos runs before the ack: a rejected delete loses the user's pending photos.
4. A delete 409s on any concurrent `photoIds` change (F5 family); the user retries after the restored row appears.

## PR #118 device test (2026-10-04): four observations. Root causes from CODE READ, not reproduced on a device

**Setup:** add a product with a description over 1 MiB; edit it; wait 3 min; restock it; delete it.

1. **Edit of a >1 MiB description is rejected 3 min later and the glass header shows the rejected list.** Not a new bug: the client has no size cap on `description` (nor on any text field) and the server write is refused (Firestore documents are capped at about 1 MiB; exact status/response UNVERIFIED), so the write is parked as a server rejection (S2b) and listed. Open: decision D1 (cap length client-side and server-side).
2. **Restock confirm: dialog never closes, Confirm and Cancel dead, other fields still editable.** `RestockDialog.onPrimaryClicked` sets `busy = true` and clears it only in the callback of `InventoryStore.restock` -> `Gateway.recordDelta`. The parked edit from (1) HOLDS the key `inventory/{productId}` (`OutboxStore.dueItems`: a parked item claims its keys; later writes for the same record wait behind it), so the restock delta is never due, its callback never fires, `busy` stays true. Meanwhile `StockBatchStore.addBatch` runs in parallel on a different key and DOES land: **a batch exists but the product's stock was never incremented** (stock vs batch ledger drift). Open: decision D2.
3. **Delete while the edit is parked: batches deleted, product and rejected list intact.** Same held key: the product delete waits behind the parked edit and is never sent, while the per-batch `stock_batch` deletes (other keys) go out at once. This is exactly the destroy-before-ack bug; BC2 (this branch) stops sending batch deletes, so nothing is destroyed on the server any more. New consequence (decision D3): the product vanishes from the local list while its delete sits behind the parked write; if the user then discards the parked edit, the delete goes out with the stale local `before` (which still contains the rejected edit) and answers 409, so the product returns (with its batches, after the resync) and the user must delete again.
4. **Rejected list stays after the delete.** By design: a parked write is released only by Retry or Discard (S2b/S3), and a later delete of the same record does not touch it.

**Status (updated 2026-10-04, PR #119):** (3) fixed in the batch part by BC2 (BC1 deployed per Taher). (1) **accepted as is** (D1: no size cap in the app). (2) and (3-consequence) **fixed by refusing up front** (D2, D3, commit `2362d9d`): restock and delete show "Fix or discard the stuck change for this product first" while the product has a parked write, and write nothing. **Order completion (2026-10-04, PR #121, decision B):** `_tryCompleteOrder` now refuses up front when a line's product has a parked write (same message; order stays `pending`; nothing consumed or queued). Cause (code read, repro = red-by-design E2E in `tst_OrdersE2E.qml`): the parked item claims `inventory/<id>` in `OutboxStore.dueItems`, so `deductStock`'s delta never sends, its callback never fires, `_completingOrderIds` stays set and FIFO batches drift from `product.stock`. Cost accepted by Taher: a counter sale is blocked until the parked edit is Retried or Discarded (advice was to bypass). **Still open (same hang, UNVERIFIED, not guarded):** `_tryAdjustOrder` (returns/exchanges: `deductStock`, `creditStockNoBatch`), `completeImportedOrder`, and the `creditStockNoBatch` failure-path credit inside `_afterAllDeltas`. A product with a parked write cannot be restocked, deleted or sold until the user Retries or Discards it (intended).


## Unsynced product edit (PR #121 follow-up, 2026-10-05)
- **Fixed in `feat/2026-10-05-unsynced-edit-ledger` (CI unverified):** a product edit's `field_change` / `stock_adjustment` rows and its Activity entry no longer register when the server rejects the edit; a sale is refused while the product has any queued edit.
- **S4 done in PR #122 (CI unverified):** server reads overlay queued AND parked edits (changed fields only) and the product card / edit dialog show a "Not synced" / "Rejected" badge. A queued CREATE is not injected into a read after a relaunch (the product is missing from the list until the create syncs): roadmap.
- **Open (roadmap, decision Q3):** `created`, `purchase`, `photo_change`, `sale`, `return`, `price_adjust` ledger rows still register before their parent write is acked (same bug as device observation 1). Needs `recordEdit` + `dependsOn` per call site.
- **Open:** Activity `product_updated` for an edit is in-memory until the ack; an app death between edit and ack drops the entry (the ledger rows survive).
- **Fixed in PR #122 (CI unverified):** a product doc over 1 MiB (`DocLimits`, estimate with a 4 KiB reserve) is refused before anything is queued; the dialogs pre-check. Gap: bulk import (`ImportPreviewDialog`, `recordMutations`) has no size check; an oversize row is still rejected by the server and removed by `_onBatchMutationFailedPermanently`.
- **Verified by code read (PR #122):** every send path (single, batch, delta, operation) ends in `Gateway._reschedule()` after a conflict or permanent drop, so `pruneOrphans` runs. Not run.
- **Open (found in PR #121 final sweep, 2026-10-05):** (a) the sale guard counts a queued CREATE and a queued edit made OFFLINE as "unsynced": an offline edit, or a product added offline, cannot be sold offline until it syncs (decision Q1 = Z, accepted; real cost for an offline-first counter). (b) Device-test cases 4.2, 4.3, 4.4, 4.10 of `2026-10-05-unsynced-edit-ledger-test-plan.md` forced a server rejection with a > 1 MiB description; the client cap now refuses that up front, so no verified on-device way to force a rejection exists. Pick one before testing.


## PH3b scheduled sweeper: accepted limits (BUILT 2026-10-05/06, NOT DEPLOYED)

Code: S-A #126, S-B #127 (merged); e2e S-C (this branch). Found in the PR #126/#127 final sweeps; none changed in code on purpose.

- **M1 env order.** Envs run `dev`, `test`, `prd` and share ONE 240 s budget. Many slow dev/test sweeps in a single run could defer `prd` markers to the next run. Needs many slow sweeps at once; backoff caps retries at 30 min. One-line fix exists (`["prd","test","dev"]`, plus edits to ~17 order-sensitive test assertions). Decision: keep, reopen if `deferred` is ever non-zero for `prd` in the logs.
- **M2 no per-sweep timeout.** One sweep started at ~239 s can reach the 300 s function timeout. Safe: every step is idempotent, `attempts` is not bumped, the next run retries.
- **M3 parked markers are never deleted** and count toward `MAX_SCAN` (2000). Only an unrealistic number could hide new ones; ERROR `PH3B_ALERT backlog` fires first. Humans clear parked markers (un-park or delete).
- **M4 false `park-failed` alert.** If `updateMarker` hits NOT_FOUND at attempt 11 (a concurrent sweeper deleted the marker) `park` also NOT_FOUNDs and raises a false alert. Needs 11 failures plus a race.
- **M5 summary `parked`** counts already-parked + capped markers, not newly parked malformed ones (those are in `malformed`).
- **E2E cannot prove (DV-1..DV-9 on a real project do):** the no-index claim, cursor-without-`orderBy` on the real Admin SDK, structured-log field names in Cloud Logging, Cloud Scheduler location for `asia-south1`, `maxInstances` on a scheduled function, the alert policy.
- **Deploy drift:** the P3 `update()` fix is in `recordMutation`'s shared module. Deploy ALL functions, not only the new one.
- **Production blocker (Q-L):** the log-based alert (runbook `specs/2026-10-05-ph3b-alert-runbook.md`) must exist and DV-9 pass before production data relies on the sweeper.
