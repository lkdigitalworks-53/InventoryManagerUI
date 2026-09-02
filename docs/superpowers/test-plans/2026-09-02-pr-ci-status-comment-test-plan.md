# Test plan — PR CI status comment

**Branch:** `feature/pr-ci-status-comment` off `main`.
**Covers:** new `pr-comment` job in `.github/workflows/checks.yml` plus its four supporting
scripts under `.github/scripts/`: `parse-junit.js`, `resolve-job-url.js`, `build-summary.js`,
`post-ci-comment.js`.

**What it does:** after `qml-tests`, `functions-tests`, `firestore-rules-tests`, and `e2e-tests`
finish (success or failure, `if: always()`), a new job downloads each job's JUnit XML artifact,
aggregates pass/fail counts, and posts (or updates, on re-push) a single PR comment: a success
summary with counts on green, or a per-job failing-test breakdown with reasons on red. Every job
row and every failing job links directly to that job's log page.

**Not covered by this plan / out of scope:** the QML/Firestore/Functions test *content* itself —
this only reports on existing test results, it doesn't add or change what's tested in the app.
No QML, C++, or app-behavior code was touched.

---

## 1. Unit test coverage

Pure-logic correctness of the three testable modules, no network/filesystem I/O involved. All run
via `node --test`, no emulator or Qt toolchain needed — genuinely run in this session
(`node --test .github/scripts/__tests__/*.test.js` → 39/39 passing, see "How this was
verified"). 16 cases in `parse-junit.js`, 12 in `build-summary.js`, 5 in `resolve-job-url.js`.

| File | What's covered |
|---|---|
| `parse-junit.test.js` | Happy path (all-pass suite); failure extraction from both `message=` attribute and element-body text; `<error>` counted separately from `<failure>` but both surface as failures; `<skipped>` counted but not treated as a failure; multiple `<testsuite>` blocks in one file aggregated; empty/whitespace/null/undefined input doesn't throw; zero-testcase suite; self-closing passing testcase; XML entity decoding in failure messages; long/multi-line failure messages truncated to first line, capped at 300 chars; missing `classname`/`name` attributes don't throw and fall back sensibly. |
| `build-summary.test.js` | Success headline with correct aggregate `passed/tests` math across jobs; upsert marker always present at the start of the body; failing test rendered as `classname › name — message` with a working logs link; overall status is `failure` if *any* job has failures even when others are green; a job with no parsed results (crashed pre-test) is called out in its own "no results" section rather than silently dropped; a genuinely `skipped` job is *not* treated as an anomaly; `cancelled` jobs get a distinct "did not complete cleanly" status; skipped *test* counts surface in the headline without counting as failures; multiple failing jobs get separate sections, not merged; missing job URL renders `_(unavailable)_` instead of a broken link; the full-run link is always present; errors fold into the same failed-count math as failures. |
| `resolve-job-url.test.js` | Exact-name match against the GitHub "list jobs" API shape; unknown job name → `null`, not a throw; empty jobs array; malformed/missing response shape (`null`, `undefined`, `{}`, `{jobs: null}`) all return `null` safely; name matching is case-sensitive by design (documents the assumption rather than silently being lenient). |

## 2. Functional test coverage

`post-ci-comment.test.js` — the I/O orchestration layer, with `global.fetch` mocked (no real
GitHub API calls) and a temp directory standing in for the downloaded-artifacts folder. 6 cases,
genuinely run this session.

| Test | What it locks down |
|---|---|
| Happy path: all 4 jobs pass, no prior comment | Issues a `POST` (not `PATCH`) with a success body and correct `8/8 tests passed` aggregate math. |
| Failure path: one job has one failing test | Comment body contains the exact `classname › name — message` line and the correct per-job logs URL resolved from the mocked jobs-list API. |
| Upsert behavior | When a comment with the marker already exists, issues `PATCH` to that comment's ID and does **not** also `POST` a duplicate — this is what makes repeated pushes to the same PR update one comment instead of spamming new ones. |
| Missing-artifact edge case | 3 of 4 jobs have no `results.xml` on disk (simulates a job that crashed before its own upload step ran) — script doesn't throw, and those jobs are listed under "produced no test results" by name. |
| Missing required env vars | Aborts with zero network calls — guards against posting a garbled/incomplete comment if the workflow is misconfigured. |
| GitHub API failure (401) | Propagates as a rejected promise rather than swallowing the error and reporting false success. |

## 3. Regression test coverage

None yet — this is new functionality, not a bugfix. One regression case was caught and fixed
*during* this session's TDD loop, worth recording because it would otherwise resurface silently:

| Test | What it locks down |
|---|---|
| `parse-junit.test.js` → "unnamed testcase falls back to placeholder name" | Caught a real bug: the original `name="..."` attribute regex had no word boundary, so it matched the tail of `classname="..."` first and returned the classname's value as the test name. Fixed with a `\b` boundary. Left in the suite as a regression guard. |

## 4. E2E test coverage

Not applicable — there is no Firestore/Auth/Functions integration surface here; the script only
reads local XML files and calls the GitHub REST API (mocked in tests, real in CI). The genuine
end-to-end proof is the first real PR this branch runs on: the job either produces a correct
comment against real CI results or it doesn't, and that will be visible directly on that PR.

## 5. On-device test plan

**N/A for this change.** Nothing here touches `qml/`, `main.cpp`, or any Felgo/Qt runtime code —
it's exclusively a GitHub Actions workflow + Node scripts that run in CI, never on a device or in
the app binary. Recording this explicitly rather than silently omitting the section, per the
standing test-plan format.

## 6. Known limitations / things to watch on the first real run

- **Job-list API race:** the `pr-comment` job calls `GET .../actions/runs/{run_id}/jobs` to resolve
  per-job log URLs. If GitHub hasn't fully registered all four job records by the time this runs
  (unlikely, since `needs:` already waited for them, but not impossible), a job's link could come
  back `null` and render as `_(unavailable)_` rather than a broken link — degrades gracefully,
  doesn't crash the job.
- **Comment permissions:** uses the built-in `GITHUB_TOKEN` (scoped to this job only via
  `permissions: pull-requests: write, actions: read`), not Taher's PAT — deliberate, least-privilege,
  and means this works on forked-PR contributions too (a PAT wouldn't, and shouldn't, be exposed to
  fork CI runs).
- **First run on this PR will exercise the real path end-to-end** — that's the actual proof; this
  plan's automated tests prove the logic is correct, CI proves the wiring is correct.

## How this was verified

```
$ node --test .github/scripts/__tests__/*.test.js
# tests 39
# pass 39
# fail 0
```

Run directly in the sandbox — pure Node, no Qt/Firebase toolchain required, so this one is a
genuine local result, not a "pushed and waiting on CI" claim. The workflow YAML itself was
validated with `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/checks.yml'))"`
(syntax-valid, correct job graph) but the actual GitHub Actions execution — artifact download
across jobs, real API calls, real comment rendering — can only be confirmed by CI on the pushed
branch/PR.
