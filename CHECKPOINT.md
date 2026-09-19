# CHECKPOINT — 2026-09-19: `Gateway._send` silent infinite retry (DELETE-FEATURE-ROADMAP item 1) — design gate, no code yet

**Session date:** 2026-09-19
**Branch:** `fix/2026-09-19-gateway-send-terminal-failure`, off `main` @ `212cd4f`
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-02-batch-cleanup-on-delete-design-CHECKPOINT.md`
(it was still sitting at the repo root after PR #65 merged).
**Skills invoked by Taher:** `superpowers:brainstorming` (HARD-GATE: no implementation before an approved
design), `ponytail:ponytail`, `qt-development-skills:qt-qml`. Caveman mode FULL applies to chat replies only;
repo docs and commits are normal prose.
**Commit identity:** `Taher (via Claude session) <dextran52@gmail.com>`. The email is the one Taher supplied for
every commit this session; the name follows the repo's existing convention for Claude-session commits.

## Ask

"Clone the repo, read `docs/superpowers/DELETE-FEATURE-ROADMAP.md` and pick up the important item for the session."

## Standing instructions from Taher (this session)

- Work on a branch, never on `main`. Push when the work is done without asking; Taher reviews in the GitHub PR.
- Do not build or run the app. Do not install Qt tooling in the sandbox; CI is the only test signal for QML.
- Every change: tests aiming at 100% coverage (unit, functional, rules, e2e, regression; happy path, negative,
  edge, multi-scenario, monkey), a test plan from the test-plan template, and `SKILLS.md` / `AGENTS.md` /
  `README.md` updated as needed.
- Honest advisor: show trade-offs, grill before deciding, do not simply agree.
- The GitHub PAT is used for `git push` and the PR API call only. It is deliberately not written anywhere in
  the repo.

## Step log (append-only; resume from the last ticked step)

- [x] 1. Read project notes and the invoked skills.
- [x] 2. Cloned the repo (public clone, no token), set the commit identity, listed branches. `main` @ `212cd4f`.
- [x] 3. Read `DELETE-FEATURE-ROADMAP.md`. Four pending items: (1) HIGH `Gateway._send` retries a failed
      mutation forever, silently; (2) MEDIUM staff delete has no row-level button; (3) MEDIUM five Sales
      Analysis tabs mislabel a deleted product's historical rows (needs stamping category/name on every
      transaction record: schema-level); (4) photo cleanup on delete unverified (blocked on a Storage plan).
- [x] 4. Traced item 1 in code (findings below). Checked overlap: no unmerged branch touches
      `qml/model/Gateway.qml` or `qml/model/OutboxStore.qml`. Only `pr_taher_bug_fixes` touches
      `functions/lib/gatewayLogic.js`.
- [x] 5. Created this branch, archived the stale checkpoint, wrote this file, committed and pushed.
- [x] 6. Asked Q1 (failure policy). Taher chose **D: surface only, keep retrying**: no drop, no rollback, no
      parking; the existing retry behavior stays exactly as it is.
- [x] 7. Verified the candidate surfaces in code (findings below). Found two problems with the "toast +
      ActivityLog" surface that the D pitch assumed.
- [x] 8. Asked Q2 (surface). Taher chose **3: toast once + local per-device banner** bound to a `Gateway`
      stuck count (no ActivityLog entry).
- [x] 9. Looked for an existing banner to reuse (findings below): `GlassHeader` already has a danger-colored
      offline caption line. Drafted the design (below) and asked Q3-Q5 in one tap-card.
- [ ] 10. **Awaiting Taher:** Q3 surface implementation, Q4 sender coverage, Q5 approval and pace. Then write the
      design doc under `docs/superpowers/specs/`, self-review, `superpowers:writing-plans`, implement.

## Item picked and why

Item 1. It is the only HIGH item, and the roadmap itself ranks it above the two delete-specific items. Honest
counter-arguments recorded for Taher: it is not ticket-sized (shared retry logic, 19 non-test
`Gateway.recordMutation(` call sites across 6 stores), whereas item 2 is a small, proven-pattern change and
item 3 is a schema change.

## Findings that shape the design

- `_send` (`qml/model/Gateway.qml`, ~line 423) has exactly one special case: a 409 with `conflict: true` is
  dropped and reported via `mutationConflicted`. Every other non-2xx goes to `OutboxStore.markFailed()`, whose
  backoff table is `[2s, 8s, 30s, 2m, 10m]` with the last delay repeating forever. There is no attempt cap and
  no signal to any caller.
- `_sendBatch` (permanent validation errors are dropped and reported via `batchMutationFailedPermanently`) and
  `_sendDelta` (`_classifyDeltaResponse`) already classify failures. `_send` is the only sender that does not.
- The server collapses every `applyMutation` exception into `500 write-failed` (`functions/index.js`, ~line
  136). A poison write (for example an invalid field value) and a transient blip look identical to the client.
  Client-only classification therefore cannot separate them; the only client-side signal is attempt count.
  Precise classification needs a server change that maps Firestore error codes to distinct HTTP statuses.
- The 400 validation errors (`unsupported-entity`, `unsupported-action`, `missing-fields`) are reachable only
  through client bugs, so classifying just those does not close the black hole described in
  `KNOWN-ISSUES.md` (403 / 5xx after an optimistic delete).
- Offline-first constraint: network errors (status 0) must keep retrying indefinitely. Capping them would break
  offline use. 401 must stay retryable (token refresh).
- Retrying is safe: the server dedupes on `requestId` (`idempotentReplay`). The defect is that the retry is
  unbounded and silent, not that it retries.
- User-facing plumbing already exists: `Toast.show(...)` and `ActivityLog.record(...)`, and
  `_onBatchMutationFailedPermanently` in `InventoryStore` / `OrdersStore` / `SupplierStore` is the template.
  Five stores listen to `mutationConflicted` (Supplier, Orders, StockBatch, Staff, Inventory).
- Possible rollback shortcut to verify in the design: the outbox item carries `before`. Passing it through the
  existing conflict-reconcile path restores an update, restores a delete, and removes a create (`before` is
  null). A held sibling write for the same key would then hit a CAS 409 and self-heal.
- Existing side effect worth recording: `OutboxStore._isItemBlocked` only blocks siblings while an item is
  in flight, so a failing item sitting in backoff does not block a later write to the same key. That later write
  is sent with a `before` the server never saw, gets a CAS 409, and is dropped with an "updated elsewhere" toast.

- Surface findings (step 7): the app has no sync-status UI at all (nothing displays `OutboxStore.hasPending`).
  `Toast.show` is ephemeral. `ActivityLog.record` has two weaknesses for this event. (a) It defaults `actorUid`
  to the current account and `_isOwn` suppresses own entries from the bell and the Notifications sheet, so an
  own-actor entry only shows in the dashboard recent-activity card (the existing `import_error` entries behave
  this way). (b) Passing a non-own `actorUid` would light the bell, but every entry is pushed to the
  tenant-wide Firestore `activity_log`, so it would also show on other staff members' devices, and it is a
  direct write rather than the durable outbox, so it can fail during the very outage it reports. Grepping
  `firestore.rules` found no explicit `activity_log` rule; a wildcard rule may cover it (verify before relying
  on any non-own actor).
- `markFailed` is called from three senders: `_send` (~line 468), `_sendBatch` (~590) and `_sendDelta` (~672).
  A shared "stuck" hook would be one helper called from those three sites.

- Reuse finding (step 9): `qml/components/GlassHeader.qml` (lines ~77-84) has a caption `Text` under the title that
  shows "App is offline, no operation allowed." in `Constants.danger` when `!app.isOnline`. It reads the root
  through `app.isOnline`; no component under `qml/components` imports `../model`, so a header reading `Gateway`
  directly would be the first. `Main.qml` root already carries custom properties, so it can expose
  `syncStuckCount` and the header can read `app.syncStuckCount` the same way it reads `app.isOnline` (verify the
  `app` id resolves to the `Main.qml` root before relying on it).
- `Gateway._reschedule()` runs at the end of `drainNow` and of all three sender handlers (lines ~344, 472, 595,
  684), so pruning stuck state there covers every outbox removal path. `Gateway.clear()` (line ~786) is the
  sign-out reset and must also reset the new state. `Toast` is a singleton in `qml/components`; model files
  already `import "../components"` to use it (`Gateway.qml` needs that import; verify it does not create an
  import cycle).

## Open decisions

- **Q1 (answered):** D, surface only, keep retrying. Rejected: A narrow classify + drop + rollback (catches
  client bugs only); B bound + park + Retry/Discard (much larger, N is a heuristic); C server classification
  first (largest blast radius; a mis-mapped transient error becomes silent data loss).
- **Q2 (answered):** option 3, toast once + local per-device banner. Rejected: toast only (ephemeral), own-actor
  ActivityLog entry (dashboard only, direct write), non-own actor bell (leaks to other devices).
- **Q3 (asked):** implement the banner by reusing the `GlassHeader` caption line (recommended) or a new dedicated
  strip.
- **Q4 (asked):** hook all three senders (recommended) or `_send` only.
- **Q5 (asked):** approve the design, and pace: continue autonomously, stop after the spec for review, or changes.

## Draft design (awaiting approval)

1. **Detection, `Gateway`.** New `stuckCount`; in-memory `_serverFailures` and `_stuckIds` keyed by `requestId`.
   `_isStuckStatus(status)`: `>= 400` and not 401 and not 409 (status 0 never counts). `_noteFailure(item,
   effStatus)` beside each `markFailed`: at the 5th server-side failure (about 3 minutes with the current
   backoff) mark the item stuck, increment `stuckCount`, and toast once when the count goes 0 to 1.
   `_pruneStuck()` inside `_reschedule()` drops ids no longer in `OutboxStore.items` and recomputes `stuckCount`.
   `clear()` resets. Retry, backoff and drop behavior unchanged; no rollback.
2. **Surface.** `GlassHeader` caption: online and `stuckCount > 0` shows "N change(s) not syncing. Still
   retrying." in `Constants.danger`. Offline message keeps precedence.
3. **Scope.** Hook `_send`, `_sendBatch` and `_sendDelta`: same black hole in all three (a stuck delta leaves the
   order-completion callback pending forever). One helper, three one-line calls.
4. **Not fixed.** Local state stays diverged and there is no Retry/Discard (option B, follow-up). The server still
   returns 500 for every write error (option C, follow-up). The counter resets with the app, so the banner returns
   after about 3 minutes if the item still fails. If the QTBUG-49896 workaround does not restore a status,
   status reads 0 and detection never fires.
5. **Tests.** Unit table for `_isStuckStatus`; `_noteFailure` (below, at and past threshold, two items,
   non-stuck statuses, toast once and again after recovery); `_pruneStuck` after `markSent` and `clear()`;
   monkey test over random failure/success/clear sequences asserting `stuckCount` equals live items with 5 or more
   server-side failures, never negative, toast only on 0 to 1. Functions and rules: no change, not applicable.
   Limit: the `onreadystatechange` handlers cannot run in `qmltestrunner` (no mock HTTP layer, see the scope note
   in `tests/tst_Gateway.qml`) and `GlassHeader` needs Felgo `dp()`/`sp()`, so the three call sites and the header
   text are covered by the on-device section of the test plan, not CI.

## Not done, deliberately

No code, no tests, no test plan, no `SKILLS.md` / `AGENTS.md` / `README.md` edits: there is no approved change
to test or document yet, and the brainstorming skill forbids implementation before design approval. The test plan
is written together with the approved design. App not built or run (standing instruction). No Qt tooling
installed in the sandbox (standing instruction).
