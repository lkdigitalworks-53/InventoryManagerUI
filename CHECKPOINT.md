# CHECKPOINT — 2026-10-15 PR #139 test-plan rewrite (resume here)

**Branch:** `docs/2026-10-13-completion-error-cause-design` (PR #139's own branch; Taher said push straight here).
**Commit identity:** `dextran52@gmail.com`. PAT only in the push command, never in a file or git config.
**Rules in force:** do not build/run the app; no Qt tools in the sandbox (CI is the proof); push without asking, Taher reviews in the PR; short scope (token budget); honest trade-offs, grill before deciding.
**Skills used:** `superpowers:brainstorming` (review + options, Taher chose option A: full rewrite to Skill 49, two commits).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-15-test-plan-rewrite-prev-CHECKPOINT.md`.

## Why
Taher's review of the test plan `docs/superpowers/test-plans/2026-10-13-completion-error-cause-test-plan.md`: (1) an "Implementation status" block inside a test plan (stale counts: 34 planned / 49 written / README 48), (2) not Skill 49 shape, (3) on-device steps poor (no prerequisites, no numbered steps, no expected outcomes). New standing rule: on-device steps always have prerequisites, numbered actions, expected outcome per step.

## Taher's device recipes (used in the plan)
- Recipe A: set `tenants/<tenantId>/members/<uid>.status` to `inactive` in Firestore while the app is open -> server 403 `no-tenant-context` (stuck, retrying, NOT parked) -> cause text is the generic "The server returned an error (HTTP 403)".
- Recipe B: delete the product doc in Firestore -> `not-found` text, or the local "<name>: not found in inventory".
- No recipe forces a 500 `write-rejected` -> the Rejected row / Retry / Discard / "refused" wording stay unit/functional only (stated in the plan).

## Steps
- [x] 1. Read plan, Skill 49, approve-all exemplar, FailureCause.js, Gateway/StuckWrites/DataModel diffs; traced what each recipe produces
- [x] 2. Commit 1: replace on-device section with the full plan (prerequisites P1-P9, H/N/E/M/K steps with expected results, affected areas, regression cues, not-testable list)
- [ ] 3. Commit 2: restructure the rest to Skill 49 (Unit, Functional, Regression, Monkey, Rules/E2E), counts recounted (49 = 16+10+3+5+5+10), "Implementation status" replaced by a short "Verification status", history moved out; README index row fixed (48 -> 49, no "planned"); Skill 49 addendum; script tests
- [ ] 4. Push, then wait for CI

## NEXT
If step 3 is not done: restructure sections 1-5 of the plan per the list above, fix the README row, run the script tests under `.github/scripts`, push.
Open decision for Taher (not in this PR): map 403 `no-tenant-context` to a clearer sentence in `FailureCause.js` (+tests). Also D-1 from the earlier review (order status `out of stock` whatever the cause).
