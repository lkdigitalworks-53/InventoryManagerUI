# Test plan: R3, the client planner for the atomic restock operation (dormant)

Branch `feat/2026-11-01-r3-restock-plan`. Design: `specs/2026-11-01-r3-restock-plan-design.md` (T1-T10). Standard format (Skill 49).
Honesty note: this slice changes no behaviour a person can see. Nothing calls `RestockPlan.build` or `InventoryStore.applyRestockResults` yet (test P-1 pins that). Every Node test below was RUN in the sandbox (functions suite 979/979 after `npm ci`). The QML tests were written but NOT run here (no Qt toolchain in the sandbox); CI's `qmltestrunner` is their only oracle. CI observed counts: see the line "CI OBSERVED" at the end of section 1, filled in after the first push.

## 1. Unit tests

| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/restockPlan.test.js` | 26 | RUN 26/26 | Keys: nonce format and uniqueness, `restockKey` accepts a plain token and refuses 13 hostile shapes (empty, 101 chars, `/`, `~`, space, `:`, non-ASCII, newline, non-strings), `isRestockKey`, `purchaseTxId`, a generated key passes the server's request-id rule. Build: new supplier (six ops, mints first, tokens placed right, explicit receipt), known supplier (four ops), no supplier, every doc field, free cost, fractional quantity, empty and non-string text, long reason cut for the ledger row only, input untouched and repeatable. Refusals: 29 inputs, every reason (`bad-key`, `bad-product`, `bad-quantity`, `bad-cost`, `bad-time`, `bad-supplier`, `reserved-text`), both tokens in every typed position. Drift guard: the plan's doc keys equal the keys of the QML builders (`addSupplier`, `_buildBatchDoc`, `recordPurchase`). Server: plan through the REAL `validateOperationRequest` + `applyOperation` on the strict fake DB (docs created once, counters, one ledger row, marker, no double write), `reflect` equals the stored docs, known and no supplier, replay of the same key writes nothing new, a second restock mints the next ids with no gap, missing product is 404 and burns nothing, write count far under budget. `reflect`: 25 malformed answers each refused with its own pinned `detail`, a completion-shaped answer is not a restock. Seeded monkey of 400 inputs (coverage floors: built > 150, refused > 15), never a server disagreement. |
| `functions/test/restockSurface.test.js` | 15 | RUN 15/15 | `forRejection` (old bug codes unchanged, nine new R2 codes are app problems, completion causes unchanged, inherited names like `toString` are not codes), `forRestock` (not-found with and without a name, exact conflict text, mint-exhausted, request-id-in-use, stock and size codes without order wording, fallback, hostile inputs never throw or give empty text), `DescribeItem` (title, `3 × Tomato`, id fallback, zero and negative quantity hidden, malformed ops never throw, completeOrder and unknown labels unchanged), the real bodies of `addLocalSupplier` and `applyRestockResults` cut from the `.qml` files and run against fake stores (order of application, known supplier, replay skips the stock, malformed answers apply nothing and warn once), source pins (dormancy, pragma-library). |
| `tests/tst_RestockPlan.qml` | 21 functions (about 90 rows) | WRITTEN, CI only | The planner cases above in the QML engine (number and string handling can differ from Node): keys, build shapes, 27 refusal rows, token refusal, `reflect` good and 26 malformed rows, seeded monkey. |
| `tests/tst_FailureCause.qml` (+) | +12 | WRITTEN, CI only | `forRejection` regression and `forRestock` wording. |
| `tests/tst_DescribeItem.qml` (+) | +5 | WRITTEN, CI only | Restock label, fallbacks, zero quantity, malformed ops, other labels unchanged. |
| `tests/tst_SupplierStore_addLocal.qml` | 6 functions | WRITTEN, CI only | Add, sort by name, repeated id is a no-op and does not overwrite, 7 refused docs, array replaced not mutated. |
| `tests/tst_InventoryStore_applyRestockResults.qml` | 8 functions | WRITTEN, CI only | Live answer fills supplier, batch, purchase and stock; known supplier; replay leaves stock alone; `replay: false` and missing opts apply the stock; same answer twice duplicates nothing; 7 malformed answers apply nothing; unknown product tolerated. |

Mutation checks (by hand, in the sandbox, scripts not committed): planner and keys 21 of 23 mutants killed alone (the 2 survivors are the redundant pair `qty <= 0` / `SM.validate`, killed together); client surface 16 of 18 first, the two survivors (exact conflict text, zero quantity label) got stronger tests, then 18 of 18.

CI OBSERVED: (filled in after the first push, see CHECKPOINT.md step 7).

## 2. Functional / rules / e2e
- Functional: the "plan through the real server code" tests (S-1..S-7) are the functional layer; they exercise the real transaction logic, counters and the strict fake DB.
- Rules: unchanged. The plan writes the same collections the QML stores write today (`suppliers`, `stock_batches`, `inventory`, `transactions`), so no rule changes.
- E2E (emulator): none added. The server side was covered by R2's e2e cases (restock operation, replay, rejection burns nothing). The first emulator test of a CLIENT-built plan belongs to R4, when something sends it.

## 3. Regression
- No existing test was edited. `functions` 979/979 (937 + 41 new, plus tests that arrived with main).
- Existing QML tests for `FailureCause`, `DescribeItem`, `SupplierStore`, `InventoryStore` are untouched; the added code only adds functions and table entries.
- P-1 pins that no QML or JS file other than the definition mentions `applyRestockResults` or `RestockPlan.build`. R4 changes that expectation deliberately.

## On-device test plan (Taher, after merge; app build needed to see the client code, but nothing changes)
Prerequisites: P1 signed in as owner on a dev tenant; P2 product A (stock 10), supplier `Acme`; P3 Firestore console open on `tenants/<t>`.

### Happy path (regression: the old restock still works)
1. Restock A by 5 with supplier `Acme` and cost 12. Expect stock 15, one new batch (supplier `Acme`, qty 5, cost 12), one purchase row in the ledger, one `receipt` movement.
2. Restock A by 2 with a NEW supplier name `Zed`. Expect supplier `Zed` created and chosen, stock 17.
3. Complete an order of 1 x A. Expect stock 16 and the order Completed (the `completeOrder` path shares `FailureCause` and `DescribeItem`).
4. Open the stuck-writes caption. Expect nothing stuck.

### Negative
- Restock with quantity 0 or empty. Expect the existing refusal text, no batch, no ledger row.
- Turn the network off, restock A by 1, turn it on. Expect the same one batch and one ledger row (existing queue behaviour; R4 will change how).
- Sign out and in during a queued write. Expect the existing sign-out sheet behaviour, unchanged.

### Edge cases
- Restock with fractional quantity 2.5 and cost 0. Expect it accepted exactly as before.
- Restock with a 600-character reason. Expect the existing behaviour (unchanged).
- Product name containing `{{batch}}`: today it saves as typed (the old path). It is the new planner that will refuse it later (R4); nothing to check now.

### Multiple scenarios
- Two restocks of A back to back, then a completion. Expect stock arithmetic and one batch per restock, FIFO order unchanged.
- Restock on two devices at once. Expect both applied (the old path), no duplicate supplier.

### Monkey
- Rapid taps on Restock, rotate the screen mid-save, background and foreground the app. Expect no crash and no duplicate batch (the old path's behaviour; R4 adds the latch).

Expected result of the whole on-device list: identical to the build before this PR. Any difference is a bug in this PR (it should be dormant).
