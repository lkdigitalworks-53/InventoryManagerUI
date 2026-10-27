# Test plan — pending batch-id mints are tenant-scoped

**Branch:** `fix/2026-10-26-pending-mints-tenant-scope`, STACKED on `feat/2026-10-26-signout-guard` (PR #167). **Design:** `specs/2026-10-26-pending-mints-tenant-scope-design.md`.
**Covers:** `qml/helper/PendingMints.js` (new, pure), `qml/model/StockBatchStore.qml` (tag on queue, filter on retry/hide, mid-flight check, load cleanup, `tenantContextReady` retry).
**No server change, no deploy.**

## What was actually executed in the session (honest)
- Node shim (same as the sign-out guard plan; proven on `tst_DescribeItem` 43/43): `tst_PendingMints.qml` **52/52**. First run found a bug in MY test driver (fake ids collided after removals), fixed in the test; no helper bug.
- Mutation check: 15 hand mutants of `PendingMints.js`, **14 killed on the first pass, 1 survivor** (an untagged item matching a signed-out state), a case was added and the mutant is now killed: **15/15**.
- Not run: the QML run (CI), the `StockBatchStore` wiring (device only).

## 1. Unit tests (`tests/tst_PendingMints.qml`, 21 test functions + 4 data functions = 52 cases)
| Area | Cases |
|---|---|
| `normalize` | valid kept; 15 bad shapes dropped (no/empty/numeric tenant, no/empty id, no/empty product, qty 0 / negative / NaN / string, null, number, string, array); non-arrays empty; no mutation or aliasing |
| `forTenant` / `has` | own items in order; signed-out (5 junk tenants) -> empty, also for untagged items; case/space exact; junk lists; **same product id in two tenants** is hidden only for its own |
| `due` | tenant's minus in-flight; no tenant starts nothing; in-flight must be strictly `true`, junk maps tolerated |
| `sameTenant` | 9-row table incl. empty==empty is false |
| `without` | by id not position; unknown id; junk |
| Scenarios | queued under A never written under B, replayed once when A returns; no tenant yet -> nothing, then the tenant-ready pass retries; account switch while the mint is out keeps the item; two tenants same product id; failure with no tenant is not queued |
| Monkey | seeded 26102026, 200 rounds x 30 random steps (queue, sign in/out, retry pass with random answering tenant): a batch is only written while its own tenant is signed in; nothing is created or lost (`left + written == queued`) |

## 2. Regression (automated)
`tst_PendingMintAndTopUpSafety` (queue/retry/top-up model), `tst_StockBatchStore`, the DataModel suites that use the store must stay green. No existing test calls the changed real-store functions (grep).

## 3. E2E / Functions
None; no server change.

## 4. Counts (observed, CI comment on PR #168, head `c0e6f93`)
**3301/3301 green** = QML 2228, Functions 866, Rules 106, E2E 101. This PR adds **54** to the QML number (52 expanded cases + the runner's `initTestCase` / `cleanupTestCase`), on top of PR #167's 55 (3247). Recount from the CI comment after any rebase, not from this line.

---

## On-device test plan
**Prerequisites:** two test accounts/tenants A and B on one device (A = a new tenant with one product `P-001`, B = a new tenant also with `P-001`). Airplane mode to force a failed mint: restock A's product, switch airplane mode on within a second of tapping save (the mint is the first call to hang). `adb logcat | grep StockBatchStore` helps.

### Happy path
| # | Action | Expected |
|---|---|---|
| H1 | As A: restock `P-001` +5 with a new supplier, airplane mode on right after save, wait 20 s | log "could not mint a batchId — queued"; `P-001` hidden from the order picker (as before) |
| H2 | H1, airplane off, still as A | batch appears (Firestore `stock_batch`), `P-001` is back in the picker |
| H3 | Nothing queued: restock normally | unchanged |

### Negative (the bug)
| # | Action | Expected |
|---|---|---|
| N1 | H1, then Sign out (accept the sheet's discard if shown; the mint queue is NOT in that sheet), sign in as **B**, airplane off | **No** `stock_batch` is created in B; B's `P-001` is still in B's order picker; log has no retry for A's item |
| N2 | N1 then sign out of B and sign back in as A, online | A's batch is created now, once |
| N3 | As B only: B has its own queued mint for `P-001` | `P-001` hidden in B only; A (signed in later) still sees its own state |

### Edge cases
| # | Action | Expected |
|---|---|---|
| E1 | A's retry in flight (online flip), immediately sign out and sign in as B | log "tenant changed during a pending mint -- left queued"; nothing written in B; the item is still A's |
| E2 | Kill and reopen the app while signed in as A with a queued item, online | the retry runs after the tenant is ready (log), not only after the next offline->online flip |
| E3 | Queue left by an OLDER build (no tenant) on a dev device | log "dropped 1 unreplayable pending mint(s)"; no crash, product not hidden |
| E4 | Mint fails while signed out of every tenant (not reachable from UI) | not queued (log) |

### Multi-scenario / monkey (manual)
Alternate A and B five times with airplane toggles and restocks of the same product id in both: no batch ever appears in the other tenant's `stock_batch` collection; each tenant ends with exactly the batches it restocked.

### Affected areas
| File | Automated coverage | Where to look on device |
|---|---|---|
| `qml/helper/PendingMints.js` | 52 cases, 15/15 mutants | N1-N3 |
| `qml/model/StockBatchStore.qml` | none (singleton, device) | H1-H3, E1-E3 |
| `NewOrderDialog` / `OrderDetailDialog` pickers (read `hasPendingMint`) | none | H1, H2, N1, N3 |

### Regression watch
- A same-tenant failed mint is still retried on reconnect and still hides the product (Decision 1 unchanged).
- `topUpOldest` still always synthesizes a labelled batch (Decision 2 unchanged).
