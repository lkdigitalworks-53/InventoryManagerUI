# Test plan — R1+R2: the `mint` op of `recordOperation` (server only)

Branch `feat/2026-10-28-r2-mint-engine`. Design: `specs/2026-10-28-r2-mint-engine-design.md` (M1-M14; section 7 = review sweep 2026-10-29). Standard format (Skill 49).
Honesty note: this slice changes NO QML and NO rules. Every Node test below was RUN in the sandbox (functions suite 931/931 locally). The emulator e2e cases are written but CI-only (no emulator here). CI OBSERVED on the first push (353050f): QML 2442, Functions 927, Rules 106, E2E 99 with 1 red (a test-hygiene bug, fixed in the sweep). PREDICTED after the sweep: Functions 931, E2E 101 (96 + 5), QML 2442 and Rules 106 unchanged.

## 1. Unit tests
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/counterRegistry.test.js` | 9 | RUN 9/9, 100% line/branch | registry keys never match inherited names (`toString`, `__proto__`), IST year at both sides of Jan 1, `describe`, `formatId` (pad 3, 1000 not truncated), `numberOf` (14 malformed ids), `maxNumber` numeric not lexical, `usableCount`, round trip monkey, non-4-digit year refused |
| `functions/test/operationLogic.mint.test.js` | 39 | RUN 39/39; `operationLogic.js` and `counterRegistry.js` 100% line AND branch; 27 of 30 hand-made mutants killed in the first pass (3 equivalent: `<` vs `<=` where an op can never sit at a mint op's index; `0 + x`), plus 7 of 7 for the sweep fixes (clean-entry write skip, heal, unused-mint, `__proto__` copy, entity match, use via `after`, use via `entityId`) | validation: unknown counter, bind names, duplicate bind, 5-mint cap, strict `entityId` placeholders (unbound, malformed, later-declared, update/delete/delta refused), lenient `after` text, no scanning without a mint, write budget boundary 500/501 (each mint with its consumer); `unused-mint` (mint-only, second mint unused, names in `before`/keys/text are not uses, uses via entityId and nested `after`); `placeholder-entity-mismatch` (whole id vs embedded id, `{{constructor}}` stays plain unbound text); apply: restock shape (every doc, both counters, audit ids skip mint indexes, marker results, receipt row), existing counter, consecutive numbers, no double read, IST year, default clock, sequence across operations, seed from highest numeric id, per-year seed, no listing when counter usable, 7 damaged counter docs, collision skip WITHOUT rewriting the occupied docs, a gap of 40 heals in one operation with ONE listing and the next operation lists nothing, heal with a stale listing, 20 walked / 21 = `mint-exhausted` only when the heal cannot help, 4 rejection kinds write nothing, retry gets the same id, replay after the counter moved, marker without results, deep substitution + keys/`before` untouched, user text, depth cap 16, hand-built ops defended, `__proto__` key stays an own key, movement mismatch burns nothing, restock without movement derives `adjustment`; seeded monkey 300 runs (never exhausted, occupied docs never rewritten) |
| `functions/test/counterRegistry.guard.test.js` | 3 | RUN 3/3 | QML stores still format and mint supplier/batch ids as the registry does (every `recordMutation(..., "create")` uses the same id field); the guard is mutation-tested (7 source mutants caught); entity map agrees |
| `functions/test/index.handlers.recordOperation.test.js` | +3 | RUN | real validator in front of the mocked apply: mint request accepted, mint results forwarded; 6 bad mints (incl. `unused-mint`, `placeholder-entity-mismatch`) are 400 with `opIndex` 0/1 and never reach apply; `mint-exhausted` forwarded as 409 |

## 2. Regression tests
- `operationLogic.test.js` and every other existing functions test are NOT edited and pass unchanged (918 before the new handler and guard tests): an operation without a mint op is byte-identical (same reads, writes, results, errors).
- `strictDb.js` gained `collection().listDocuments()`; the other suites that use it still pass.

## 3. E2E (real emulator, CI only)
`test/e2e/recordOperation.e2e.test.js` +5 (each records and restores the shared counter doc AND deletes the docs it minted in its own `finally`; leaving them to the end of the file was the CI failure):
- restock operation takes `BAT-<year>-NNN` from the server counter, every doc lands, stock +3, marker holds the mint result, replay returns the same id and the counter does not move;
- a rejected restock (floor) burns nothing: counter and batch absent, no marker; after fixing stock the retry gets the SAME id;
- client-style counter mint racing the server op on one counter: two different numbers, final counter +2;
- NEW: 25 occupied ids after the counter (wider than the 20-walk limit): one operation heals, mints id +26, the occupied docs are untouched, the next operation mints +27;
- NEW: a mint nobody uses is a clean 400 `unused-mint`, no counter move, no marker.

## 4. Rules
Unchanged. `counters` stays client-writable (design 11, atomic design 7b item 2).

## On-device test plan (Taher, after merge; functions deploy only, no app build)
The app sends no `mint` op yet (client R3-R5), so nothing user-visible should change. The plan proves the deploy did not break the paths that share the file.
Prerequisites: P1 signed in as owner on a NEW dev tenant; P2 one product A (stock 10); P3 Firestore console open on `tenants/<t>`. Deploy: `firebase deploy --only functions`.

### Happy path
1. Add a supplier `Acme`. Expect a supplier id `SUP-001` and `counters/suppliers.value` = 1 (client minting, unchanged).
2. Restock A by 5. Expect stock 15, a batch `BAT-<year>-001`, `counters/stockBatches-<year>.value` = 1.
3. Create an order with 2 x A and complete it. Expect stock 13 and the order Completed (this is the `completeOrder` operation going through the edited file).
4. Open the stuck-writes caption. Expect nothing stuck.

### Negative
- Complete the same order again from another device or reopen/complete. Expect no double deduction (replay path unchanged).
- Turn airplane mode on, restock A by 1, turn it off. Expect the restock applies once; counter +1 only.

### Edge cases
- Restock with a new supplier name. Expect supplier `SUP-002` and batch `BAT-<year>-002`, counters 2 and 2.
- Restock the same product twice quickly. Expect two batches, ids consecutive, no gaps.

### Affected areas
Order completion, restock, supplier add, import (all still on the client mint path).

### Regression
Import a CSV with 3 new products and a new supplier. Expect product/supplier/batch ids continue from the counters; no duplicate ids.

### Monkey
Rapidly alternate restock, order completion and supplier add for 2 minutes on two devices signed into the same tenant. Expect no permission or conflict toast, no duplicate ids in the console.

### Not testable on device until R3-R5
The `mint` op itself: covered by Node (39 + 9 + 3 + 3) and the emulator e2e above.
