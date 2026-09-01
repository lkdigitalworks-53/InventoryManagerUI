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

## Sandbox capability: qmltestrunner *can* run here — Skill 54 supersedes the earlier blanket "no toolchain" assumption

`feature/product-order-delete-ui`'s 5 new/extended test files (`tst_DataModel_deleteGuards.qml`,
`tst_InventoryStore_mutationConflicted.qml`, 2 cases added to `tst_OrdersStore_sync.qml`,
`tst_InventoryPage_deleteButton.qml`, `tst_OrdersPage_deleteButton.qml`) were all written and
committed as "NOT RUN IN THIS SANDBOX," carried over from an earlier standing assumption that this
sandbox has no Qt toolchain at all. `main` picked up SKILLS.md Skill 54 (merged after that
assumption was written) documenting the opposite, checked and confirmed rather than assumed: a
real `qt6-declarative-dev` + `qml6-module-*` set installs cleanly from this sandbox's existing apt
allowlist, and a prior session's full suite run got **315 passed, 22 failed** headless
(`QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests -platform offscreen`), with
every failure traced to a specific Qt-version mismatch (6.4.2 here vs 6.8 on CI/Taher's machine),
not a real regression.

**Two of this session's five new files are the first page-level UI-interaction tests in this
repo's suite** (`tst_InventoryPage_deleteButton.qml`, `tst_OrdersPage_deleteButton.qml`) — exactly
the kind of new-pattern risk Skill 54's install would let someone actually confirm instead of
guessing at.

**Decision:** flagged here rather than acted on unprompted this session — installing the toolchain
and running the actual suite is real, separate work with its own tool-call budget, outside what
was asked for in the rebase-and-push task this entry was written during. Recommend doing this
before merge, specifically for the two new UI-interaction files, using Skill 54's already-proven
package list and invocation rather than rediscovering it.

---

## Housekeeping: a memory-recorded active branch doesn't exist on the remote

Noticed, not chased down: prior-session memory records `fix/chunked-batch-import-over-200-rows` as
an active branch. It isn't on `origin` — the closest match by name and apparent scope is
`fix/bulk-import-chunking-durable-status`. Worth Taher confirming which one is actually current;
unrelated to `feature/product-order-delete-ui`, not investigated further here.


