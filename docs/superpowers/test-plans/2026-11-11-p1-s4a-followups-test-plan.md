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

## Slice 3 - D-R1: `stock_movements` read restricted to owner / admin / manager
### 1. Rules tests (`test/firestore.rules.test.js`, emulator: CI ONLY, not run in the sandbox: the emulator jar cannot download here)
WRITTEN, NOT RUN locally. 22 new cases plus the shared ledger loop (owner): owner, admin, manager read OK and cannot create / update / delete (data untouched); staff cannot read, write or delete; suspended owner / admin / manager / staff cannot read or write; member docs with role viewer, empty, `Owner`, numeric, missing, missing status, unknown status cannot read; outsider and anonymous cannot get or list; manager can list, staff cannot; a manager of ANOTHER tenant cannot read; regression: `audit_log`, `transactions`, `stock_batches` stay readable by all four roles.
### 2. Unit / guard (`functions/test/stockRegister.guard.test.js`, RUN 12/12)
SRG-08 write-denied; SRG-08b `isLedgerReader` is the read rule, defined once and used once, starts with `isMember`, and its role list EQUALS `REGISTER_ROLES` (parsed from both files); SRG-08c the three sibling collections still `isMember` read / `false` write; SRG-08d no `stock_movements` in `qml/`, `src/`, `main.cpp`.
### 1b. CI found a hole the guards missed (2026-11-12, fixed in the same PR)
The emulator job failed 2 of 129 cases on the first head: staff COULD still read `stock_movements`, because the generic fallback `match /{collection}/{docId}` allowed every member to read it and Firestore ORs matching rules. Fix: `collection != 'stock_movements'` in the fallback read; new guard SRG-08e reads the fallback block and pins the carve-out (mutant removing it: killed). The emulator cases are the proof; read the Rules job on the fixing head.
### 3. Mutation (hand, 5/5 killed by the guards, plus 1/1 for the carve-out)
staff added to the list; read back to `isMember`; `isMember` dropped from the helper; `stock_batches` narrowed; admin removed. The emulator cases cover the same behaviour but only CI can run them.
### 4. Regression
Functions suite and scripts suite unchanged and green (see CHECKPOINT for the final counts). No handler code changed in this slice.
### 5. E2E
None: the app has no ledger read. State it in the PR.
### Deploy
`checks.yml` deploys `functions,firestore:rules,firestore:indexes` on merge (behind the Deploy Check gate), so ONE approval ships all four slices. The plan's "rules need a separate deploy" was stale. If the rules deploy fails, revert this commit only.
### On-device (curl / console, after the deploy)
Happy: signed in as the owner, open the Firebase console Firestore data for `stock_movements`: unaffected (console bypasses rules). The S4a register `curl` steps still work (Admin SDK). Negative: BLOCKED until a staff login exists (KNOWN-ISSUES 12); the emulator cases are the proof until then. Affected: every normal app flow (restock, order, return, lock, photos, analysis): none reads the ledger, so nothing should change. Regression: S4a steps 1-5.

