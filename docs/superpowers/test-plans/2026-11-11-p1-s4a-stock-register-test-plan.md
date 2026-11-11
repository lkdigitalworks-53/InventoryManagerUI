# Test plan — P1 S4a: stock register read model (`computeStockRegister`)

Branch `feat/2026-11-11-p1-s4a-stock-register-server`. Design: `specs/2026-11-11-p1-s4a-stock-register-design.md` (SR-D1..SR-D13). Standard format (Skill 49).
Server only: no QML, no rules change, no UI. CI observed: see CHECKPOINT (read after push).

## 1. Unit tests
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/stockRegisterMath.test.js` | 33 | RUN 33/33 | `toMillis` (Date, Timestamp-like, `{seconds}`, `{_seconds}`, ms, ISO with offset; 20 junk values all NaN), `parseWindow` (ms, ISO offset, 19 refused shapes), `canViewRegister`, opening / IN / OUT per kind / closing, every kind present, adjustment both directions, `[from,to)` boundaries, adjacent periods chain, fractional quantities, `-0` normalised, ledger-only (deleted) product, stock with no rows, ledger vs inventory disagreement, rows only after the period, ordering, junk inventory docs, non-numeric stock, 18 unclassifiable rows by reason, prototype-like ids, empty input, streaming equals batch and inputs not mutated, Timestamp shapes; review sweep: SR-29 impossible calendar dates refused (12 shapes, both bounds), SR-30 leap days (2024, 2000, year 0 yes; 1900, 2100, 2026 no; every month end), SR-31 hour 24 / minute 60 / second 60 / zone range, SR-32 monkey 3000 random dates against a Date round-trip oracle |
| `functions/test/index.handlers.stockRegister.test.js` | 22 | RUN 22/22 | 405 on four methods, 401 x2, 403 no context, 403 staff (zero reads), 200 for owner/admin/manager, 12 bad windows, happy path JSON shape, read-only (no writes, only the two collections), 2503 rows over 3 pages of 1000, exactly one full page (1000), empty ledger, 250 001 rows = 413, 250 000 rows served, Firestore failure = 500, junk rows reported, other tenant never read, unknown env, no body; review sweep: SRH-18 impossible date = 400 with zero reads, SRH-19 scan over its 100 s budget = 504 `ledger-scan-timeout` and no page after the budget, SRH-20 a fast multi-page scan is served, SRH-21 Firestore error while resolving the membership = JSON 500, SRH-22 `constructor` / `toString` / `__proto__` / `hasOwnProperty` / `valueOf` fall back to the default database while `dev` and `test` still map |
| `functions/test/stockRegister.guard.test.js` | 9 | RUN 9/9 | module pure (one require), handler has no write call, ledger streamed not materialised and capped, order context -> role -> window -> read, kinds not copied, role list vs `VALID_ROLES`, row fields the register reads are the ones the server writes, handler codes present, `stock_movements` still write-denied in the rules; SRG-09 the scan budget stays at least 10 s under the function timeout and the stream gets page size + deadline |

## 2. Regression tests
- `index.handlers.membershipAuthority.test.js` now includes `computeStockRegister`: the whole F2/F3/S2f-1 matrix (removed, suspended, unsafe tenant id, 11 bad roles, valid roles pass the identity step) runs against the new endpoint (+10 cases).
- SR-27 feeds rows built by the REAL `movementLogic` (derive for create / sale / increase-as-sale / edit / delete, explicit return and loss) into the register: the register can read everything the server writes, and a product created, sold, edited and deleted ends at 0 and reconciles.
- Existing suites untouched: functions 1433/1433 after the review sweep (1424 before it, 1360 before the PR: 29 + 17 + 8 + 10 new, then +9 in the sweep), `.github/scripts` see CHECKPOINT. The harness gained one recording field (`firestoreDbIds`); every older handler test still passes.
- `scopedDb` (shared by every handler) changed in the sweep: SRH-22 covers the new behaviour through this endpoint; all other handler suites run the old and new code paths identically for `dev`, `test`, `prd` and unknown env.

## 3. Mutation and monkey
- SR-28: 300 seeded random ledgers x random windows against a brute-force oracle (opening, IN, OUT, closing, ledger total, count, identity `closing = opening + IN - OUT`); shuffling the rows changes nothing.
- 25 hand mutants on the new code (boundary `<` to `<=` both sides, sign of OUT, ledger total dropped, opening sign, closing without opening, stock-without-rows removed, direction check removed, `reconciles` forced true, `deleted` forced false, name order flipped, `from >= to` loosened, staff added to roles, offset-less ISO accepted, kind and time checks removed, cap off by one, role gate removed, window check removed, 413 removed, paging loop broken, cap changed, `acc.add` unplugged, products blanked, `-0` kept): the first run left one survivor (`-0` normalisation), killed by the new case SR-11b; final run 25/25 killed.

- Review-sweep mutants (5, each reverts one fix): calendar check off (5 tests fail), deadline never checked (SRH-19), context outside the try (SRH-21), plain-object env lookup (SRH-22), page size back to 500 (SRH-09), budget raised to 115 s (SRG-09). All killed.

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
7. `from` after `to`; `from` equal to `to`; `"from":"2026-04-01"` (date only); `"from":"2026-04-01T00:00:00"` (no offset); a missing `to`; `"from":"2026-02-30T00:00:00Z"` and `"to":"2026-04-31T00:00:00+05:30"` (days that do not exist); `"from":"2026-04-01T24:00:00Z"`. Each: 400 `invalid-window` (never a register for some other month).
8. **BLOCKED (no second login can be created yet: `Gateway.provisioningAvailable` is `false`, KNOWN-ISSUES item 12).** Intended check: a STAFF token of the same tenant gets 403 `role-not-allowed`; manager and admin get 200. Until then the gate is proven by SRH-05 and the membership matrix. Do NOT try to create a staff login for this.
9. Use the owner token of ANOTHER tenant: the answer lists only that tenant's products (never A, B, C).
10. A GET request: 405.
10b. `"env":"constructor"` (and `"toString"`) with the owner's dev token: 403 `no-tenant-context`, exactly like `"env":"nonsense"`: the default database holds no such user. Never a 500 or a hang.
10c. The 504 `ledger-scan-timeout` and 413 `ledger-too-large` answers need a huge ledger and cannot be reproduced on a dev tenant: they are proven by SRH-19 and SRH-11 only.

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
20. **BLOCKED with step 8** (no staff login yet). Intended: signed in as staff, nothing new is visible anywhere (no register page yet).
