# Test plan — P1 S4a: stock register read model (`computeStockRegister`)

Branch `feat/2026-11-11-p1-s4a-stock-register-server`. Design: `specs/2026-11-11-p1-s4a-stock-register-design.md` (SR-D1..SR-D13). Standard format (Skill 49).
Server only: no QML, no rules change, no UI. CI observed: see CHECKPOINT (read after push).

## 1. Unit tests
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/stockRegisterMath.test.js` | 29 | RUN 29/29 | `toMillis` (Date, Timestamp-like, `{seconds}`, `{_seconds}`, ms, ISO with offset; 20 junk values all NaN), `parseWindow` (ms, ISO offset, 19 refused shapes), `canViewRegister`, opening / IN / OUT per kind / closing, every kind present, adjustment both directions, `[from,to)` boundaries, adjacent periods chain, fractional quantities, `-0` normalised, ledger-only (deleted) product, stock with no rows, ledger vs inventory disagreement, rows only after the period, ordering, junk inventory docs, non-numeric stock, 18 unclassifiable rows by reason, prototype-like ids, empty input, streaming equals batch and inputs not mutated, Timestamp shapes |
| `functions/test/index.handlers.stockRegister.test.js` | 17 | RUN 17/17 | 405 on four methods, 401 x2, 403 no context, 403 staff (zero reads), 200 for owner/admin/manager, 12 bad windows, happy path JSON shape, read-only (no writes, only the two collections), 1203 rows over 3 pages, exactly one full page, empty ledger, 250 001 rows = 413, 250 000 rows served, Firestore failure = 500, junk rows reported, other tenant never read, unknown env, no body |
| `functions/test/stockRegister.guard.test.js` | 8 | RUN 8/8 | module pure (one require), handler has no write call, ledger streamed not materialised and capped, order context -> role -> window -> read, kinds not copied, role list vs `VALID_ROLES`, row fields the register reads are the ones the server writes, handler codes present, `stock_movements` still write-denied in the rules |

## 2. Regression tests
- `index.handlers.membershipAuthority.test.js` now includes `computeStockRegister`: the whole F2/F3/S2f-1 matrix (removed, suspended, unsafe tenant id, 11 bad roles, valid roles pass the identity step) runs against the new endpoint (+10 cases).
- SR-27 feeds rows built by the REAL `movementLogic` (derive for create / sale / increase-as-sale / edit / delete, explicit return and loss) into the register: the register can read everything the server writes, and a product created, sold, edited and deleted ends at 0 and reconciles.
- Existing suites untouched: functions 1424/1424 (1360 before: 29 + 17 + 8 + 10 new), `.github/scripts` 1049/1049.

## 3. Mutation and monkey
- SR-28: 300 seeded random ledgers x random windows against a brute-force oracle (opening, IN, OUT, closing, ledger total, count, identity `closing = opening + IN - OUT`); shuffling the rows changes nothing.
- 25 hand mutants on the new code (boundary `<` to `<=` both sides, sign of OUT, ledger total dropped, opening sign, closing without opening, stock-without-rows removed, direction check removed, `reconciles` forced true, `deleted` forced false, name order flipped, `from >= to` loosened, staff added to roles, offset-less ISO accepted, kind and time checks removed, cap off by one, role gate removed, window check removed, 413 removed, paging loop broken, cap changed, `acc.add` unplugged, products blanked, `-0` kept): the first run left one survivor (`-0` normalisation), killed by the new case SR-11b; final run 25/25 killed.

## 4. E2E (emulator)
Not written. `test/e2e` drives the QML app and `recordOperation` against the emulator; the register has no client yet, and the handler is proven against the in-memory Firestore double that every other handler test uses. S4b adds the first QML-to-endpoint case.

## 5. Rules
No rules change. SRG-08 pins that `stock_movements` stays `allow write: if false`.

## On-device test plan (Taher, after merge AND after the functions deploy approval)
The app has no register screen yet (S4b), so these steps use `curl` and the Firebase console. Nothing in the app changes: also do the 3 regression steps below on the phone.

Prerequisites
- P1 Functions deployed to the dev project (merge, then approve the deploy gate in Actions, or `firebase deploy --only functions`). Check: `curl -s -o /dev/null -w "%{http_code}" -X POST https://asia-south1-inventorymanager-48392.cloudfunctions.net/computeStockRegister` answers `401`, not `404`.
- P2 A NEW dev tenant and user (owner). Create product A (stock 10), product B (stock 5). Restock A by 4. Complete one order with 2 x A. Return 1 x A. Adjust B's stock by editing it from 5 to 3. Delete a third product C that had stock 2.
- P3 An ID token for the owner. Easiest: sign in in the app on a debug build and copy the token from the log, or use the Firebase Auth REST `signInWithPassword` call with the project's web API key. Call it `$TOKEN`. `$URL` = the endpoint above.
- P4 Firebase console open on `tenants/<t>/stock_movements` to compare.
- P5 Body helper: `BODY='{"env":"dev","from":"2020-01-01T00:00:00+05:30","to":"2099-01-01T00:00:00+05:30"}'`.

