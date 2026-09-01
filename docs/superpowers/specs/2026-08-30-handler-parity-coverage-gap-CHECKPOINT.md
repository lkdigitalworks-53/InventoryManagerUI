# CHECKPOINT — handler-test parity for recordMutation/recordDelta/recordMutationsBatch

**Session date:** 2026-08-30
**Branch:** `test/handler-parity-coverage-gap` (off `main` @ `d1087b6`)
**Previous arc archived to:**
`docs/superpowers/specs/2026-08-29-functions-remaining-endpoint-handlers-CHECKPOINT.md`
(archived with a correction note — that file claimed its work was "not yet committed" but it had
in fact already merged as `d1087b6`/PR #55 by the time this session started; whoever merged it
didn't update the checkpoint. Flagged, not silently rewritten.)

## What this session is

Instructed to pick up the next actionable item from `docs/superpowers/E2E-TESTING-ROADMAP.md`.
Read the roadmap fresh (not trusted from prior-session memory, which turned out to be stale — the
multi-user-conflict E2E test that a prior arc's memory recorded as an open investigation is
actually resolved: QTBUG-49896 root-caused and fixed, confirmed on a real CI run, per the roadmap's
"Resolved this arc" section). Found the roadmap's three "Needs Taher's input" items are all
explicitly marked not scoped or estimated yet, deliberately — implementing any of those without
Taher's actual decision would be guessing at something the roadmap itself says isn't safe to guess
at. The one item that's genuinely actionable without his input: a flagged-but-not-fixed test
coverage asymmetry in `functions/test/index.handlers.test.js` (`recordDelta`/`recordMutationsBatch`
missing most of the 401/403/405/500 matrix `recordMutation` already had). Picked that up. Full
reasoning: `docs/superpowers/specs/2026-08-30-handler-parity-coverage-gap-design.md`.

**Process note**: this session's instructions explicitly waived the normal live-approval gate
between spec and implementation (single-prompt constraint, stated up front). Design doc was written
and acted on in the same pass, not across an approval round-trip — flagged explicitly in the design
doc itself rather than silently treated as equivalent to approval.

## Status: implementation complete, verified, committed, pushed

### Done
- [x] Fresh clone, branch created off `main` @ `d1087b6`
- [x] Read `docs/superpowers/E2E-TESTING-ROADMAP.md` end to end before picking an item — confirmed
      the only unblocked item, rejected guessing at the three Taher-gated ones
- [x] Read `functions/index.js`'s `recordMutation`/`recordDelta`/`recordMutationsBatch` handlers and
      the full existing `functions/test/index.handlers.test.js` end to end before writing anything,
      to confirm the roadmap's "cheap to close, no new mocking needed" claim rather than trust it
      blind — confirmed correct by inspection of `testSupport/handlerHarness.js`
- [x] Ran the baseline suite before touching anything: 163/163 passing
- [x] Design doc written: `docs/superpowers/specs/2026-08-30-handler-parity-coverage-gap-design.md`
      — problem table, root-cause explanation (authoring artifact, not a deliberate scope decision),
      exact list of the 11 cells being filled, explicit note on what's deliberately NOT being
      touched (the two pre-existing unreachable-code findings from Skill 52)
- [x] 11 new tests added to `functions/test/index.handlers.test.js`, mirroring `recordMutation`'s
      existing test bodies exactly in structure: `recordMutation` +1 (405), `recordDelta` +5 (401
      invalid-token, 403, 400, 405, 500), `recordMutationsBatch` +5 (401 missing-token, 401
      invalid-token, 403, 405, 500)
- [x] File header comment updated to describe the now-symmetric coverage instead of the old
      "these three share the shape" framing that didn't mention the asymmetry
- [x] Full `functions/` suite: **174 tests, 0 failures** (163 pre-existing + 11 new)
- [x] Coverage check (`node --test --experimental-test-coverage`): `index.js` line coverage 95.32%
      → 99.32%. The two lines still uncovered (`send()`'s `JSON.stringify`-failure catch,
      `canAssignRole`'s unreachable `else`) are the same two pre-existing findings from Skill 52 —
      re-confirmed unreachable, not newly discovered, deliberately not force-tested
- [x] Syntax check (`node -c`) on the touched file — clean
- [x] `SKILLS.md` — Skill 53 added
- [x] `AGENTS.md` — Testing & QA Agent handler-tests bullet updated to note the parity fix
- [x] `README.md` — dated update note under **Testing**
- [x] `docs/superpowers/E2E-TESTING-ROADMAP.md` — the flagged gap's entry updated with a pointer to
      the fix; a new "Resolved this arc" entry added
- [x] Stale prior-arc `CHECKPOINT.md` archived with an honest correction note (see above)

### Findings surfaced, not fixed (same discipline as the prior two arcs)

- Nothing new. The two remaining `index.js` coverage gaps (`send()`'s unreachable catch,
  `canAssignRole()`'s unreachable `else`) are the exact same findings Skill 52 already surfaced and
  flagged — re-confirmed still true and still out of this session's scope, not re-litigated.

### Explicitly not touched, and why

- The three "Needs Taher's input" roadmap items (silent batch-id-mint swallow, `orderMath.js`
  parity, account-switch-mid-sync) — all still waiting on his scoping decision, untouched.
- `review/post-pr45-qml-audit` (PR #49) — a different branch/PR Taher is handling directly per the
  roadmap's own coordination note; not inspected or touched, per this repo's standing rule against
  managing branches outside the one currently being worked on.
- No production code changed. This arc is test-file-only.

## Next action if resumed

Nothing pending — this arc's changes are committed and pushed to
`test/handler-parity-coverage-gap`. If resuming a future session: check whether Taher has scoped
any of the three "Needs Taher's input" roadmap items yet before picking a next item; if not,
re-read the roadmap fresh rather than trusting any prior session's memory of its contents (this
session found that memory stale once already).

---

## Addendum (same session, same branch): correcting an overstated sandbox limitation

After the work above was pushed, Taher pushed back on framing the item choice as gated by sandbox
execution limits, and asked for two standing conventions to be written down in the repo rather than
repeated each session. Writing them down surfaced that one of the limitations stated earlier in
this session ("sandbox can't run qmltestrunner") was an untested assumption, not a checked fact —
so this addendum corrects that in the same pass rather than leaving it wrong on `main`.

**Done:**
- [x] Checked instead of assumed: `apt-cache policy qt6-declarative-dev` → real 6.4.2 candidate
      exists via the already-allowlisted `archive.ubuntu.com`
- [x] Installed the full `qml6-module-*` set needed by this repo's actual test suite (several
      install-run-read-next-missing-module rounds — see SKILLS Skill 54 for the exact list)
- [x] Ran the real suite: **315 of 337 test files pass**, 22 fail at `compile()` with a known,
      pre-existing, Qt-version-drift cause (`AuthStore.qml`'s `import QtCore; Settings {...}` isn't
      valid QML until later than this sandbox's apt 6.4.2; CI runs 6.8) — same root cause Skill 47
      already documented in 2026-08-22, at a smaller 14-file count then (suite has grown since)
- [x] Checked instead of assumed, for Firebase too: `firebase-tools` installs via `npm` and
      `firebase emulators:start` runs past config/port-checking, failing specifically at the
      emulator jar download with `Host not in allowlist: storage.googleapis.com` — a precise,
      actionable finding, not the vague "Firebase doesn't work here" stated earlier this session
- [x] Fixed 2 pre-existing wrong "Skill 46" cross-references in `AGENTS.md` (both should have said
      Skill 47) — found while verifying the sandbox note they were attached to
- [x] Added `scripts/setup-sandbox-qmltestrunner.sh` — the discovered package list as a runnable,
      idempotent script, so a future session doesn't repeat the trial-and-error. **Caught and fixed
      a real bug in it before committing**: `apt-get update` exits non-zero because of this
      sandbox's pre-existing broken `deb.nodesource.com` entry (unrelated to Qt), which would have
      killed the script under `set -e` before it ever reached the install step — confirmed the bug
      by actually running the script (exit code 100), not by inspection alone; fixed with `|| true`
      on that one line, re-ran to confirm exit 0 and unchanged 315/22 test result
- [x] New `## Session & Sandbox Conventions` section added near the top of `AGENTS.md` with the two
      standing rules Taher asked for, plus the corroborating correction above
- [x] SKILLS.md Skill 54 written up

**Explicitly not done:** no change to `AuthStore.qml` or any other production QML — the 22-file
compile floor is a sandbox Qt-version artifact, not a code bug; "fixing" it in the real source would
mean downgrading working, CI-correct code to match this sandbox's older `apt` Qt, which would be
backwards.

