# Test plan — stuck state survives a relaunch (part B, S2a / decision P5)

**Branch:** `feat/2026-09-29-s2a-persist-stuck-state`, stacked on PR #97 (`feat/2026-09-29-stuck-writes-dialog-retry-now`). **Decision:** plan `../specs/2026-09-29-gateway-park-retry-discard-plan.md`, P5 and its (a)-(d).
**Status:** written with the code, before CI. **Nothing was built or run.** Standing rule: no Qt toolchain in the sandbox; CI is the QML signal.

## What S2a changes

Each stuck-write fact is now mirrored onto the queued outbox item (`failures`, `stuck`, `terminal`) and rebuilt at launch (`Gateway.resumeStuck`, called from `Main.qml` before the first drain). Stuck items are made due once at launch (`OutboxStore.wakeStuck`, attempts NOT reset). No toast at launch. Park / Discard are not here (S2b).

## What was actually executed in the session (Node, not Qt)

- `qml/helper/StuckWrites.js` loaded in a Node `vm`: the `hydrate` / `metaOf` cases from `tst_StuckWrites.qml` plus the relaunch monkey (400 steps, relaunch at random points), **1217 assertions passed**. Throwaway harness, not committed.
- **Not executed:** `tst_OutboxStore.qml` and `tst_Gateway.qml` (real singletons, need Qt), and everything on device.

## 1. Unit (headless, `tests/`)

| File | New cases | Covers |
|---|---|---|
| `tst_StuckWrites.qml` | 16 | `metaOf` (unknown write, counting, stuck+terminal); `hydrate` (non-array inputs, stuck restore, counting restore keeps its tip point, terminal label, threshold derives stuck, stuck with too-low or missing count repaired so it cannot toast twice, count above threshold never re-tips, malformed items and fields incl. NaN / negative / fractional / string, output accepted by `prune`, input not mutated); `metaOf` -> `hydrate` round trip; monkey: a relaunched state and a never-relaunched state make identical tip decisions and counts over 400 steps |
| `tst_OutboxStore.qml` | 18 | `setStuckMeta` (stores three fields, survives `_load()`, falsy fields omitted so an untouched item is byte-identical, fields removed when no longer true, unchanged value does not save, unknown / empty / undefined id, missing or malformed meta, touches only the named item, survives `markFailed` / `retryNow` / coalesced edit, gone with `markSent`); `wakeStuck` (backed-off stuck item due, attempts kept, failed re-check waits the 10-minute step again, non-stuck untouched, in-flight skipped, no save when nothing moves, empty queue, several items); monkey: random meta / mark / wake / relaunch / retry never lose or duplicate an item and `stuck` matches what was set |
| `tst_Gateway.qml` | 16 | `_noteFailure` writes counts, tipping marks stuck, rejected -> terminal and a later outage answer clears it, uncounted failures write nothing; relaunch restores count, terminal count and the dialog row; relaunch never toasts; relaunch wakes a backed-off stuck write once and only once; a failed re-check counts on top and never re-tips; a write that lands after relaunch clears the line; a failure arriving before `resumeStuck` cannot erase persisted state; still-counting writes tip on time after relaunch; no stuck writes -> nothing changes; several writes restore only the stuck ones; sign-out clears and the next launch resumes again; monkey: persisted state matches live state across random failures and relaunches |

## 2. Functional / rules / e2e

- **Functional:** the unit cases above are the functional layer (real singletons, real `OutboxStore` persistence via `Settings`).
- **Rules:** no change to `firestore.rules` / `storage.rules`; no rules tests.
- **Server / Node:** server untouched; no `functions/` tests.
- **e2e (emulator):** none. No new server path. The reject -> park -> discard e2e belongs to S3.

## 3. On-device checklist (the only coverage for relaunch, header and dialog)

Setup: use a **dev or test** environment and a **new tenant** (so nothing is stuck at the start). Force a stuck write with either (A) set your member doc `tenants/{tenantId}/members/{uid}.status` to `"suspended"` (403; the app ignores the status, also after a relaunch), or (B) a local, uncommitted wrong `functionUrl` (404). Full steps in the S1 test plan section 3. Do **not** use a rules change or a stopped emulator: Admin SDK bypasses rules, and a stopped emulator is status 0 = offline. Online throughout. With setup B, revert the URL only when the checklist says to fix the cause: a rebuild is also a relaunch, so it restores the stuck state at launch too.

**Happy path**
- [ ] Edit a product name, wait ~3 min: toast once, header line underlined, dialog shows the row.
- [ ] Force-close and reopen the app **while the cause is still there**: header line is back **at launch** (before any retry finishes), dialog shows the same row, **no toast**.
- [ ] Within a few seconds of launch the write is re-tried once (row shows "Sending..." then "Not syncing"); it does not wait ~10 minutes.
- [ ] Undo the cause, reopen: the launch re-check sends it, row and header line disappear, product name lands on the server.

**Negative**
- [ ] Cause still there after reopen: no second toast, header line stays, next retry is on the long backoff (not every few seconds).
- [ ] Offline at launch: caption is the offline message, not tappable; going online re-checks the write.
- [ ] Sign out, sign in as another account: no header line, no rows from the previous account.
- [ ] Type-A setup: reopen with the dialog row labelled by the server answer; after the cause changes to a different failure (e.g. switch A to B), the label follows the latest answer after the next failed attempt.

**Edge**
- [ ] Two stuck writes, one write still counting (fewer than 5 failures): reopen -> header says 2 (not 3), the counting write tips after the remaining failures with one toast.
- [ ] Reopen five times in a row while stuck: count and rows stay the same; no growth in the outbox.
- [ ] Stuck write edited again while stuck (coalesced): still stuck after reopen, latest value is the one retried.

**Monkey**
- [ ] Repeatedly force-close the app at random moments during a stuck retry, toggle airplane mode across launches, rotate the device. Header count always equals the number of dialog rows; no crash, no duplicate or lost writes.

## 4. Regression watch

`tst_Gateway.qml` stuck-count / stuckRows / retryStuck cases, `tst_OutboxStore.qml` coalescing / in-flight / retryNow cases and `tst_StuckWrites.qml` counting / rows cases must stay green. `Gateway.clear()` now also re-arms `resumeStuck`. Old saved items (no `failures` / `stuck` / `terminal`) must load unchanged (covered by unit tests; no S1 build with stuck writes exists outside test devices, and every PR is tested on a new tenant).
