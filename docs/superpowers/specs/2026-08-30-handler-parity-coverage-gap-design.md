# Design: closing the `recordDelta`/`recordMutationsBatch` HTTP-layer coverage gap

**Date:** 2026-08-30
**Status:** approved (autonomous session — see note on process below)
**Scope:** `functions/test/index.handlers.test.js` only. No production code changes.

## Where this came from

Picked from `docs/superpowers/E2E-TESTING-ROADMAP.md`. That doc currently has exactly one
actionable item that doesn't require Taher's input first: the three "Needs Taher's input" entries
(silent batch-id-mint swallow, `orderMath.js` parity, account-switch-mid-sync) are all explicitly
marked "not scoped or estimated yet — deliberately." Implementing any of those without Taher's
actual scoping decision would mean guessing at a decision the roadmap itself says isn't safe to
guess at (`orderMath.js` parity's entry literally says "not enough carried-forward context to
define 'parity' honestly"). Picking one of those up anyway would violate this repo's own stated
discipline against unscoped work, not honor it.

This item — flagged under "Resolved this arc" as a side-finding, not itself resolved — is the one
concrete, bounded, non-blocked gap on the board: `recordMutation`/`recordDelta`/
`recordMutationsBatch` are missing method-not-allowed (405) tests for all three, and `recordDelta`
specifically is missing invalid-token (401) and write-failed (500) tests that `recordMutation`
already has. The roadmap's own words: "cheap to close if/when it's picked up: same harness, same
pattern, no new mocking needed." Verified that claim directly (read `functions/index.js`'s three
handlers end to end plus the full existing test file) before trusting it — it holds.

## Problem, precisely

`functions/test/index.handlers.test.js` exists to catch the class of bug Skill 43 found: a `lib/`
function computing a result correctly, and `index.js`'s hand-built HTTP response silently dropping
or mis-forwarding part of it. All three endpoints in that file — `recordMutation`, `recordDelta`,
`recordMutationsBatch` — share the exact same shape: `OPTIONS` short-circuit → method check →
bearer-token parse → `verifyIdToken` → body validation → `deriveContext` → the lib call → response
translation. But the file's actual test coverage isn't symmetric across the three:

| Case | recordMutation | recordDelta | recordMutationsBatch |
|---|---|---|---|
| 200 success | yes | yes | yes |
| ok:false result forwarding | yes (x2) | yes | yes |
| 400 invalid body | yes | no | yes (empty-batch only) |
| 401 missing-token | yes | yes | no |
| 401 invalid-token | yes | no | no |
| 403 no-tenant-context | yes | no | no |
| 405 method-not-allowed | no | no | no |
| 500 write-failed | yes | no | no |

## Root cause of the asymmetry

Not a logic bug — a coverage-authoring artifact. The file's own header comment says its scope is
Skill 43's bug class, and Skill 43's bug specifically lived in `recordMutation`'s conflict
forwarding. That's almost certainly why `recordMutation` got the full auth/error matrix (it was
the endpoint under active investigation) while `recordDelta`/`recordMutationsBatch` got just enough
to prove the response-forwarding pattern once each (their own conflict-shape regression tests) and
a happy path, without anyone deliberately deciding "these two need less coverage than
`recordMutation`." Confirmed by reading the file's git history via `git log -p` on the relevant
hunks — the three endpoints' tests were added in separate passes, not as one symmetric pass.

## Solution

Add the missing cells above, mirroring `recordMutation`'s existing test bodies and the harness
patterns already in the file (`mockState.verifyIdToken` override for 401, `mockState.docs = {}`
for 403, `mockReq({ method: "GET" })` for 405, the `require.cache`-patch pattern already used for
`recordMutation`'s 500 test, applied to `GatewayLogic.applyDelta` and
`BatchMutationLogic.applyMutationsBatch` respectively). No harness changes — `testSupport/
handlerHarness.js` already exposes everything needed; the roadmap's "no new mocking needed" claim
is confirmed correct by inspection.

**New tests (9):**
- `recordMutation`: 405 method-not-allowed (1)
- `recordDelta`: 401 invalid-token, 403 no-tenant-context, 400 invalid entity, 405
  method-not-allowed, 500 write-failed (5)
- `recordMutationsBatch`: 401 missing-token, 401 invalid-token, 403 no-tenant-context, 405
  method-not-allowed, 500 write-failed (5, but `recordMutationsBatch` already has 400 coverage via
  its empty-batch test, so no new 400 test needed there) — actually 5 minus the one already covered
  elsewhere nets to 5 new; see table above for the exact cells filled.

(Exact count reconciled against the table during implementation — the table is the source of
truth, this bullet list is a preview.)

**Not doing:** no change to any endpoint's actual behavior, no new harness mocking, no touching
`acquireLock`/`releaseLock`/`provisionMember`/`runCutover`/`computeAnalysis` (already fully covered
per Skill 52), no touching the two previously-flagged unreachable-code findings (`canAssignRole`'s
dead branch, `send()`'s unreachable catch) — those aren't test gaps, they're dead-code findings
with no legitimate path to exercise, and manufacturing an artificial test for unreachable code
would be a fake test, not real coverage.

## A note on process

This repo's standing convention is brainstorm → spec → plan → approval → implementation, with a
live approval gate between spec and implementation. This session's instructions explicitly waived
the live gate for this pass ("write design spec and plan if needed, then implement it," "don't
wait for permission to push," single-prompt constraint) — so this doc is being written and acted on
in the same pass, not across a approval round-trip. Flagging that explicitly rather than silently
treating "wrote a doc" as equivalent to "got approval": the two are different things, and the gap
between them is a deliberate, instructed trade-off for this session, not this repo's normal mode.
For a change this size (one existing test file, no production code, no new mocking, mirroring an
established in-file pattern), the risk of proceeding without the live round-trip is low — but it's
a real trade-off, not a free one, and it wouldn't be the right call for anything touching production
code, architecture, or the three items still waiting on Taher's actual scoping decisions above.
