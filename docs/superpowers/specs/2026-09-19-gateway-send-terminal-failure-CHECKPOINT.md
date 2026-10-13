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
- [x] 10. Taher answered Q3 (reuse the `GlassHeader` caption), Q4 (all three senders), Q5 (approve; run spec, plan
      and implementation autonomously; he reviews in the PR).
- [x] 11. Wrote and committed the spec (`docs/superpowers/specs/2026-09-19-gateway-stuck-write-indicator-design.md`)
      and the plan (`docs/superpowers/plans/2026-09-19-gateway-stuck-write-indicator.md`).
- [x] 12. Task 1: `qml/helper/StuckWrites.js` + `tests/tst_StuckWrites.qml` (21 cases). Ran the test bodies in Node:
      21/21 green, 8/8 deliberate mutations caught.
- [x] 13. Task 2: `Gateway.qml` (`stuckCount`, `_noteFailure`, `_pruneStuck`, hooks in all three senders, `clear()`
      reset) + 10 new cases in `tests/tst_Gateway.qml`.
- [x] 14. Task 3: `Main.qml` `syncStuckCount` + `GlassHeader.qml` caption.
- [x] 15. Task 4: test plan (Skill 49 structure), test-plans index row, `SKILLS.md` Skill 67, `AGENTS.md` helper
      entry, README update paragraph, KNOWN-ISSUES and roadmap status notes.
- [x] 16. Found PR #75 unmergeable (main moved: PR #72 merged), so CI had not triggered. Merged `origin/main` in
      (`e61117d`): kept this checkpoint, archived the PR #72 session's to
      `docs/superpowers/specs/2026-09-16-new-order-double-submit-CHECKPOINT.md`, kept both README / index
      entries, renumbered this session's skill to 67 (main already has two entries numbered 66).
- [x] 17. CI on `e61117d`: all four jobs green, 1108/1108 (QML 901, Functions 138, Rules 28, E2E 41).
- [ ] 18. On-device pass by Taher using the test plan's On-Device section (only coverage for the three sender call
      sites and the header caption). PR #75 is still a draft; Taher marks it ready.

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

## Decisions (all answered)

- Q1 D: surface only, keep retrying. Q2 3: toast once + local per-device indicator. Q3 reuse the `GlassHeader`
  caption. Q4 all three senders. Q5 approve, autonomous. Rejected options and reasons are in the spec.

## Not done / follow-ups (stated in the spec, test plan, KNOWN-ISSUES and Skill 67)

- Local state still diverges while a write is stuck; no in-app Retry / Discard (option B).
- The server still returns `500 write-failed` for every write exception (option C).
- The counter is in memory: it restarts with the app.
- The three sender call sites and the `GlassHeader` caption have no automated coverage (no mock HTTP layer, Felgo
  `dp()` / `sp()`): on-device plan only. 100% line coverage of that wiring is not reachable in CI today.
- `SKILLS.md` on `main` has two entries numbered 66 (predates this PR, left alone).
- No sandbox build or app run (standing instruction); no Qt tooling installed.
