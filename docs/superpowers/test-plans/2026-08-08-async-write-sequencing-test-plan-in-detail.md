# Test plan — fix/async-write-sequencing-review-fixes

**Covers:** all 15 commits on this branch — the 8 Critical fixes from the 2026-08-06 code review
(`docs/superpowers/specs/2026-08-06-async-write-sequencing-code-review.md`): the `_normalizeOrder`
consumption-lineage bug (C1), the `locks/**` Firestore rules lockdown (C2), client-side CAS conflict
handling wired into all 5 stores (C3), `restock`/`creditStockNoBatch` converted to atomic deltas
(C4), FIFO batch rollback on rejected deltas (C5), status-aware lock-denial classification (C6),
deletion of a dead/dangerous duplicate order-approval path (C7), and removal of PII-leaking debug
logging (C8).

**Does not duplicate** `2026-07-14-test-plan.md` / `2026-07-17-test-plan-part2.md` — those cover
id-minting, import stock-checks, and duplicate-row handling on a different branch. This plan is
scoped entirely to concurrency/locking/CAS/delta behavior, which those two docs don't touch at all
except incidentally (their H26/H27/N15 cover *stock-sufficiency* on order adjustment, not
*concurrency* on it — different bug class, no overlap). Baseline create/add flows (Add Product, Add
Staff, Add Order, Add Supplier, imports) are assumed already covered by those two docs and are not
re-tested here except where this branch specifically touches them (it doesn't, except restock and
order/product/staff *editing*, not creation).

**Read this first:** every fix here was verified by either (a) a real, unmodified execution —
`functions/`'s Node test suite (87/87), and the real `applyMutation`/`applyDelta` server logic run
directly against a fake-Firestore double — or (b) a throwaway Node script extracting the exact QML
logic and testing it in isolation, since **no Qt toolchain exists in the sandbox this was built in.**
Nothing QML-side has run under a real `qmltestrunner`, and nothing in `firestore.rules` has run
under the Firebase emulator. This is real coverage of the *logic*, not proof the *QML wiring*
(signals, bindings, `Component.onCompleted`) is free of a syntax or runtime issue Qt's own engine
would catch. Section 3 is where that gap actually closes — prioritize it, especially given a
production issue was already reported on this branch (order editing) before this plan was written.

---

## 1. Unit tests

### 1.1 Already covered (automated)

`functions/test/gatewayLogic.test.js` + `lockLogic.test.js` — 87 cases across the whole
`functions/` suite (not just these two files), confirmed passing via a real `node --test` run,
before and after every change in this branch. No new cases added specifically for this branch's
fixes (C8 only removed debug logging, no logic changed) — the existing 87 already covered
`applyMutation`'s CAS check and `applyDelta`'s floor/clamp behavior thoroughly.

`tests/tst_Gateway.qml` — grew by 6 new test functions:
- `_parseMutationConflict`: recognizes a genuine `409 + conflict:true` response; ignores a 409
  *without* the conflict flag (belt-and-braces, in case a future endpoint reuses 409 for something
  else); ignores every non-409 status (400/401/403/500) — these must fall through to the existing
  retry path unchanged; handles a malformed or empty response body safely (no throw).
- Fixed one unrelated stale test found as a byproduct: `test_mode_defaults_to_direct` asserted the
  wrong default (`Gateway.mode` was flipped to `"gateway"` in an earlier commit; this test was never
  updated and would have failed the first time anyone actually ran the suite).

`tests/tst_LockManager.qml` — grew by 4 new test functions: `_classifyAcquireResponse` at
400/401/403/500, each asserting `reason === "error"`, not `"denied"` — the exact status-branch
coverage this file was missing before (every existing case only ever used status 404 or 409).

`tests/tst_OrdersStore_normalization.qml` — grew by 2 new test functions: FIFO consumption lineage
survives normalization when the product exists but carries no `consumption` field of its own (the
silent-data-loss case); normalization doesn't throw when a line's product is absent from
`InventoryStore` entirely (the crash case — simulates a deleted product or a legacy line with no
`productId`).

Run: `qmltestrunner -input tests/tst_Gateway.qml tests/tst_LockManager.qml
tests/tst_OrdersStore_normalization.qml tests/tst_OutboxStore.qml` and `node --test` inside
`functions/`.