### Happy path
1. `curl -s -X POST "$URL" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$BODY"`. Expect HTTP 200, `ok:true`, `kinds` with 10 names, `counts.skipped` all 0.
2. In the answer find product A. Expect `opening 0`, `kinds.receipt.in` 14 (10 opening stock + 4 restock), `kinds.sale.out` 2, `kinds.sales_return.in` 1, `closing` 13, `currentStock` 13, `reconciles:true`.
3. Product B: expect `receipt.in` 5, `adjustment.out` 2, `closing` 3, `reconciles:true`.
4. Product C (deleted): expect `deleted:true`, `name:null`, `closing 0`, `adjustment.out` 2, `reconciles:true`.
5. Compare `counts.rowsSeen` with the number of documents in `stock_movements` in the console. Expect equal.

### Negative
6. Same call with no `Authorization` header: 401 `missing-token`. With `Bearer garbage`: 401 `invalid-token`.
7. `from` after `to`; `from` equal to `to`; `"from":"2026-04-01"` (date only); `"from":"2026-04-01T00:00:00"` (no offset); a missing `to`. Each: 400 `invalid-window`.
8. Sign in as a STAFF member of the same tenant (create one in the Staff page), repeat step 1 with that token: 403 `role-not-allowed`. As a manager and an admin: 200.
9. Use the owner token of ANOTHER tenant: the answer lists only that tenant's products (never A, B, C).
10. A GET request: 405.

### Edge cases
11. Period that starts after everything: `from` = tomorrow. Expect every product `opening` = its stock, all IN/OUT 0, `closing` = opening.
12. Period that ends before the first row: `to` = 2020-01-02. Expect `products: []` (or only products holding stock with no rows, flagged `reconciles:false`).
13. Boundary: copy the `serverTimestamp` of one row from the console, convert to an ISO instant with offset. Call with `to` = that instant: the row is NOT in the period. Call with `from` = that instant: the row IS in the period.
14. Time zone: send the same instants as `+05:30` and as `Z` (shifted). Expect identical figures.
15. A product with a fractional quantity (restock 0.5). Expect `0.5` exactly, no `0.49999999`.
16. A second new tenant with no activity: `products: []`, 200.

### Monkey
17. With the app on the phone, restock, sell, return, edit stock and delete products at random for 2 minutes, with airplane mode toggled a few times. Wait until the header shows nothing syncing. Call the endpoint. Expect `counts.mismatches` 0 for every product and `counts.skipped` all 0. A `reconciles:false` right after a burst: repeat the call once (the two reads are not one transaction, design SR-D8); if it persists, that is a real hole in the ledger: note the product and report it.

### Affected areas
Cloud Functions deploy (new export), `firestore.rules` untouched, Analysis (`computeAnalysis`) untouched. No QML file changed.

### Regression (on the phone)
18. Restock, complete an order, return one item: all still work and stock moves once.
19. Sales Analysis still opens and totals as before.
20. Sign in as staff: nothing new is visible anywhere (no register page yet).
