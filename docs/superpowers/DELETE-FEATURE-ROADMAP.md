# Delete feature — roadmap for next session

Everything in `docs/2026-09-02-batch-cleanup-on-delete-design` (PR #65) that's confirmed working
is tracked in `docs/superpowers/KNOWN-ISSUES.md`, not repeated here. This doc is only the
**pending** work this PR's investigation surfaced but didn't fix — ranked by importance, for
whoever picks this up next.

## 1. `Gateway._send` retries a failed mutation forever, silently — HIGH

Not delete-specific, but this PR's own root-cause traces (Skill 60, the batch-CAS-conflict fix)
ran straight into it: a mutation that fails for a real, non-conflict reason (network error,
permission rule change, a genuine server bug) retries with backoff **indefinitely**, with no
terminal-vs-transient classification and no signal back to any caller. First flagged from the
chunked-batch-import work, re-confirmed relevant here. Silent, unbounded retry of a failed write
is a real data-integrity risk across every entity this app writes — not just deletes — which is
why this ranks above the two delete-specific items below despite being the oldest, already-
deferred-twice item on this list.

**Why it's still not fixed**: real, separate work — rewriting shared retry/classification logic
used by every mutation of every entity, not a delete-ticket-sized change.

## 2. Staff delete has no row-level button — MEDIUM

Identical gap to what products and orders had before this PR: `StaffStore.deleteStaff()` and its
confirm-dialog wiring already exist and work (same as the products/orders logic did originally);
there's just no button in the row template to trigger it. The exact fix pattern is proven twice
over in this PR (`ProductCard`, orders row) — this is the lowest-effort item on this list.

**Why it's still not fixed**: out of the original ask's scope (products and orders only).

## 3. Five Sales Analysis tabs mislabel a deleted product's historical rows — MEDIUM

Value, Purchased, Revenue, Sold, and Profit's Realised sub-mode all keep **correct totals** after
a delete (they walk the immutable event/batch ledger directly), but a deleted product's row in
their by-category breakdown shows "(uncategorised)" instead of its real category, and its by-name
breakdown shows the raw `productId` instead of the product's name. Root cause is different from
everything else on this list: none of these historical/breakdown paths stamp category or name
onto the transaction record at the time of the sale — they re-look-up against the live product
catalog every time, which fails once the product is gone.

**Why it's still not fixed**: the real fix means stamping category/name onto every transaction/
consumption record at creation time — a schema-level change across every write path that creates
one. Genuinely bigger and different in kind from the read-side guard fixes this PR shipped, not
a one-line addition.

## 4. Photo cleanup on delete — unverified, not blocking

`InventoryStore.deleteProduct()` calls `StorageService.deleteProductPhoto()`, guarded in a
try/catch. Correct by code trace, but **not confirmed on-device** — no Storage plan is enabled
in this environment right now, so there's nothing to actually verify against. Re-test once a
Storage plan is active; until then this is a known verification gap, not a known bug.

## Closed, not pending — recorded here so it isn't re-raised

- **Backfill for batches orphaned by deletes that happened before this PR shipped**: not needed.
  Dev environment only; Firestore gets cleared and re-verified from scratch each time, so there's
  no real backlog of pre-existing orphaned batches to backfill. Revisit only if this ever matters
  in a real environment with production data predating this fix.