## Slice 4 - D-R3: `count()` pre-check in `computeStockRegister`
### 1. Unit / functional (real handler, in-memory double with a new `count()` aggregation)
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/index.handlers.stockRegister.test.js` | +8 (SRH-23..30) | RUN | over cap: 413 with ZERO document reads; exactly the cap is served (strict `>`, same constant as the stream); `count()` throws: still served; count says small but the stream finds more than the cap: 413 from the backstop; six junk count answers ignored; the count never runs for staff, a bad window or a bad token; count 0 and another tenant's ledger untouched; 60-case monkey (413 iff count or ledger over the cap, never 500). |
| `functions/test/stockRegister.guard.test.js` | +1 (SRG-11) | RUN | count before the stream, shared cap with strict `>`, junk count ignored, local catch, in-stream cap still the same constant. |
Harness: `handlerHarness.js` gained `count().get()` (`countCalls`, `countError`, `countValue`); a count reads no document, so it is NOT in `collectionGetCalls`.
### 2. Regression
Functions 1564/1564 on this branch (1552 after slices 2 and 3, plus 12 here), scripts 1049/1049. Every older register test passes unchanged (the double answers the seeded length when `countValue` is unset).
### 3. Mutation (hand, 6/6 killed)
Pre-check removed; `>` to `>=`; a count failure fails the request; in-stream cap removed (backstop); junk count not ignored; wrong collection counted.
### 4. E2E / rules
None. The real `count()` call has never run against Firestore: the first real call is the on-device `curl` below (admin SDK `^12.6` supports it).
### On-device (curl, after the deploy)
Happy: S4a step 1 still answers 200. Negative: an over-cap ledger (250 001 rows) cannot be built on a phone, do NOT seed it; the 413 path is proven by the double only. Look in the function logs after the first call: there must be NO `count failed, scanning instead` warning. If there is one, `count()` is failing on real Firestore and the request silently falls back to the full scan (still correct, but the saving is gone): report it.

## Review sweep 1 - PR #195 (2026-11-12): fixes added to the same PR
Findings fixed: (F1) `uploadProductPhoto` read Firestore three times before its Storage write with no `try` (unhandled rejection on a transient error); (F2) a hung `count()` had no timeout; (F3) the count failure was logged with a raw `console.warn(error)`; (F4) the 200-character name cap could split an emoji; (F5) guard SRG-08d shelled out to `grep` and passed vacuously when it failed.
### 1. Unit / functional (RUN)
| File | Cases | Covers |
|---|---|---|
| `functions/test/index.handlers.photos.test.js` | +7 (RD-U1..U7) | audit read throws, preflight read throws, replay product read throws: JSON 500 `write-failed`, never `write-rejected`, zero Storage saves, zero writes. Non-Error throws (string, null, 42, object) at both reads. Same request succeeds after the read recovers. Happy, replay, 404, 409 unchanged. Monkey: 120 seeded runs, a random read fails at a random step. |
| `functions/test/productName.test.js` | +6 (PN-28..33) | cap inside a surrogate pair drops the orphan half; an emoji ending exactly at the cap is kept; a space before the emoji still ends trimmed; input that is already a lone surrogate is not made worse; monkey 400 random mixed BMP / emoji names (length, no lone half, prefix, trimmed, idempotent); writer and register clean alike. |
| `functions/test/index.handlers.stockRegister.test.js` | +7 (SRH-31..37) | count failure logs exactly one structured warning (message, code, no stack); non-Error throws; a successful count logs nothing; hung count abandoned at 15 s then served by the stream (one warning, code `count-timeout`); still waiting at 14 999 ms; hung count on an over-cap ledger still ends 413; a count that answers clears its timer. Fake timers, per-test `timeout`. |
| `functions/test/stockRegister.guard.test.js` | +1, 1 rewritten | SRG-12 (timeout constant under a quarter of the scan budget, wraps `count().get()`, cleared in a `finally`); SRG-08d is now an fs walk that fails when a folder is missing. Harness gains `countHang`. |
### 2. Regression
Whole functions suite 1586/1586 (was 1564). Rules, QML and E2E: nothing touched in this sweep.
### 3. Mutation (hand, all killed)
Original `index.js` against RD-U (5 fail); original `cleanProductName` against PN (5 fail); `console.warn` back (2 fail); a `qml` file that names `stock_movements` (SRG-08d fails); `withTimeout` removed (SRH-34..37 and SRG-12 fail, none hangs).
### 4. E2E / rules
None: no client change, no rules change in this sweep.
### On-device (curl, after the functions deploy)
Happy: upload a photo from the app, it still works. Negative: cannot be provoked on a phone; covered by the double. Edge: a product named with an emoji at character 200 (paste a long name) saves and shows in the register without a replacement character. Watch the logs for `count failed, scanning instead` with code `count-timeout` after the first register calls.

