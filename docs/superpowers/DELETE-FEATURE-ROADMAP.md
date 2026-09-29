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

**Status 2026-09-19 (PR #75): surfaced, not resolved.** A stuck write now raises one toast and a persistent
`GlassHeader` caption line (all three senders); retry, backoff and dropping are unchanged. Still open:
Retry/Discard for a stuck write, and server-side error classification. Details in `KNOWN-ISSUES.md` and
`docs/superpowers/specs/2026-09-19-gateway-stuck-write-indicator-design.md`.

**Status 2026-09-28: decided, next up.** Remaining scope is (C) server-side error classification, then (B) park +
Retry/Discard. Taher chose **C first** (client still never drops), Discard = **re-pull from Firestore**, parked flag
**persisted**, UI = **tappable header caption -> dialog**. Trace, trade-offs and decisions:
`docs/superpowers/specs/2026-09-28-gateway-stuck-write-retry-discard-options.md`.

**Status 2026-09-28 (later): part C implemented, PR pending review.** Taher chose option B for the signal: status stays
500, body `error` = `write-rejected` / `write-unavailable` / `write-failed` (distinct 4xx would make the delta/operation
senders drop the write, Skill 74). Client labels rejected stuck writes in the header caption; nothing dropped.
Design: `docs/superpowers/specs/2026-09-28-gateway-write-error-classification-design.md`. **Next: (B) park +
Retry/Discard.**

**Status 2026-09-29: part B scoped, not built.** Four sequential slices (dialog + Retry-now, park + persist, Discard + resync,
cleanup). Two corrections to earlier notes: Party / Category / OrderChannel never go through `Gateway`, so they are out of B;
the existing `syncFromFirebase()` full resync is the Discard re-pull. Plan and open decisions:
`docs/superpowers/specs/2026-09-29-gateway-park-retry-discard-plan.md`.

## 2. Staff delete has no row-level button — MEDIUM

Identical gap to what products and orders had before this PR: `StaffStore.deleteStaff()` and its
confirm-dialog wiring already exist and work (same as the products/orders logic did originally);
there's just no button in the row template to trigger it. The exact fix pattern is proven twice
over in this PR (`ProductCard`, orders row) — this is the lowest-effort item on this list.

**Why it's still not fixed**: out of the original ask's scope (products and orders only).

**Status 2026-09-21: RESOLVED** (`feat/2026-09-21-staff-delete-ui`). Row-level button shipped with the same
idiom. Two adjacent gaps closed alongside it: `StaffStore._onMutationConflicted`'s delete-specific toast
wording, and a client-side self-delete guard. One new gap found and given a narrow fix: `recordMutation` had
no server-side role check for staff/delete (or any entity/action) — fixed for staff/delete only; the general
gap is tracked as its own KNOWN-ISSUE. Details: `docs/superpowers/specs/2026-09-21-staff-delete-ui-design.md`.

**Follow-up 2026-09-25 (same branch, found on-device):** deleting a staff member blanked their name from their
orders (detail, export, analysis) and could wipe the order's attribution on save; fixed with a `removed_staff`
tombstone + one shared resolver. Details: `KNOWN-ISSUES.md`, test plan section 5, Skill 70.

## 3. Five Sales Analysis tabs mislabel a deleted product's historical rows — MEDIUM — RESOLVED 2026-09-26

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

**Status 2026-09-26: RESOLVED, branch `fix/2026-09-26-sales-analysis-deleted-product-labels`.**
Traced to source — the two halves were not the same size. `productName` was already stamped on
every `TransactionStore` entry at creation time, so the by-name half was a small, contained
**read-side** fix. `category` was genuinely never stamped anywhere, so that half got the
**write-path** change originally scoped here, plus reusing the original sale's stamped category for
returns/adjustments on an already-deleted product. Also fixed in the server-side parity port
(`functions/lib/`), which had the identical bug. Full detail, a real precedence bug the Node test
suite caught pre-merge, and two adjacent-but-out-of-scope findings: `KNOWN-ISSUES.md` and
`docs/superpowers/specs/2026-09-26-sales-analysis-deleted-product-labels-design.md`.

## 4. Photo cleanup on delete — unverified, not blocking

**Status 2026-09-28: unblocked soon.** Storage plan is now active and the product-photos branch
(`feature/2026-09-21-product-photos-firebase-storage`) works; Taher expects it to merge within days. Queued as the next
priority after item 1's C and B, and pulled forward once that branch lands. It is an on-device check, not a build.

`InventoryStore.deleteProduct()` calls `StorageService.removeProductPhoto()` per `photoIds` entry (renamed by the photos PR;
this text said `deleteProductPhoto()`), guarded in a try/catch. Correct by code trace, but **not confirmed on-device** — no Storage plan is enabled
in this environment right now, so there's nothing to actually verify against. Re-test once a
Storage plan is active; until then this is a known verification gap, not a known bug.

## Closed, not pending — recorded here so it isn't re-raised

- **Backfill for batches orphaned by deletes that happened before this PR shipped**: not needed.
  Dev environment only; Firestore gets cleared and re-verified from scratch each time, so there's
  no real backlog of pre-existing orphaned batches to backfill. Revisit only if this ever matters
  in a real environment with production data predating this fix.
