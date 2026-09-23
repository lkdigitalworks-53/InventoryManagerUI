# CHECKPOINT — 2026-09-22: C-3 Phase 3 PR 1 (Outbox + Gateway transport) open, Tasks 9-11 next

**Session date:** 2026-09-22 (continues the 2026-09-18/20 arc)
**Branch:** `fix/2026-09-22-atomic-order-completion`, off `main` @ `2c1e5f6` (after #75, #76, #77, #78, #79, #81
merged — verified via `git merge-base`, not assumed)
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-20-atomic-operation-outbox-CHECKPOINT.md`
**Commit identity:** `Taher (via Claude session) <tsowner@lkdigitalworks.com>` (confirmed by Taher). PAT is
supplied by Taher in chat each session and is never written to the repo, `.git/config`, or memory.
**Spec:** `docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md` (D1-D5 approved, on `main`).
**Plan:** `docs/superpowers/plans/2026-09-20-atomic-operation-outbox.md` (13 tasks, 3 phases, on `main`).
**Test plan:** `docs/superpowers/test-plans/2026-09-20-atomic-operation-outbox-test-plan.md` (on `main`; needs a
pass converting "planned" rows to "verified"/CI-run once each PR lands — not done yet).

## Where things actually stand (all live-checked, not assumed)

**Merged to `main`:** #75 (stuck-write indicator), #76 (C-4 rename), #77 (spec/plan/test-plan), #78
(`recordOperation` endpoint, Phase 1 — includes review fixes: `isSafeDocId`/`invalid-request-id`,
`{requestId}~{index}` per-op audit ids, replay guard, an emulator test), #79 (pure helpers, Phase 2 — includes
review fixes: `_has()` own-property checks in `CompletionPlan`, negative-quantity guard, `nextEpoch`
non-negative-integer guard, ponytail cuts to `SendPolicy`), #81 (CI fix: `post-ci-comment.js`'s
`readResultsFile` only ever read one `results.xml` per job, so the E2E job's second JUnit file — the
`recordOperation` emulator test — was silently uncounted even though the job was green; now reads every
`*.xml` in the artifact dir).

**Open, CI in progress:** **#83**, this branch. Phase 3 PR 1 (plan Tasks 6-8): `OutboxStore.enqueueOperation`
+ per-key `dueItems()` ordering + retry jitter; `Gateway` send timeout (settled-flag Timer alongside each
existing XHR, NOT the plan doc's original shared-`_xhrPost`-with-injectable-factory design — the real
`_send`/`_sendBatch`/`_sendDelta` had grown far more elaborate than the plan assumed, so a full reroute was
rejected as too risky in favour of the `AuthService._postJson`-proven pattern, leaving every existing
conflict/QTBUG-49896/callback line untouched); `Gateway.recordOperation` with await mode,
`operationApplied`/`operationRejected` signals. 32 new tests, all hand-traced (no Qt toolchain in the
sandbox) — Tasks 6 and 8's decision logic is pure and fully exercised that way (including driving
`_finishOperation` directly, the same pattern this file already uses for `_noteFailure`); Task 7's actual
Timer/XHR/`abort()` interaction cannot be tested anywhere but on a device or in CI's real `qmltestrunner` run
(no mock HTTP layer anywhere in this codebase — documented in `tst_Gateway.qml`'s own long-standing scope
note). One real bug caught and fixed before committing: `signal.connect(fn)` doesn't return a usable
disconnect handle in QML the way Qt's C++ API does; fixed to disconnect the same function reference.

**Nothing calls `recordOperation` yet.** `DataModel._tryCompleteOrder` still uses the old per-line delta
chain. App behaviour is unchanged by everything merged or open so far. The C-3 bug is **still not fixed**.

## Step log (append-only; resume from the last ticked step)

- [x] 1-11 (2026-09-18 through 2026-09-21): scoping, C-1/C-2/C-4 sequencing, D1-D5 design decisions, spec +
      plan + test plan written, Phases 1-2 implemented and merged, the CI multi-file counting bug found and
      fixed. Full detail in the archived checkpoint above and in PR bodies #74/#76/#77/#78/#79/#81/#83.
- [x] 12. Taher: PR #75 merged; he deploys `recordOperation` himself; asked whether #77/#78 could merge —
      both had already merged by the time this was answered (his own call, reasonable given green CI at the
      time); asked to "continue".
- [x] 13. Found and fixed the CI multi-file counting bug (PR #81, merged by Taher before this session could
      open it itself).
- [x] 14. Phase 3 PR 1 opened as #83 (Tasks 6-8, this branch). CI in progress at session end.
- [ ] 15. **Waiting on:** #83's CI result, Taher's review, and confirmation `recordOperation` is deployed to
      dev (no confirmation received yet either way — Phase 3 PR 2 does not itself need the deployment to be
      written, since nothing in the sandbox calls the live function, but the mechanism is unverified
      end-to-end until it is).
- [ ] 16. Next: Phase 3 PR 2 (plan Tasks 9-10: store hooks on Inventory/StockBatch/Orders/TransactionStore,
      then `DataModel._tryCompleteOrder` itself). Flagged to Taher as the riskiest, least-certain part of the
      whole arc — worth a design nod before starting, not just a code review after. Task 10 in the plan
      document also predates the real current `_tryCompleteOrder` (which has grown since the plan was
      written, same lesson as Task 7) — re-read the live function fully before writing anything, the way
      Task 7 did, rather than trusting the plan doc's draft code verbatim.
- [ ] 17. After PR 2: Phase 3 PR 3 (plan Task 11, the "saved, syncing" UI hint) and Task 12 (docs/tracker/
      `SKILLS.md` sweep — still not touched anywhere in this arc, to avoid a Skill-number collision with #75;
      this is the point to add one). Task 13 (deploy + on-device plan) is Taher's, throughout.

## Cross-arc note (found resolving a CHECKPOINT.md conflict with `main`, 2026-09-24)

A separate, unrelated session has been working `docs/2026-09-24-compliance-reassessment` (P1 stock-movement
taxonomy / compliance): its checkpoint, archived below, plans an "S3: `sale` via `completeOrder`" slice that
explicitly depends on **this** C-3 Phase 3 landing first. That session's compliance-status table also listed
Phase 3 as "not started" as of 2026-09-24 — PR #83 existed and was open at the time, so that's a miss on its
part (didn't check open PRs), not a signal that anything here regressed. Worth flagging to Taher once Phase 3
lands, since S3 will need to build on `_tryCompleteOrder`'s new shape.

## Resume instructions

Fresh session: clone, read this file, re-check live PR/CI state (#83 and anything opened after it), then
continue at step 15. Do not build or run the app until Taher asks. Before touching `DataModel.qml`,
`OrdersStore.qml`, `TransactionStore.qml`, `InventoryStore.qml`, or `StockBatchStore.qml` for Tasks 9-10,
re-read each one fresh on current `main` — do not assume the plan document's draft code for those tasks still
matches reality. `CHECKPOINT.md` conflicts are resolved by keeping the branch's version and archiving
`main`'s copy under `docs/superpowers/specs/`.
