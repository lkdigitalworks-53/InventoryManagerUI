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
- [ ] 6. **Grill Taher** on the failure policy (Q1 below), one question at a time. Then brainstorming steps 4-5
      (approaches, design in sections, approval), design doc under `docs/superpowers/specs/`, then
      `superpowers:writing-plans`.

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

## Open decisions (grilling queue)

- **Q1 (asked):** failure policy for a non-network, non-401, non-409 failure. Options: A narrow classify and
  drop + rollback; B bound, park, user Retry/Discard; C server-side classification first, then drop; D surface
  only (signal + toast + activity log, keep retrying).
- Q2: which statuses count as "stuck" (5xx only, or 403 too), and the attempt threshold.
- Q3: whether the fix also unifies `_sendBatch` / `_sendDelta` classification, or leaves them alone.

## Not done, deliberately

No code, no tests, no test plan, no `SKILLS.md` / `AGENTS.md` / `README.md` edits: there is no approved change
to test or document yet, and the brainstorming skill forbids implementation before design approval. The test plan
is written together with the approved design. App not built or run (standing instruction). No Qt tooling
installed in the sandbox (standing instruction).
