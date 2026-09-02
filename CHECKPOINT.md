# CHECKPOINT — PR CI status comment implemented and pushed

**Session date:** 2026-09-02
**Branch:** `feature/pr-ci-status-comment` (off `main`)
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-01-ordermath-linetax-refund-coverage-CHECKPOINT.md`
(unrelated prior arc — item 1/2/3 roadmap triage, still gated on Taher's input, untouched this
session).

## What this session is

Two parts. First, Taher asked to investigate test-coverage reporting (unit/PR-diff/overall) across
the three test suites — researched, **not implemented**, findings and recommendation given, Taher
said "leave it for now." Second, a new ask: post CI results as a PR comment (success summary, or
failing-test names + reasons on failure, with a link to the CI job logs). This session implements
the second one.

## Coverage-reporting research (not implemented, for context if revisited)

- Node functions & Firestore rules: mature free tooling exists (`node --test
  --experimental-test-coverage`, Firestore emulator's native `ruleCoverage` endpoint). Near-zero CI
  time cost.
- QML/JS: no mature free tool for Qt6. Coco is commercial; `qoverage` is pre-alpha. Recommended
  **not** gating CI on a pre-alpha tool's numbers — flagged as worse than no number, since it'd get
  treated as ground truth in merge decisions.
- Decision needed from Taher before any of this proceeds: Codecov account signup (free for public
  repos, needs a token), whether QML gets a numeric gate at all (recommended: no, keep the existing
  manual test-plan matrix), and whether patch-coverage failures should hard-block merge or just
  comment. **Not decided yet — parked, no code written for this part.**

## PR CI status comment — implemented, tested, pushed this session

New `pr-comment` job appended to `.github/workflows/checks.yml`, `needs: [qml-tests,
functions-tests, firestore-rules-tests, e2e-tests]`, `if: always() && github.event_name ==
'pull_request'`. Downloads each job's existing JUnit XML artifact, runs the comment script's own
unit tests as a CI step (fail loudly, don't post a garbled comment), then posts/updates a single PR
comment via the built-in `GITHUB_TOKEN` (not Taher's PAT — scoped `permissions: pull-requests:
write, actions: read` at job level, works on forked PRs too).

**New files, all in `.github/scripts/`:**
- `parse-junit.js` — dependency-free JUnit XML parser, scoped to the two generators this repo
  actually uses (`qmltestrunner` and `node --test --test-reporter=junit`).
- `resolve-job-url.js` — matches a job's display name to its `html_url` from the GitHub "list jobs"
  API response, so every row/failure links straight to that job's logs.
- `build-summary.js` — pure function building the comment markdown; no network/filesystem calls, so
  format changes are testable without mocking anything.
- `post-ci-comment.js` — thin I/O orchestration: reads artifact files, calls the GitHub API,
  upserts the comment via a marker comment (`<!-- ci-status-comment:checks.yml -->`) so re-pushes
  update one comment instead of duplicating.

**Tests:** `.github/scripts/__tests__/` — 39 cases total, all genuinely run locally
(`node --test "./.github/scripts/__tests__/*.test.js"` → 39/39 pass), pure Node so no
Qt/Firebase toolchain needed. Caught one real bug during the TDD loop: `name="..."` attribute regex
had no word boundary and matched inside `classname="..."`, returning the classname as the test
name — fixed with `\b`.

**Docs updated:** `SKILLS.md` Skill 56 (full narrative, the caught bug, design decisions),
`AGENTS.md` feature table, `README.md` Testing section, and a full test plan at
`docs/superpowers/test-plans/2026-09-02-pr-ci-status-comment-test-plan.md` (UT / functional /
regression / E2E-N/A / on-device-N/A, per the standard format — this change has no on-device or E2E
surface since it's CI-only, noted explicitly rather than silently omitted).

## What still needs Taher

- **First real PR run is the actual proof.** Unit/functional tests prove the parsing and
  comment-building logic is correct in isolation; only a real GitHub Actions run proves the
  artifact-download → job-list API → comment-post wiring end to end. Watch the first PR this
  branch opens (or the next PR after merge) for: (a) does the comment appear at all, (b) do the
  per-job log links actually resolve, (c) does a second push to the same PR update the comment
  rather than duplicate it.
- Coverage-reporting decision from the first half of this session — still open, no urgency stated.

## How to resume if interrupted

Branch `feature/pr-ci-status-comment` is pushed with all changes above. If picking this back up:
check whether Taher already opened a PR from it and reviewed the live comment behavior — if so,
follow up on whatever the real run surfaced (link resolution, formatting, anything the mocks didn't
catch). If not, the branch is ready to open a PR from as-is.
