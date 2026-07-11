# Known Issues

Running log of accepted, non-blocking issues deferred for later. Each entry: what's
broken, where, why it was deferred, and leads for a future fix.

---

## Leave-workspace: self-leave rule staged but not deployed

**Status:** Partially shipped (2026-06-12). Re-login bug is fixed in code now; clean
member-doc auto-removal awaits a Firestore rules deploy.

**What works without any deploy:** `leaveCurrentTenant()` clears the tenant pointer
(`tenantId`/`role`/`tenants[]`) on the leaver's own `users/{uid}` doc — a self-write
allowed by current live rules. This fixes the main bug (re-login no longer rejoins the
empty workspace; the user correctly lands on onboarding).

**What's deferred (needs a rules deploy):** `firestore.rules` adds a clause letting a
member delete their OWN non-owner membership (`tenants/{tid}/members/{uid}` where
`uid == request.auth.uid`). Until `firebase deploy --only firestore:rules` runs, that
self-delete is denied (403), so the leaver's member doc lingers as `status: active`.
Cosmetic only — the owner can remove the ghost member via Member Management under
current rules.

**Why not deployed now:** the repo `firestore.rules` also carries the **P0 ledger
lockdown** (`audit_log`/`transactions`/`stock_batches`/`stock_movements` → `write: if
false`). `Gateway.mode` is still `"direct"`, so the client writes those collections
directly today; deploying the repo rules before the P0 cutover would DENY those writes
and break restock/stock ops. Rules deploy is free (Spark) — the blocker is functional
(P0 not cut over), NOT the Blaze/Cloud-Functions billing requirement (functions are a
separate `--only functions` deploy).

**When to deploy:** at the P0 cutover, when `firestore.rules` ships as a unit and
`Gateway.mode` flips to `"gateway"`. The self-leave clause goes live then for free. See
the P0 compliance gateway spec.

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

