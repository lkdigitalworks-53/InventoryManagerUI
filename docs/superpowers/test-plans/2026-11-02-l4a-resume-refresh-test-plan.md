# Test plan: L4a, non-blanking data refresh on resume and reconnect

Branch `feat/2026-11-02-l4a-resume-refresh`. Design: `specs/2026-11-02-l4a-resume-refresh-design.md` (L4-D1..D8). Standard format (Skill 49). Nothing was built or run on a device. Node tests were RUN in the sandbox; QML tests are written and run in CI only.

## 1. Unit tests

| File | Cases | Run? | Covers |
|---|---|---|---|
| `.github/scripts/__tests__/refreshPolicy.test.js` | 43 (battery of checks, 20000-step seeded monkey, 40 hand mutants; includes the edit-dialog blocker) | RUN | `decide` matrix (run / wait / drop, per trigger, staleness, spacing, every hard and soft blocker, order of reasons, junk in every field fails closed), `swapOk` (revision, outbox, in-flight, lock, photos, block, offline, junk revisions), `wantExpired`, `runLost`, `allCommitted`. |
| `.github/scripts/__tests__/refreshBehavior.test.js` | 80 (57 + 15 from the 2026-11-03 review: busy at commit, busy only mid-way, Transaction retry timer; + 8 for the edit-form hold: wait, swap guard, close trigger, hold counter and its 5000-step monkey) | RUN | REAL function bodies of the six stores and of `DataModel` in a vm sandbox: paging into a buffer, list untouched until the commit, guard refusal / throw / non-true, failed first or later page, cancel mid-flight (answers once, late page ignored), refusal to start while loading / resetting / refreshing, cancel-then-new-run, per-store commit details (sort, counts, activities, tombstones, overlay, mints), coordinator run / wait / expire / rearm once / partial / skipped store / superseded / hung run, 6 seeds x 3000-step monkey with invariants. 24 hand mutants on the real files, 0 survivors. |
| `.github/scripts/__tests__/refreshWiring.test.js` | 41 (24 + 5 busy-check mutants + 10 edit-hold mutants + 2 tests that flip the flag on every one of the nine forms and on seven read-only sheets) | RUN | Source rules: the paging function never touches the live list, `hasMore`, `_cursor`, `loadingMore` or `revision`; stale answers ignored first; guard strict and try-wrapped; commit only after the guard; reset and clear cancel first; snapshot keys equal the keys the policy reads; each key read from its real source; only `DataModel` calls `refreshFromFirebase`; resume hook; sign-out resets; helper is pure. 22 wiring mutants. |
| `tests/tst_RefreshPolicy.qml` | 13 functions | CI only | Policy contract in the real Qt JS engine. |
| `tests/tst_LockManager.qml` | +1 function | CI only | Edit-hold counter in the real engine (count, overlap, never negative, reset). |
| `tests/tst_StoreRefresh.qml` | 6 functions (+ Transaction commit stops a pending retry timer) | CI only | All six singletons compile with the new members; refusal to start; cancel answers once; commit replaces and sorts. No network. |
| `.github/scripts/__tests__/sessionRecheckWiring.test.js` | updated | RUN | Resume-hook pin follows the new block shape; `DataModel` allowed to read `AuthService.checking`. |

Suites after the change: script suite 905/905 (862 before the review sweep, 882 after fix F1), `functions` 985/985 (untouched).

## 2. Functional / rules / e2e
- Functional: the behaviour tests above are the functional layer (real function bodies, fake edges).
- Rules: unchanged. A refresh only reads collections the stores already read.
- E2E (emulator): none. Nothing server-side changed.

## 3. Regression
- `syncFromFirebase()` and every `_resetAndFetch()` keep their behaviour; the only edit is a first line `_cancelRefresh()` that does nothing unless a refresh is running.
- Sign-in sync, discard resync, conflict handlers, `listComplete`, pagination are untouched.
- Existing QML tests for the six stores and `DataModel` must stay green in CI.

## On-device test plan (Taher; build needed; two phones A and B, same owner account, dev tenant)

