# Test plan — pending batch-id mints are tenant-scoped

**Branch:** `fix/2026-10-26-pending-mints-tenant-scope`, STACKED on `feat/2026-10-26-signout-guard` (PR #167). **Design:** `specs/2026-10-26-pending-mints-tenant-scope-design.md`.
**Covers:** `qml/helper/PendingMints.js` (pure), `qml/model/StockBatchStore.qml` (tag on queue, `make` validation, filter on retry/hide, tenant re-check on BOTH the success path and the retry callback, ledger-loaded gate `_loadedTenant`, quarantine of unreplayable items).
**No server change, no deploy.** Updated by the PR #168 final sweep, 2026-10-27.

## What was actually executed in the session (honest)
- Node shim (a throwaway scratch script that loads the pure helper and runs the `TestCase` functions; proven on the pre-sweep file: 52/52 before and after the helper change): `tst_PendingMints.qml` **129/129**.
- Mutation check: **31 hand mutants** of `PendingMints.js` (`make`, `normalize`, `appendRejected`, `forTenant`, `has`, `due`, `sameTenant`, `without`), **31 killed**. One equivalent mutant was reasoned away, not counted (dropping the `typeof inFlight === "object"` check: strings and arrays have no id keys).
- Script tests `node --test .github/scripts/__tests__/*.test.js`: 109/109 after the SKILLS-INDEX regeneration.
- Not run: the QML run (CI), the `StockBatchStore` wiring (device only), Qt in any form.
- Honest limit: the driver in the test file models the store's control flow with the real helper; the inline `!==` tenant check in `addBatch` and the `_loadedTenant` bookkeeping live in the store and are NOT executed by any automated test.

## 1. Unit tests (`tests/tst_PendingMints.qml`, 64 test functions incl. 10 `_data` functions = 129 cases)
| Area | Cases |
|---|---|
| `normalize` | valid kept whole and in order; minimal / fractional / huge-finite qty kept; 17 bad shapes dropped (no/empty/numeric tenant, no/empty id, no/empty product, qty 0 / negative / NaN / Infinity / -Infinity / string, null, number, string, array); `dropped` and `rejected` counted for a mixed list of 5; duplicate ids not deduped (pinned); non-arrays empty; no mutation or aliasing |
| `make` | defaults and `Number()` coercion of `"3"`; supplier / note / cost kept; round-trips through `normalize`; 17 refusals (no/undefined/null/numeric tenant, no id, no/numeric product, qty 0 / negative / NaN / Infinity / text / "" / null / undefined) |
| `appendRejected` | appends in order, JSON round trip incl. `{ raw }`; cap keeps the newest; default cap 50; 6 cap edges (0, NaN, text, negative, fraction, 1); 7 damaged previous values start fresh; non-array entries ignored; inputs not mutated |
| `forTenant` / `has` | own items in order; signed-out (5 junk tenants) -> empty, also for untagged items; case/space/type exact (`7` vs `"7"`); junk lists; new array returned; **same product id in two tenants** hidden only for its own; several items; missing / non-string product refused (5 rows); numeric product id not matched by its digits |
| `due` | tenant's minus in-flight, queue order kept; no tenant starts nothing; in-flight strictly `true`, junk maps and an array tolerated; junk list; inputs not mutated |
| `sameTenant` | 13-row table (empty==empty is false, types, case, trailing space); the "ledger loaded for this tenant" truth table |
| `without` | by id not position; unknown id / undefined / junk; shared id removes both (pinned); new array |
| Scenarios (driver) | queued under A never written under B, replayed once when A returns; **retry before the ledger is loaded mints nothing, asks for the load, then mints**; no tenant yet asks for nothing; empty queue never asks for a load; **stale ledger after an account switch does not count**; account switch while a mint is out keeps the item; two tenants same product id; every retry mint starts under the item's own tenant with a loaded ledger; **second pass while a mint is out starts nothing new**; failed / timed-out mint frees the item; **`addBatch` success after an account switch (or sign-out) is owed to the old tenant, not written to the new**; unchanged tenant writes directly; no tenant at all queues nothing; bad qty never queued, `"4"` coerced |
| Monkey | seeded 26102026, 300 rounds x 40 random steps (queue, `addBatch` with a random answering tenant, sign in/out, ledger load, retry pass, a mint that goes out and stays out, late answers): written only while its own tenant is signed in; every retry mint under its owner and on a loaded ledger; nothing created or lost (`left + written == queued`); an in-flight item is still queued |

## 2. Regression (automated)
`tst_PendingMintAndTopUpSafety` (single-tenant queue/retry/top-up model, now with a drift note), `tst_StockBatchStore*` and the DataModel suites that use the store must stay green. No existing test calls the changed real-store functions (grep for `_onTenantContextReady`, `retryPendingMints`, `_pendingMints`, `hasPendingMint`, `_queuePendingMint`, `_loadedTenant` outside the store and the mirror test). Tests that run the real `addBatch` with no tenant keep working: the success-path check compares `""` with `""` and proceeds.

## 3. E2E / Functions
None; no server change.

## 4. Counts
Not claimed here. Recount from the CI comment on the PR head after pushing (the previous line quoted a head SHA that no longer exists after the rebase onto `main`). Expected QML delta of the sweep over the pre-sweep PR: +77 cases.

---

## On-device test plan
**Prerequisites:** two test accounts/tenants A and B on one device (A = a new tenant with one product `P-001`, B = a new tenant also with `P-001`). To force a failed mint, switch airplane mode ON **before** tapping save on the restock (the mint then fails fast; no timing luck needed). `adb logcat | grep StockBatchStore` shows the log lines named below. Firestore console: collection `stock_batches` of the tenant.

### Happy path
| # | Action | Expected |
|---|---|---|
| H1 | As A, online: restock `P-001` +5; then airplane ON, restock `P-001` +3 | second restock: log "could not mint a batchId — queued for retry"; `P-001` hidden from the order picker |
| H2 | H1, airplane OFF, still as A | log "Synced N batches (all pages)" **then** the mint; batch appears in `stock_batches`, `P-001` is back in the picker |
| H3 | Nothing queued: restock normally | unchanged; one batch, no queue |

### Negative (the bug)
| # | Action | Expected |
|---|---|---|
| N1 | H1 (queued), Sign out (the mint queue is NOT in the sign-out sheet; the sheet's discard only covers outbox and photos), sign in as **B**, airplane OFF | **No** `stock_batches` doc in B; B's `P-001` stays in B's picker; no retry log for A's item |
| N2 | N1, then sign out of B and back in as A, online | A's batch is created once, after A's ledger load |
| N3 | As B only: B has its own queued mint for `P-001` | `P-001` hidden in B only; A (signed in later) sees its own state |
| N4 | Sign out while A has a queued mint, with A's stock delta already counted | stock is unchanged by sign-out; after N2 the stock is backed by a batch again (sum of `qtyRemaining` equals product stock) |

### Edge cases
| # | Action | Expected |
|---|---|---|
| E1 | **Driver-only.** An account switch while a mint is in flight, on the retry path or on the `addBatch` success path (retry callback check, `addBatch` re-check) | not reproducible by hand: a mint answers in well under a second and sign-in takes seconds. Covered by the driver scenarios and the monkey; the log lines "tenant changed during a pending mint -- left queued" / "tenant changed during a mint -- queued for its own tenant" would show it if it ever happens in the field |
| E2 | Kill and reopen the app signed in as A with a queued item, online | log order: "Synced N batches" first, then the retry; the batch is created once. Not only after the next offline->online flip |
| E3 | Queue left by an OLDER build (no tenant): install the PR #167 build, create a queued mint (H1), then install this build over it | log "quarantined 1 unreplayable pending mint(s)"; no crash; product is NOT hidden; the item is not replayed in any tenant. Optional: `adb shell run-as <package>` and read the app's settings file, key `rejectedJson`, to see the item |
| E4 | Sign in as A offline with a queued item, wait, then go online | product stays hidden while offline; once online, the ledger loads, then the mint runs (log order as E2); batch created once |
| E5 | Kill the app while the retry mint is in flight (airplane ON then OFF, then force-stop within a second) | on reopen the item is still queued (it was only removed after the write); at most one batch is created in total, and a gap in the `stockBatches-<year>` counter is acceptable |
| E6 | Two failed restocks of the SAME product as A, then online | two batches are created, both replayed, none lost |
| E7 | Same account, different workspace without a sign-out (only if the app allows it) | A's queued item is not replayed in the other workspace (the resync resets the ledger gate), and is replayed when A's workspace is active again |
| E8 | Offline restock end to end: airplane ON before opening the restock, save, then online | the stock delta syncs through the outbox, the batch follows through the queue; sum of `qtyRemaining` equals product stock at the end |

Moved out of this table: the old E4 ("mint fails while nobody is signed in") is not reachable from the UI; it is a unit case (`make` refuses an empty tenant, driver "no tenant at all queues nothing").

### Multi-scenario / monkey (manual)
Alternate A and B five times with airplane toggles and restocks of the same product id in both: no batch ever appears in the other tenant's `stock_batches`; each tenant ends with exactly the batches it restocked.

### Known limitation (documented, not tested)
The queue is scoped by tenant only, not by user. A different member of the same tenant signing in on the same device (staff vs owner) replays the item under their own permissions; if the rules deny the write the mint fails and the item stays queued. Harmless; the restock design retires the queue.

### Affected areas
| File | Automated coverage | Where to look on device |
|---|---|---|
| `qml/helper/PendingMints.js` | 129 cases, 31/31 mutants | N1-N3 |
| `qml/model/StockBatchStore.qml` | driver model only; the wiring is device-only | H1-H3, N1-N4, E2-E8 |
| `NewOrderDialog` / `OrderDetailDialog` pickers (read `hasPendingMint`) | none | H1, H2, N1, N3, E4 |

### Regression watch
- A same-tenant failed mint is still retried on reconnect and still hides the product (Decision 1 unchanged).
- `topUpOldest` still always synthesizes a labelled batch (Decision 2 unchanged).
- A normal sign-in with an empty queue starts no extra load (no "Synced" log beyond the usual one).
