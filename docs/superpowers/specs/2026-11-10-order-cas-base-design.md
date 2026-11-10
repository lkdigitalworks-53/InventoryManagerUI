# Design: the CAS base of an order is the exact server image (PR #186 device test, 2026-11-10)

## Report
Taher changed `quantity` of a line inside `products` in the Firestore console, refreshed the app, set the order to completed and saved. The status did not change and every later edit, completion and delete of that order answered "updated elsewhere - your change didn't save". A refused delete still wrote an "Order deleted" Activity entry. Products did not show it.

## Facts (read from code)
- F1. `applyMutation` (`functions/lib/gatewayLogic.js`) and `recordOperation` (`operationLogic.js`, line 404) answer 409 unless the stored doc deep-equals the client's `before`.
- F2. The client built `before` from `_clone()` -> `_normalizeOrder`, which recomputes items, subtotal, discount, tax, taxBreakdown and total from the lines, drops unknown keys and fills defaults.
- F3. So a stored order that is not its own `_normalizeOrder` (a hand-changed quantity with untouched totals, an extra field, an older build's shape) can never match. Every retry rebuilds the same wrong `before`: the conflict repeats for ever. `_onMutationConflicted` fed the server's answer back through the same rebuild, so it did not help.
- F4. The completion goes through `buildOrderUpdate` (via `_completionHooks`), so it hit the same compare.
- F5. `deleteOrder` wrote its Activity entry at tap time. Products write it on `Gateway.mutationApplied` (BC2).
- F6. `FirebaseService._decodeDoc` adds no key of its own, so a decoded doc is a valid exact `before`.

## Decisions (vetoable in the PR)
- D-1. Keep an exact image of each order as the server holds it (`_serverBase`), fed by load, refresh (private buffer, swapped in on commit), conflict (`current`), remote result, and set to the sent `after` on every local write. `before` = a copy of that image; no entry = the rebuilt copy (old behaviour).
  Rejected: a lenient server compare (weakens the guard that protects against real races); sending `current` back on a conflict and retrying automatically (hides real races, loops on a real concurrent edit); normalising the stored docs with a migration (nobody can run it on a hand edit made tomorrow).
- D-2. After one accepted write the doc is canonical again (`after` is the rebuilt doc). Side effect, by design: the first app save recomputes the totals from the lines, overwriting a hand-edited total. The lines are the source of truth.
- D-3. Every internal write of `orders` goes through `_setOrders`; `onOrdersChanged` drops all bases and pending deletes for a write from anywhere else (tests, future code), so the base can never outlive a list it did not see.
- D-4. Delete: the Activity entry is written on `mutationApplied` only; a conflict, a parked-write discard and `clear()` drop the pending entry. A delete that merges into a still-queued create never reaches the server and logs nothing (same as products).
  Cost: an offline delete shows no Activity entry until the server confirms.

## Not done / limits
- A base entry is a second copy of each order (memory about doubles for the order list). Fine at this size; revisit with paging.
- Products, suppliers, staff and batches rebuild `before` too. They were not reported; checking each store's stored shape against its rebuild is a follow-up (own PR).
- The same failure for a field type the decoder maps to null (a Timestamp typed by hand in the console) is not covered: the decoded `before` has null, the server has a Timestamp.
