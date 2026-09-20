# CHECKPOINT — 2026-09-20: order-completion double-consume (C-3) design kickoff (design gate, no code yet)

**Session date:** 2026-09-20
**Branch:** `docs/2026-09-18-idempotency-scoping-checkpoint`, rebuilt as a single commit on `main` @ `318dd38`
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-16-new-order-double-submit-CHECKPOINT.md`
(byte-identical to what PR #75 archives at the same path, so the two merge cleanly).
**Skills invoked by Taher:** `superpowers:brainstorming` (HARD-GATE: no implementation before an approved
design), `qt-development-skills:qt-qml`, `ponytail:ponytail`. Caveman mode: FULL.
**Commit identity:** `Taher (via Claude session) <tsowner@lkdigitalworks.com>` (repo convention; not verified
against the claude.ai account email). PAT is supplied by Taher in chat each session and is never written to
the repo, `.git/config`, or memory.

## Step log (append-only; resume from the last ticked step)

- [x] 1. Cloned repo, read roadmap, tracker (`ASYNC-REENTRANCY-BUGS.md`) and PR state live.
- [x] 2. Told Taher the item was NOT picked from `main`'s roadmap list: it came from the tracker's C-3 entry
      (the roadmap only got a pointer via PR #73). Taher moved on to sequencing without objecting.
- [x] 3. Rebased PR #73 onto `main` (one roadmap conflict, both sides kept), CI green, then merged by Taher.
- [x] 4. Sequencing analysis: merge #72 first (Taher's on-device retests came back clean per the tracker), then C-3 / C-1. PR #72 and #73 are
      now both merged (`main` @ `318dd38`).
- [x] 5. Taher asked to triage PR #64. Verdict: obsolete, recommend close without merging (below).
- [x] 6. Found a **label collision** on `main` (below) and a new open PR #75 that touches `Gateway.qml`.
- [x] 7. Taher answered Q1-Q4. Q1: yes, rename the Restock entry to C-4. Q2: yes, merge PR #75 first; write
      spec and plan meanwhile, implement after #75 merges. Q3: offline outbox/gateway handling must stay; he
      wants to understand whether, when connected, network calls could go to the server first and then be
      reflected locally (today everything is local first, then server), uniformly across all network calls.
      Q4: yes, two devices with different or the same user ids can complete orders for the same product.
- [x] 8. Rename done: PR #76 (`docs/2026-09-20-rename-restock-c3-to-c4`), docs only.
- [x] 9. Code check before answering Q3 (see "Code facts" below) and re-pointed the recommendation to
      approach D.
- [x] 10. Taher decided: D1 approve approach D; D2 pilot server-first-when-online on compound ops only, via a
      Gateway option; D3 apply an offline-queued completion anyway with a drift-repair batch (the sale
      happened); D4 he deploys the Cloud Functions himself, dev environment only, no prod yet.
- [x] 11. Taher asked whether timeouts, circuit breakers, fallbacks and retry can be part of this design or
      later sessions, and asked for the answer before designing. Answered from code (facts below); proposal
      recorded under "Resilience scope".
- [ ] 12. **Blocked on D5** (resilience scope split, below). Next: spec + plan (docs only) under
      `docs/superpowers/specs/`, then implementation after PR #75 merges.

Not done, deliberately: no code, no tests, no test plan, no `SKILLS.md`/`AGENTS.md`/`README.md` edits: there
is no change to test or document yet; the test plan is written together with the approved design.
App not built or run (standing instruction). No Qt tooling installed in the sandbox (standing instruction).

## PR #64 triage (2026-08-30 docs, 3 commits, 72 behind `main`)

Same topic as work that has since shipped, older snapshot. Its roadmap text says the batch-id mint fix is
"blocked on N3" and the `orderMath.js` parity gap is "decision pending". On `main`: N3 was run on-device and
the mint item was fixed 2026-09-14 (retry queue; `topUpOldest` always synthesizes a batch); `orderMath.js`
parity was implemented 2026-09-01 (100% line and branch); its handler-parity checkpoint is already on `main`
(PR #49). Merging would replace `main`'s root `CHECKPOINT.md` and reintroduce "pending" text on resolved
items. One nugget worth keeping in mind for C-3: `StockBatchStore.topUpOldest` (`:593`) still calls its
callback unconditionally, even if `addBatch` returned no doc; a failed mint now lands in the retry queue,
so it is no longer silent data loss, but the callback still carries no error.

## Findings that shape the C-3 design

- The server already has transport-level idempotency: `recordMutation`/`recordDelta`/batch carry a
  `requestId`, the `audit_log` doc id IS that id, and a repeat returns `idempotentReplay: true` without
  re-applying (`functions/index.js` header, `functions/lib/gatewayLogic.js` ~138-150 and ~187-194).
- It is defeated one layer up: `Gateway._nextRequestId()` (`qml/model/Gateway.qml:130`) mints a fresh
  `"req-" + Date.now() + "-" + random` per call, so a re-run of `_tryCompleteOrder` after its in-memory
  guard is lost gets new ids and the server cannot recognise them as the same operation.
- `StockBatchStore.consumeFifo` plans from *local* `qtyRemaining` and reconciles floor rejections against
  the server's `current`; its plan is not stable across attempts.
- `Gateway.recordDelta` coalesces queued deltas for the same entity+entityId, so the surviving `requestId`
  can belong to an earlier call. Any caller-supplied key scheme must account for that.
- Reasoning, not measured: adding XHR timeouts *before* operation-level idempotency turns "hung" into
  "outcome unknown", which is what produces double-apply on retry.

## Candidate approaches (Taher's stated direction: general, not a one-call patch)

- A. Stable operation keys only (deterministic `requestId` passed by callers). Smallest diff, no server
  change. Holes: FIFO plan drift on partial drain, same key + different delta silently replayed with the
  old `after`, key reuse across a legitimate re-completion needs an epoch.
- B. Write-ahead intent + stable keys: persist the plan on the order first, derive every step's key from the
  intent id, resume from the persisted plan. Closes A's holes, reusable for C-1. Costs: order schema field,
  rules/validation, old-client compatibility, resume trigger. Logic can live in a pure JS helper so 100%
  coverage is measurable in Node.
- C. Server-side `completeOrder` Cloud Function with a Firestore transaction: true atomicity, fully
  Node-testable. Costs: no precedent, offline-first tension, FIFO/top-up/tax math re-homed, deploy-order
  coupling with client releases. Largest blast radius.
- Recommendation on record: B, scoped first to `_tryCompleteOrder`, C-1 as second consumer; A only as a
  stopgap. Not a new network layer.

## Code facts checked after Q3/Q4

- The server is already the only writer of `inventory`, `stock_batches`, `stock_movements` (header of
  `functions/index.js`); each single mutation is one Firestore transaction with one `audit_log` entry.
- `recordMutationsBatch` is atomic but single-entity and mutations only (`batchMutationLogic.js`, cap 200
  items): it cannot carry deltas or span `stock_batch` + `inventory` + `order` + `transaction`. No QML caller
  uses it outside Gateway/Outbox.
- `applyDelta`/`applyMutation` (`gatewayLogic.js`) each wrap their own `db.runTransaction` around a short
  read -> compute -> two-writes body, so a multi-op variant in ONE transaction is a composition, not a rewrite.
- `_tryCompleteOrder` (post-#72) does per line: `consumeFifo` (+ `topUpOldest` on shortfall), then
  `deductStock` with reject-not-clamp; then `OrdersStore.updateOrder`, `SalesStore.recordSale`,
  `TransactionStore.recordSaleFromOrder`. On partial failure it compensates client-side with `restoreFifo` and
  `creditStockNoBatch`.

## Approach D (recommended after Q3/Q4): one atomic, idempotent multi-write op through the outbox

- Client still plans the writes from local state (FIFO, top-up, stock delta, order update, sale doc) but sends
  them as ONE outbox item with ONE stable `opKey` (= `requestId`): a new generic server endpoint applies all
  ops in a single Firestore transaction, floors checked inside, all-or-nothing, replay-safe.
- No FIFO logic is re-homed server-side (that is what makes C big). The server stays generic.
- Fixes the C-3 mechanism (retry after a hang resends the same `opKey`: exactly-once) and the concurrency case
  (Q4): if another device drained a batch, the whole op is rejected atomically with `current` values and the
  client re-plans; a new `opKey` is minted only after a definitive rejection, never after an ambiguous hang.
- Deletes the compensating rollback code in `_afterAllDeltas` (atomicity replaces it).
- Reusable for C-1 (`_tryAdjustOrder`) and any future multi-write business operation.
- Server code is Node-testable in the sandbox (100% line/branch measurable there); QML side stays thin.
- Costs: refactor `gatewayLogic` into composable read/plan/write helpers; new endpoint + Outbox item type +
  Gateway sender (touches the same senders as PR #75); audit_log needs per-op entry ids derived from the
  request id plus a request-level replay marker; op cap (~200 ops, 2 writes each); functions must deploy before
  the client; old clients keep the old path (no worse than today).
- Q3 answer (server-first when online): valid, but it is not a substitute for idempotency; it needs
  timeouts + fallback-to-outbox, and the fallback is only safe with stable keys. Recommendation: make it a
  Gateway option used first by compound ops (await ack when online, reflect the server's `after`; offline =
  optimistic + outbox as today), not an app-wide rewrite in this arc. Reasons: every tap would wait on network
  latency, the app has no XHR timeouts today, it needs two code paths per operation, and it does not by
  itself make multi-step operations atomic.

## Resilience facts (checked on `main` @ `318dd38`)

- No request timeout anywhere in `qml/`. The one precedent is `AuthService._postJson` (20s `Timer` racing the
  XHR, then `abort()`).
- `Gateway._send` (and `_sendBatch`/`_sendDelta`) are bare XHRs. On failure they call
  `OutboxStore.markFailed`, which backs off 2s, 8s, 30s, 2m, 10m, then stays at 10m. No jitter.
- Retry only starts after a request *fails*. A hung request never fails, and while it is pending the item's
  in-flight key and `Gateway.inFlight` stay set, so that item is not retried in that session.
- `AuthService.isOnline` is set from `Main.qml` (OS connectivity), so it means "device thinks it has a
  network", not "the server is reachable".
- A timeout on Gateway sends is safe today because each outbox item keeps one `requestId` and the server
  replays it. It is NOT automatically safe for non-Gateway calls (`FirebaseService._request`: reads and
  id mints); a retried mint could burn an id. Not verified per call site.

## Resilience scope (proposed, awaiting D5)

In this design (D needs them):
- One shared XHR helper for all Gateway senders (`_send`, `_sendBatch`, `_sendDelta`, new operation sender):
  `Timer` race + `abort()`, following the `AuthService._postJson` precedent. A timeout is treated as a network
  failure and goes through the existing backoff. Two values: a generous one for background outbox drains and a
  short one for the server-first await (numbers tuned on device; not measured yet).
- Fallback = the offline path: the item is durable in the outbox before the send; when the await times out,
  the UI moves to "saved, syncing", the same-session guard stays set until the ack, and the drain resends the
  same `opKey`. Offline (`isOnline` false) skips the await and queues immediately.
- Retry: keep the schedule and add small jitter (two devices reconnecting together). Retry classification stays
  as is (PR #75's rules).
- Decision logic (outcome classification, delay with jitter) goes in a pure JS helper like `StuckWrites.js`, so
  it is Node-testable; the Timer/XHR wiring is covered by the on-device section, not automated tests.
- Open point for the spec: whether repeated timeouts count toward PR #75's "stuck" indicator (today only
  status >= 400 except 401/409 count and offline never does).

Later, separate specs, in this order:
1. Circuit breaker (closed / open / half-open) at the shared helper. Needs real timeout data to tune, a
   definition of failure (timeouts and 5xx, not 4xx/409/floor rejections), and a UX signal (reuse #75's header
   caption). Risk: a false open leaves the app queue-only while the server is fine; half-open probing limits it.
2. Timeouts for `FirebaseService._request` (reads, id mints): the existing roadmap item; each caller's failure
   handling has to be reviewed first.
3. Read fallbacks (serve the local cache on a read timeout), per store.
No speculative policy hook is added now: the shared helper is already the single choke point.

## Found this session, needs a decision

- **Two different bugs are both labelled "C-3" on `main`.** `ASYNC-REENTRANCY-BUGS.md:175` is the
  `RestockDialog` double-press entry (resolved, no repro: stale-build explanation, no code changed) and
  `:214` is `_tryCompleteOrder` (this arc). `AGENTS.md:453` and `README.md:720` mean the Restock one; the
  roadmap (`:59-73`) and PR #73 mean the order-completion one. Textually the two PRs merged without
  conflict, which hid it. Proposed fix: renumber the Restock entry to C-4 (closed) and update its cross-refs.
- **PR #75** (open, not from this session, CI 1108/1108, `mergeable_state: clean`): Gateway "stuck write"
  indicator. Touches `Gateway.qml` `_send`/`_sendBatch`/`_sendDelta`, the same file C-3 would touch.
  Recommend merging it before the C-3 implementation branch, same reasoning as #72.

## Decisions

- D1 approve approach D. D2 pilot server-first on compound ops only. D3 apply anyway with drift-repair.
  D4 Taher deploys functions, dev-only, no prod yet. (All answered by Taher on 2026-09-20.)
- D5 (open). Confirm the resilience split above: timeout + fallback-to-queue + jitter in this design;
  circuit breaker, `FirebaseService._request` timeouts and read fallbacks as later specs.

## Resume instructions

Fresh session: clone, read this file, re-check open PR state live (#64, #74, #75, #76), then continue at step 12.
Do not start implementation before the design is approved. `CHECKPOINT.md` will conflict with PR #75's copy;
resolve by keeping the branch version and archiving `main`'s under `docs/superpowers/specs/`.