### 1.2 Gap — not covered by any committed test, recommend closing soon

- **The `_onMutationConflicted` handlers themselves** (all 5 stores) have no dedicated QML test.
  The shared find/patch/append/remove logic they all wrap was verified via a Node simulation
  (4 cases: patch existing, append unknown id, remove deleted, no-op removing an already-absent
  id) — genuine coverage of the *algorithm*, but not of the actual QML function, the `Gateway`
  signal connection, or the `Toast.show()` call. Recommend a `tst_MutationConflict.qml` (or 5
  small additions to each store's own future test file, if any get created) directly invoking
  each store's `_onMutationConflicted("<entity>", id, current)` and asserting the array patched
  correctly — these are pure enough to test this way without a network layer.
- **`test/firestore.rules.test.js`'s new `locks` coverage** (6 new test functions: member
  read/write denied, owner/admin read/write denied — no role bypasses this, and the
  wildcard-guard-in-isolation test) has never run under the Firebase emulator. Run
  `firebase emulators:exec --only firestore "node --test test/"` before trusting this fully — this
  is the ONE piece of verification in this whole branch that on-device testing (Section 3) cannot
  substitute for, since it's specifically about what a *malicious or buggy client* can do, not
  what the app itself does.
- **`StockBatchStore`'s `consumeFifo`/`topUpOldest`/`restoreFifo`** have zero delta-specific test
  coverage — true before this branch too, and still true after, since they were NOT converted to
  `recordDelta` (that's a still-open gap, see Section 2's "changed on purpose" note below for what
  IS different about them this round despite not being converted).
- **`InventoryStore.restock`/`creditStockNoBatch`'s new delta call shape** was verified against the
  real `applyDelta` (pure-addition delta, empty floors/clamps, idempotency, stacking) — genuine
  server-side coverage — but there's no `tst_InventoryStore.qml` exercising the QML function
  itself (the supplier-resolution sequencing, the `ActivityLog`/`TransactionStore`/
  `StockBatchStore.addBatch` side effects firing only after delta confirmation).

---

## 2. Regression tests

Nothing in this list should have changed behavior for the single-user, no-conflict case — this
branch's whole point was to fix what happens *around the edges* (concurrency, conflicts, lock
denials), not the core save path itself. **Two items are marked "changed on purpose"** — not bugs,
don't report them as regressions.

- [ ] A single-device edit to an order (qty, price, customer info, status) with no contention from
      any other session still saves successfully and reflects immediately in the UI — the
      success path in `Gateway._send` (`status 200-299`) is byte-for-byte the same code as before
      this branch; if this is broken, it's not an intentional behavior change, see Section 4's
      priority order.
- [ ] Same for a single-device product edit (name/price/category/stock-threshold fields via
      `EditProductDialog`, not restock).
- [ ] Same for a single-device staff edit.
- [ ] Same for a single-device supplier edit.
- [ ] Restock, no concurrency: stock still increases by the entered amount, `ActivityLog` entry
      still appears ("Restocked: X · +N · now Y in stock..."), `TransactionStore` purchase record
      still created, a new `StockBatchStore` batch still appears, supplier attribution (existing
      or newly-typed name) still works, `reason` field is still optional. **Changed on purpose:**
      these side effects (log/transaction/batch) now fire only *after* the server confirms the
      delta, not optimistically before it — under normal (fast, successful) network conditions
      this should be visually indistinguishable, but don't be alarmed if there's a beat of delay
      between tapping Confirm and the activity log entry appearing that wasn't there before.
- [ ] Return/exchange via `ConfirmReturnSheet`, no concurrency, sufficient stock: still applies
      exactly as before — quantity/price adjustment reflected, refund amount correct, stock
      credited back.
- [ ] `OrdersPage`'s "Approve all" button (the real, still-present `_approveAllPending()`) still
      works exactly as before — confirm this specifically, since a *different*, dangerous
      implementation of "approve all" was deleted this branch (`OrdersStore.approveAllPending()`,
      which was dead code, never reachable from the UI) — make sure the one users actually press
      is unaffected.
