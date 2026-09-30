# Test plan — stuck-writes dialog + Retry now (part B, S1)

**Branch:** `feat/2026-09-29-stuck-writes-dialog-retry-now`. **Design:** `../specs/2026-09-29-stuck-writes-dialog-retry-now-design.md`.
**Status:** written with the code, before CI. **Nothing was built or run.** Standing rule: no Qt toolchain in the sandbox; CI is the QML signal.

## What was actually executed in the session (Node, not Qt)

- `tst_StuckWrites.qml` and `tst_DescribeItem.qml` (pure JS): every test body run in a Node `vm` harness against the real `.js` files, **51/51 and 40/40 runs**. This caught one real test bug (a raw response body passed where `noteFailure` wants the error code).
- `tst_OutboxStore.qml`: the real `OutboxStore.qml` function bodies were extracted into a Node mirror (bare property names via `with`) and the whole file run, **57/57** including 14 new cases. This caught one test artefact (duplicate requestIds in the monkey test; Gateway mints unique ids).
- **Not executed:** `tst_Gateway.qml` (needs the real singleton graph), the sheet, the header tap. Those are CI / on-device.

## 1. Unit (headless, `tests/`)

| File | New cases | Covers |
|---|---|---|
| `tst_DescribeItem.qml` (new) | 19 functions, 40 runs | 21 entity x action titles (data-driven); name > productName > customer precedence; delete reads `before`; id fallback; trim; blank / non-text names; unknown entity/action; prototype-key names (`constructor`, `__proto__`); batch count + pluralisation; delta; operation (+ empty ops, unknown opType); malformed input (null, string, number, array, function); 500-iteration monkey |
| `tst_StuckWrites.qml` | 10 | `isStuck`; `rows` order, only-stuck, skips ids not queued, terminal flag follows latest answer, null items, no state mutation; monkey (5 seeds x 200 steps) length == stuck-and-queued |
| `tst_OutboxStore.qml` | 14 | `retryNow`: due + attempts 0, backoff restarts at ~2 s, unknown/empty/undefined id, in-flight no-op, works after clearInFlight, only touches named item, payload kept, batch/delta/operation items, survives `_load()`, revision bump only on change; `isInFlight` / `inFlightCount` incl. batch keys and `clear()`; monkey (300 steps) |
| `tst_Gateway.qml` | 18 | `stuckRows` (empty, below threshold, describes, rejected flag, in-flight flag, order == `stuckCount`, no ghost row, record name); `retryStuck` (due + reset backoff, stays stuck + no second toast, lands then leaves count, refuses not-stuck / unknown / in-flight, twice harmless, only chosen write, after `clear()`, keeps rejected label); monkey (200 steps) rows == `stuckCount` |

## 2. Functional / rules / e2e

- **Functional:** the unit cases above are the functional layer (real singletons, real `OutboxStore` persistence).
- **Rules:** no change to `firestore.rules` / `storage.rules`; no rules tests.
- **Server / Node:** server untouched; no `functions/` tests.
- **e2e (emulator):** none for S1. Nothing here reaches the server on a new path. The reject -> park -> discard e2e belongs to S3.

## 3. On-device checklist (the only coverage for the UI)

Setup: use a **dev or test** environment and a **new tenant** (nothing stuck at the start). Stay online. Force a stuck write with one of these (corrected 2026-09-30 after on-device testing):

- **A, no code (403 `no-tenant-context`):** Firestore console -> `users/{uid}.tenantId` -> `tenants/{tenantId}/members/{uid}` (tenant creation already made it) -> set `status` to `"suspended"` (the app's own suspended value; any value other than `"active"` gives the same 403). The app does not react to this while open or after a relaunch, so the write queues and fails. Edit a product name and save. Set `status` back to `"active"` to fix the cause.
- **Caution (found on-device 2026-09-30):** with setup A, force the stuck write with a **single-write action** (edit a product name). Do NOT use Restock: it sends a batch write and a stock delta, the server's 403 drops the delta and only the batch stays queued, so Retry now creates a batch without adding stock. Known issue, decided as a future atomic operation: `docs/superpowers/KNOWN-ISSUES.md` ("Restock is two independent writes", on branch `docs/2026-09-30-restock-atomic-operation`).
- **B, temporary code (404):** local, uncommitted: in `Gateway.qml` point `functionUrl` at `.../recordMutationX`, rebuild, edit a product name. Revert the URL and rebuild to fix the cause (the queued write survives the rebuild). Single-entity writes only (product edits); delta, operation and batch have their own URLs.

**Do not use** a Firestore rules change (Cloud Functions write with the Admin SDK, which bypasses rules) or a stopped emulator (status 0 counts as offline, not stuck). Editing the document in the console only produces the 409 "changed elsewhere" toast, which is deliberately not counted.
The "Rejected by the server" label (`write-rejected`) cannot be produced from the console: it needs a gRPC code 3, 5, 6, 7 or 9 thrown inside `applyMutation`. Mark that row "unit-tested only" unless a throwaway dev function is deployed.

**Happy path**
- [ ] Force one write to fail 5 times (~3 min). Toast appears once. Header caption reads "1 change(s) ... Still retrying." and is **underlined**.
- [ ] Tap the caption: sheet "Changes not syncing" opens, one row: title ("Edited order"), detail (id or name), state line, "Retry now".
- [ ] Fix the cause (setup A or B above), tap "Retry now": toast "Retrying...", row shows "Sending..." then disappears, header line disappears.
- [ ] Rejected write (server `write-rejected`): row says "Rejected by the server. Still retrying." (unit-tested only, see setup)

**Negative**
- [ ] Cause not fixed: tap Retry now (only after ~3 min, once the caption is tappable); row goes "Sending..." then back to "Not syncing"; header line stays; **no second toast**.
- [ ] Go offline: caption becomes the offline message and is **not** tappable.
- [ ] Retry now is disabled while a row shows "Sending...".
- [ ] Nothing stuck: tapping the caption area does nothing (caption hidden).

**Edge**
- [ ] Force-close and reopen while stuck: the write is kept and keeps retrying, but the stuck line is gone in this slice (S1 by design; S2a, PR #100, fixes it).
- [ ] Two stuck writes: two rows, queue order; retry one, the other unchanged.
- [ ] Stock delta / completion / bulk-import stuck: titles "Stock change", "Order completion", "N products changed".
- [ ] Write leaves the outbox while the sheet is open (fixed elsewhere): row vanishes, empty text shows.
- [ ] Android Back with the sheet open closes it (does not exit the app).
- [ ] 20+ stuck rows scroll inside the sheet; small phone and desktop widths.
- [ ] Sign out with the sheet open: sheet empties, no crash.

**Monkey**
- [ ] Hammer "Retry now" on one row and on several rows; rotate the device; background/foreground mid-retry; toggle airplane mode while "Sending...". No duplicate rows, no crash, count matches header.

## 4. Regression watch

`tst_Gateway.qml` stuck-count cases, `tst_OutboxStore.qml` coalescing / in-flight cases, and `tst_StuckWrites.qml` counting cases must stay green: `StuckWrites.rows/isStuck` and `OutboxStore.retryNow` are additive, and `stuckCount` semantics are unchanged.
