# Test plan - P1 S4a follow-ups (one PR, four commits)

Branch `feat/2026-11-11-p1-s4a-followups`. Plan: `plans/2026-11-11-p1-s4a-followups-one-pr-plan.md`. Standard format (Skill 49).
Server and rules only: no QML, no UI. CI observed: see CHECKPOINT (read after each push).

## Slice 1 - D-R4: the caller is resolved inside a `try` in every older handler
### 1. Unit / functional (handler, real `index.js`, in-memory Firestore double)
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/index.handlers.membershipAuthority.test.js` | +33 table, +5 | RUN 162/162 | 11 handlers x 3 failing reads (users doc, member doc, every read): JSON 500 with the handler's own code, never `write-rejected`, never `no-tenant-context`, zero writes / locks / files / scans, one `deriveContext failed` log (computeStockRegister logs with console.error, SR-D16). Non-Error throws (string, undefined, null, 42, object). Refusal untouched (403 for all 11). Monkey: 200 seeded runs. Guards: every handler has a code in the table; raw `deriveContext` calls = 2 (helper + computeStockRegister); no `CONTEXT_FAILED` line names a terminal code. |
### 2. Regression
Whole functions suite 1525/1525 (was 1434): F2/F3/S2f-1 matrix, `provisionMemberTarget`, photos, locks, analysis, register all untouched and green. Scripts 1049/1049.
### 3. Mutation (hand, all killed)
Raw `deriveContext` back in `recordDelta` (6 fail); `recordMutation` answers `write-rejected` (6 fail); helper returns `null` (33 fail); helper does not log (30 fail).
### 4. E2E / rules
None: no client, no rules change. State it in the PR.
### 5. Client check (read only, no code)
`StuckWrites.noteFailure` parks a write only on `write-rejected`; any other JSON 5xx body is "may still succeed" and retries exactly like today's bodiless platform 500. `LockManager._classifyAcquireResponse` maps any non-409, non-403-`no-tenant-context` body to reason `error`. So a JSON 500 `write-unavailable` / `lock-failed` is safe.
### On-device
Happy: nothing visible. Negative: cannot be provoked on a phone without breaking Firestore; covered by the double. Affected areas (all ten handlers answer as before): restock, order complete, return, open an order for edit (lock), photo upload, photo delete, analysis, staff add. Regression: the S4a steps 1-5 still pass.

## Slice 2 - D-R2: a `productName` snapshot in every ledger row
### 1. Unit / functional (real writers against an in-memory transaction double)
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/productName.test.js` | 27 | RUN 27/27 | `cleanProductName` (trim, blank / non-string / object / symbol / NaN give `undefined`, cap 200 with no trailing blank), `nameFor` (after wins, a delete uses before, a blank after never hides the real name, create has no before, non-objects), `buildRows` (field only when usable, never an `undefined` value, same name on every row of one write, other keys untouched), the four writers: `applyMutation` create / rename / delete (+ a delete that wrongly carries an `after`, + a nameless product), `applyDelta` (stored doc name, FIFO rows, nameless), `applyMutationsBatch` (create / rename / delete items; non-inventory writes no rows), `applyOperation` (delta op from the running doc, mutation op from its after, two ops on one product; an operation cannot delete inventory). Register: deleted product named from its latest row, rename keeps the latest in any arrival order, the doc's own name wins while it exists, old nameless rows mixed with new, all nameless gives `null`, cleaning like the writer, equal instants resolved the same in every order, a skipped row never lends its name, rows outside the window still name the product, real writers into the real register. Monkey: 300 seeded ledgers against an oracle, shuffled. |
| `functions/test/stockRegister.guard.test.js` | 9 | RUN 9/9 | SRG-06 now also pins that the register reads `row.productName` and cleans it with `cleanProductName`. |
### 2. Regression
Whole functions suite 1552/1552 (was 1525). Every older writer / register test passes unchanged: rows without a name are byte-identical to before.
### 3. Mutation (hand, 15/15 killed)
`nameFor` ignores after; blank accepted; no cap; raw name written (an `undefined` value); `buildRows` never writes the name; each of the four writers omits the name (4); operation delta name dropped; delete takes the after; register picks the first row instead of the latest; doc name ignored; tie-break flipped; ledger name not cleaned.
### 4. E2E / rules
None (no client, no rules change in this slice). The row gains one string field; `firestore.rules` denies every client write to `stock_movements`, so no rule sees it.
### On-device (curl, same prerequisites P1..P5 as the S4a plan; after the functions deploy)
Happy: S4a step 4, deleted product C now answers `name` = C's name. Edge: rename product A in the app, make one more stock change, call the register: A shows the NEW name. Negative: a product created and deleted before this deploy has only old rows, so `name:null` is still correct for it. Affected: restock, order complete, return, product edit, product delete, bulk import all still write their rows (the register totals do not change).
