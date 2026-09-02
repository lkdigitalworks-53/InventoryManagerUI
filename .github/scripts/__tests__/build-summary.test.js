'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { buildCommentBody, COMMENT_MARKER } = require('../build-summary');

function job(overrides = {}) {
  return {
    display: 'QML Tests',
    jobResult: 'success',
    jobUrl: 'https://github.com/org/repo/actions/runs/1/job/1',
    parsed: { tests: 5, passed: 5, failed: 0, errors: 0, skipped: 0, failedTests: [] },
    ...overrides,
  };
}

test('happy path: all jobs green produces a success headline with aggregate counts', () => {
  const body = buildCommentBody({
    runUrl: 'https://github.com/org/repo/actions/runs/1',
    jobs: [
      job({ display: 'QML Tests', parsed: { tests: 10, passed: 10, failed: 0, errors: 0, skipped: 0, failedTests: [] } }),
      job({ display: 'Functions Tests', parsed: { tests: 4, passed: 4, failed: 0, errors: 0, skipped: 0, failedTests: [] } }),
    ],
  });
  assert.match(body, /All CI checks passed/);
  assert.match(body, /14\/14 tests passed/);
  assert.match(body, /✅/);
  assert.doesNotMatch(body, /Failed tests/);
});

test('includes the upsert marker so the workflow can find/update its own prior comment', () => {
  const body = buildCommentBody({ runUrl: 'https://x', jobs: [job()] });
  assert.ok(body.startsWith(COMMENT_MARKER));
});

test('failure path: lists failing test name, classname, and reason with a logs link', () => {
  const body = buildCommentBody({
    runUrl: 'https://github.com/org/repo/actions/runs/1',
    jobs: [
      job({
        display: 'Functions Tests',
        jobResult: 'failure',
        jobUrl: 'https://github.com/org/repo/actions/runs/1/job/2',
        parsed: {
          tests: 3,
          passed: 2,
          failed: 1,
          errors: 0,
          skipped: 0,
          failedTests: [{ name: 'lineTax rounds correctly', classname: 'orderMath.test.js', message: 'Expected 10 but got 11' }],
        },
      }),
    ],
  });
  assert.match(body, /CI checks failed/);
  assert.match(body, /orderMath\.test\.js › lineTax rounds correctly/);
  assert.match(body, /Expected 10 but got 11/);
  assert.match(body, /\[logs\]\(https:\/\/github\.com\/org\/repo\/actions\/runs\/1\/job\/2\)/);
});

test('overall status is failure if any single job has failures, even if others are fully green', () => {
  const body = buildCommentBody({
    runUrl: 'https://x',
    jobs: [
      job({ display: 'QML Tests' }), // all green
      job({
        display: 'E2E Tests',
        jobResult: 'failure',
        parsed: { tests: 1, passed: 0, failed: 1, errors: 0, skipped: 0, failedTests: [{ name: 'a', classname: 'b', message: 'm' }] },
      }),
    ],
  });
  assert.match(body, /CI checks failed/);
});

test('edge case: job with no parsed results (crashed before producing XML) is called out distinctly, not silently dropped', () => {
  const body = buildCommentBody({
    runUrl: 'https://x',
    jobs: [job({ display: 'Firestore Rules Tests', jobResult: 'failure', jobUrl: null, parsed: null })],
  });
  assert.match(body, /produced no test results/);
  assert.match(body, /Firestore Rules Tests/);
  assert.match(body, /`failure`/);
});

test('edge case: skipped job (e.g. workflow_dispatch subset run) is not treated as a failure or an anomaly', () => {
  const body = buildCommentBody({
    runUrl: 'https://x',
    jobs: [job({ display: 'A' }), job({ display: 'B', jobResult: 'skipped', parsed: null })],
  });
  assert.match(body, /All CI checks passed/);
  assert.doesNotMatch(body, /produced no test results/);
});

test('edge case: cancelled job surfaces as a distinct non-success, non-failure state', () => {
  const body = buildCommentBody({
    runUrl: 'https://x',
    jobs: [job({ display: 'A', jobResult: 'cancelled', parsed: null })],
  });
  assert.match(body, /did not complete cleanly/);
});

test('edge case: skipped test counts are surfaced in the headline without being counted as failures', () => {
  const body = buildCommentBody({
    runUrl: 'https://x',
    jobs: [job({ parsed: { tests: 6, passed: 5, failed: 0, errors: 0, skipped: 1, failedTests: [] } })],
  });
  assert.match(body, /All CI checks passed/);
  assert.match(body, /1 skipped/);
});

test('edge case: multiple failing jobs each get their own section, not merged together', () => {
  const body = buildCommentBody({
    runUrl: 'https://x',
    jobs: [
      job({
        display: 'QML Tests',
        jobResult: 'failure',
        parsed: { tests: 1, passed: 0, failed: 1, errors: 0, skipped: 0, failedTests: [{ name: 'qa', classname: 'QA.qml', message: 'boom' }] },
      }),
      job({
        display: 'Functions Tests',
        jobResult: 'failure',
        parsed: { tests: 1, passed: 0, failed: 1, errors: 0, skipped: 0, failedTests: [{ name: 'fa', classname: 'fa.test.js', message: 'bang' }] },
      }),
    ],
  });
  assert.match(body, /\*\*QML Tests\*\*/);
  assert.match(body, /\*\*Functions Tests\*\*/);
  assert.match(body, /qa/);
  assert.match(body, /fa/);
});

test('edge case: missing job URL falls back to an explicit unavailable marker instead of a broken link', () => {
  const body = buildCommentBody({ runUrl: 'https://x', jobs: [job({ jobUrl: null })] });
  assert.match(body, /_\(unavailable\)_/);
});

test('always includes a link to the full CI run regardless of outcome', () => {
  const body = buildCommentBody({ runUrl: 'https://github.com/org/repo/actions/runs/42', jobs: [job()] });
  assert.match(body, /\[View full CI run\]\(https:\/\/github\.com\/org\/repo\/actions\/runs\/42\)/);
});

test('regression: errors (as distinct from failures) are folded into the failed count in headline math', () => {
  const body = buildCommentBody({
    runUrl: 'https://x',
    jobs: [job({ jobResult: 'failure', parsed: { tests: 2, passed: 1, failed: 0, errors: 1, skipped: 0, failedTests: [{ name: 'e', classname: 'c', message: 'threw' }] } })],
  });
  assert.match(body, /1 of 2 tests failed/);
});