Prerequisites: P1 dev functions deployed (unchanged), P2 both phones signed in as owner with at least 20 orders and 20 products, P3 Firestore console open.

### Happy path
1. A and B open on Orders. On B add a product "L4 Test" and a pending order. Put A in the background for more than 5 minutes (screen off, other app). Bring A back. Expect: Orders and Inventory show the new rows within a few seconds, no sign-in screen, no blank list, scroll position kept.
2. Same but A is away only 1 minute. Expect: no refresh (nothing new appears). Confirms the 5-minute staleness rule. Wait to 6 minutes total and resume again: rows appear.
3. A in airplane mode for 6 minutes while B adds a row. Turn the network on. Expect: the row appears shortly after (reconnect trigger).
4. Check the Analysis and Dashboard numbers on A after step 1. Expect: they include B's new order (SalesStore follows OrdersStore).

### Negative
5. On A create an order offline, then resume with the network back. Expect: the order stays visible all the time, is sent, and a refresh follows after it is acknowledged (the lists then show the server copy). No row ever disappears.
6. On A open an order for editing (lock held), resume from the background while B changed another order. Expect: no refresh while the dialog is open; once it is closed (and the lists are more than 5 minutes old) they refresh on their own, without another resume.
7. Suspend the member on B (Firestore console `members/<uid>.status = suspended`) and resume A. Expect: the access screen (existing L3 behaviour) and no data read errors.
8. Kill the network in the middle of a refresh (resume, then airplane mode within a second). Expect: lists unchanged, no toast, no crash; the next resume refreshes.

### Edge cases
9. Resume ten times in 30 seconds. Expect: at most one refresh (15 s spacing, 5 min staleness).
10. Resume with a parked (stuck) write in the stuck-writes dialog. Expect: no refresh; after Retry or Discard clears it, the next resume refreshes.
11. Resume right after a cold start. Expect: no second full read (the sign-in sync counts as the last sync).
12. Photo upload in progress, resume. Expect: refresh waits until the photo is uploaded (up to 2 minutes), the product keeps its photo.
13. Sign out and sign in as another account right after a resume. Expect: the other account's lists, nothing of the first one (cancel on clear).

### Multiple scenarios and monkey
14. Two phones, both editing different products and orders in turns for 10 minutes with resumes in between. Expect: no lost edit, no duplicate row, no "edited elsewhere" toast caused by a refresh.
15. Rapid app switching (monkey): switch to another app and back 30 times with orders being completed on B. Expect: no crash, no blank list, numbers settle to the server's after the last resume + 5 minutes.

16. (Review F1, Transactions) Start A with the network off, sign in from the saved session so the Transactions list stays partial and retries in the background, then turn the network on and resume after 5 minutes. Expect: History shows each transaction once; the totals on Dashboard and Analysis equal the server's, not doubled.

17. (L4-D10, edit forms) On A open New order, type a customer name and add a product, then on B add a product and an order. Put A in the background for 6 minutes and resume with the form still open. Expect: nothing changes under the form (the new product is not in its picker), no toast. Close the form without saving: the lists refresh within a few seconds and B's rows appear.
18. (L4-D10) Repeat step 17 with Add product, Edit product, Restock, Add staff, Staff detail, Import preview and the order Return confirmation. Expect: the same hold each time. Then open Filter, Export and Notifications and resume after 6 minutes: these do NOT hold, the refresh runs behind them.
19. (L4-D10) Open a form, sign out through the profile menu, sign in again, wait 6 minutes and resume. Expect: the refresh runs (the hold did not survive the sign-out). Also: open and close Order detail 20 times quickly (monkey), then resume after 6 minutes: the refresh runs (no hold left behind).

### Affected areas
Orders, Inventory, Staff roster, Suppliers, Dashboard / Analysis (derived), stock batches (FIFO ledger), Transactions (history), the resume hook, the stuck-writes caption.

### Regression
R1 login and cold start show the same lists as before. R2 completing, returning and restocking behave as before. R3 the access-blocked screen and the role toast (L3 slice A) still appear. R4 the stuck-writes dialog Retry and Discard still work.