- [ ] Opening any of the three lock-wired dialogs (`OrderDetailDialog`, `EditProductDialog`,
      `StaffDetailDialog`) for read-only viewing (open, look, close without editing) is still not
      blocked by anything — locking only ever gates Save, never opening/viewing.
- [ ] Dashboard KPIs, list/detail views, exports, category/order-channel management, RBAC gates —
      all untouched by this branch, spot-check rather than exhaustive.
- [ ] Add Product / Add Staff / Add Order / Add Supplier / Import — this branch didn't touch any
      creation path, only editing/restocking/returning. Spot-check one creation flow to confirm
      nothing adjacent broke, don't re-run the full 07-14/07-17 plans.

---

## 3. On-device tests

### 3.1 Happy path

| # | Flow | Steps | Expect |
|---|---|---|---|
| H1 | Modify order, lock granted | Open an order → edit quantity or price on a line → Save | Lock acquires silently in the background while the dialog is open; Save succeeds; change persists after closing and reopening the order |
| H2 | Modify order, second device views while first edits | Device A opens order, starts editing. Device B opens the *same* order (view only, doesn't try to edit) | Device B can view freely — locking never blocks reads. Device A's edit is unaffected by B viewing |
| H3 | Modify product | `EditProductDialog` → change name/price/category → Save | Same lock-then-save pattern as H1, succeeds normally |
| H4 | Modify staff | `StaffDetailDialog` → change role/department → Save | Same pattern, succeeds normally |
| H5 | Restock, single device | Product detail → Restock → enter qty → Confirm | Stock increases by exactly the entered amount; activity log/transaction/batch all appear (see Section 2) |
| H6 | Restock, two devices, same product, no overlap in time | Device A restocks product X by +5, waits for confirmation. Device B then restocks the same product X by +3 | Final stock = original + 5 + 3, both restocks show correctly in the batch/activity history — nothing overwritten |
| H7 | Restock, two devices, same product, genuinely concurrent | Device A and B both tap Confirm on a restock of the *same* product within roughly the same second (+4 and +6 respectively) | **The core new behavior this branch adds.** Both deltas apply — final stock = original + 4 + 6, not just one of them. Neither device sees an error or a lock conflict, since restock never acquires a lock and doesn't need to (deltas are commutative) |
| H8 | Return, sufficient stock | `OrderDetailDialog` → adjust → reduce a line's quantity → `ConfirmReturnSheet` → confirm | Order updates, refund amount correct, stock credited back, no lock-related messaging anywhere in this flow (see N-series below for why) |
| H9 | Exchange, sufficient stock for the added units | Adjust an order, increase one line's quantity by an amount well within current stock → confirm | Succeeds exactly as before, stock deducted for the net increase, FIFO batch(es) show the new consumption |
| H10 | Lock denied, legitimate | Device A opens an order and is actively editing (dialog stays open). Device B opens the *same* order and attempts to Save a change | Device B's Save is blocked with an accurate "someone is editing this" — style message naming Device A's user if available. Device B's edit does NOT silently apply |

### 3.2 Negative tests

| # | Scenario | Expect |
|---|---|---|
| N1 | Force a genuine write conflict — Device A opens an order, leaves the dialog open for several minutes without saving (long enough for Device B to complete a full edit-and-save cycle on the same order in the meantime), then Device A finally taps Save | Device A's save is dropped, not silently retried forever — a Toast appears explaining the order was updated elsewhere and didn't save, and the order detail refreshes to show Device B's actual current values. Confirm by waiting a further 15-20 minutes and checking there is no repeated network activity for that same stale write (the old bug: this used to retry every ~10 minutes indefinitely) |
| N2 | Same as N1, but for a product edit instead of an order | Same Toast pattern, same reconciliation, same "no repeated retries afterward" check |
| N3 | Same as N1, for staff and supplier edits | Same pattern for both |
| N4 | Force a lock-acquire error that ISN'T a real denial — e.g. leave the app backgrounded/idle long enough for the auth session to go stale, then open an order and try to Save | Message should describe a connection/auth problem generically ("couldn't confirm this is free to edit" or similar) — **must NOT** say a specific person is editing it when nobody actually is. This is genuinely hard to force reliably on-device (session staleness timing isn't fully controllable) — if it can't be forced, note as untestable-as-is and rely on the Node-verified classification logic (Section 1.1) |
| N5 | Airplane mode ON, then attempt to save an order/product/staff edit | Error/queued state shown, not a silent hang — this is pre-existing outbox behavior, not new to this branch, but worth confirming it's still intact given `Gateway._send` was modified |
| N6 | Exchange, added units exceed available stock | The adjustment is rejected with a message naming the product and that stock ran out — confirm via product/batch detail afterward that the FIFO batches were NOT left decremented for the rejected units (see E5 below for the precise version of this check) |
| N7 | A line item's product was deleted from inventory, then the order containing that line is opened/edited/adjusted | **Must not crash.** This is the direct on-device check for C1's fix — see E1 below for the full setup, this entry is the "does the app survive it" smoke test specifically |
| N8 | Attempt to reach the `locks` Firestore collection directly (bypassing the app) — e.g. via the Firebase console's Firestore browser while signed in as a normal tenant member, or a direct REST call if you have the tooling for it | Read and write both denied. This is the on-device-adjacent check for C2 — it doesn't require the app itself, just confirms the deployed rules actually behave as intended for a real client, not just in the (unrun) emulator test |

### 3.3 Edge cases — these map directly to the review's 8 fixes, don't skip any

| # | Scenario | Expect |
|---|---|---|
| E1 | **C1, the core bug, exact setup.** Create an order with a line item for product X, complete it (so FIFO consumption is recorded on that line). Note the batch(es) it consumed. Delete product X from inventory entirely. Now open that order again, or trigger any operation that re-normalizes it (edit any field and save, or adjust it). | Does not crash. The line's FIFO consumption data (if you can inspect it — order detail or Firestore console) is still intact for that line, not silently wiped. Repeat once more WITHOUT deleting the product first, on a different order, to separately confirm consumption lineage survives a normal re-save when the product still exists (the silent-data-loss half of the same bug) |
| E2 | **C2, the core bug, exact setup.** With rules deployed (already done per your last message): attempt N8 above. Separately, confirm normal app functionality that touches locks indirectly still works fine — open `OrderDetailDialog`, confirm the lock-acquire spinner/state resolves normally (the app's OWN access goes through Cloud Functions using the Admin SDK, which bypasses these rules entirely, so this should be completely unaffected) | Direct client access denied (N8); app's own lock acquire/release via the dialogs still works normally |
| E3 | **C3, the core bug, exact setup.** Reproduce N1 (or N2/N3) precisely, then specifically confirm: (a) the Toast text, (b) the order/product/staff/supplier detail view actually shows the OTHER device's values after reconciliation, not a half-merged or stale state, (c) no further network retries happen for that dropped write | All three confirmed — this is the single most important edge case in this whole plan, since it's the one the original review found completely unimplemented |
| E4 | **C4, the core bug, exact numbers.** Product with exactly 20 in stock. Device A restocks +5, Device B restocks +7, both within the same few seconds (genuinely overlapping requests, not sequential). | Final stock = 32 (20+5+7), not 25 or 27 — confirm neither device's restock silently overwrote the other's. Repeat once for `creditStockNoBatch`'s path if you can force two concurrent returns crediting the same product's stock (harder to set up — two separate orders each returning units of the same product, adjusted from two devices at the same time) |
| E5 | **C5, the core bug, exact setup.** Product with exactly 5 in stock, already has at least one FIFO batch. Start an exchange adding 8 units of that product (more than available) → confirm rejected (N6). Then check the product's FIFO batch(es) — either via order/product detail if it surfaces remaining batch quantity, or Firestore console if available. | The batch quantities should read as if the failed exchange never happened — no units consumed for the 8 that were never actually sold. If they show as decremented despite the rejection, that's the exact bug C5 fixed reappearing |
| E6 | **C6, the core bug.** Attempt N4 as precisely as you can force it (stale/expired session token during a lock acquire) | Error message is generic/connection-related, never names a specific person as "editing this" when nobody is. If genuinely unforceable on-device, mark untestable and rely on Section 1.1's coverage |
| E7 | **C7, confirm the deletion didn't break anything.** Use the app normally for a full session touching orders (add, edit, adjust, complete, bulk-approve via the real button) | No crash, no missing functionality — confirms deleting the dead `approveAllPending` code didn't have an unexpected live dependency somewhere this plan didn't anticipate |
| E8 | **C8, if you have Cloud Functions log access.** Perform any order/product edit, then check the Cloud Functions log stream (Firebase console → Functions → Logs, or `firebase functions:log`) for the `recordMutation` invocation | No `[applyMutation]`/`[recordMutation]` debug lines dumping full document JSON. If log console access isn't available to whoever's testing, mark untestable-on-device and rely on the code diff already confirming the removal |

### 3.4 Monkey testing

- Rapidly open and close `OrderDetailDialog`/`EditProductDialog`/`StaffDetailDialog` on the same
  record several times in a row (acquire → release → acquire → release) — confirm the lock state
  never gets stuck (e.g. a release that fires after a new acquire already started, leaving the UI
  showing "granted" when it shouldn't, or vice versa).
- From two devices, rapidly alternate which one is "in front" editing the same order (A edits and
  saves, B immediately opens and edits, A immediately tries again) — stress-test the
  conflict-detection path with fast back-and-forth rather than one clean conflict.
- Restock the same product from 3+ sessions within a few seconds of each other, not just 2 — confirm
  all deltas land and the final total is the correct sum, not just that 2-way concurrency works.
- Toggle airplane mode ON mid-save on an order edit, then OFF again after a minute — confirm the
  queued write eventually drains from the outbox and actually saves, rather than getting stuck.
- Leave an order dialog open (lock held) for an extended idle period (10+ minutes) without saving,
  then attempt to save — confirms whether a long-held lock's TTL/renewal behaves sanely, and
  whether an eventually-stale token (N4) gets hit naturally through normal idle use rather than
  needing to be forced.

---

## 4. Suggested order of attack

Given a production issue is already open on this branch (order editing), adjust from the reference
docs' usual order — start with the exact flow that's reportedly broken before working outward:

1. **H1** (single-device order modify, no concurrency at all) — this is the reported broken flow;
   confirm/deny whether it's broken even in the simplest possible case before anything else.
2. **Regression checklist, Section 2** — the "should be byte-identical to before" items, especially
   the first four (single-device edit to order/product/staff/supplier) — if these are also broken,
   it points away from anything concurrency-specific and toward something more fundamental (the
   rules deploy, the functions deploy, or an unrelated environment issue).
3. **E1** (C1's core bug) — the second most likely candidate given it touches `_normalizeOrder`,
   which runs on every single order save regardless of concurrency.
4. **E3** (C3's core bug) — the biggest, newest piece of machinery in this branch; confirm it works
   for the actual conflict case even if H1 turns out fine.
5. **H2–H10** remaining happy paths.
6. **N1–N8** negative paths.
7. **E2, E4–E8** remaining edge cases.
8. Monkey testing last, time-permitting.

## 5. Sign-off checklist

- [ ] Section 1.1's automated tests passing in a real build (`qmltestrunner` + `functions/`'s
      `node --test`) — not just the Node-simulated verification this branch was built with
- [ ] The reported order-modify issue reproduced, root-caused, and either confirmed unrelated to
      this branch or fixed and re-verified against H1 + the Section 2 regression items
- [ ] E1 (C1 — consumption lineage + no-crash-on-deleted-product) explicitly confirmed
- [ ] E2 (C2 — locks collection denied to direct client access) explicitly confirmed
- [ ] E3 (C3 — conflict Toast, reconciliation, no infinite retry) explicitly confirmed — this is
      the review's single most important finding, don't sign off without seeing it work live
- [ ] E4 (C4 — concurrent restocks both apply, correct sum) explicitly confirmed with exact numbers
- [ ] E5 (C5 — FIFO batches not left decremented after a rejected exchange) explicitly confirmed
- [ ] E6, E8 attempted if feasible; explicitly marked untestable-on-device if not, rather than
      silently skipped
- [ ] E7 (C7's deletion caused no regression) confirmed via a full normal-use session
- [ ] All Section 2 regression items spot-checked, nothing broken beyond what's already
      under investigation
- [ ] H1–H10 happy paths pass
- [ ] N1–N8 negative paths degrade correctly
- [ ] Monkey testing found nothing alarming