'use strict';

const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const PASSING_XML = `<testsuite name="s" tests="2" failures="0"><testcase name="a" classname="c"/><testcase name="b" classname="c"/></testsuite>`;
const FAILING_XML = `<testsuite name="s" tests="2" failures="1"><testcase name="a" classname="c"/><testcase name="b" classname="c"><failure message="boom"/></testcase></testsuite>`;

let tmpDir;
let originalFetch;
let originalEnv;
let calls;

function mockFetch(responses) {
  // responses: array of {match: RegExp, method: string, respond: (url) => {status, json}}
  return async (url, options = {}) => {
    const method = options.method || 'GET';
    calls.push({ method, url, body: options.body ? JSON.parse(options.body) : undefined });
    const handler = responses.find((r) => r.method === method && r.match.test(url));
    if (!handler) {
      throw new Error(`Unmocked fetch call: ${method} ${url}`);
    }
    const { status, json } = handler.respond(url);
    return {
      ok: status < 400,
      status,
      json: async () => json,
      text: async () => JSON.stringify(json),
    };
  };
}

beforeEach(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ci-comment-test-'));
  calls = [];
  originalFetch = global.fetch;
  originalEnv = { ...process.env };
  process.env.ARTIFACTS_ROOT = tmpDir;
  process.env.GITHUB_TOKEN = 'test-token';
  process.env.PR_NUMBER = '42';
  process.env.RUN_ID = '999';
  process.env.GITHUB_REPOSITORY = 'lkdigitalworks-53/InventoryManagerUI';
  process.env.GITHUB_SERVER_URL = 'https://github.com';
  process.env.GITHUB_API_URL = 'https://api.github.com';
  process.env.QML_TESTS_RESULT = 'success';
  process.env.FUNCTIONS_TESTS_RESULT = 'success';
  process.env.FIRESTORE_RULES_TESTS_RESULT = 'success';
  process.env.E2E_TESTS_RESULT = 'success';
  delete require.cache[require.resolve('../post-ci-comment')];
});

afterEach(() => {
  global.fetch = originalFetch;
  process.env = originalEnv;
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

function writeArtifact(dir, xml) {
  const full = path.join(tmpDir, dir);
  fs.mkdirSync(full, { recursive: true });
  fs.writeFileSync(path.join(full, 'results.xml'), xml);
}

test('happy path: all jobs pass, no existing comment -> creates a new comment with success body', async () => {
  for (const dir of ['qml-test-results', 'functions-test-results', 'firestore-rules-test-results', 'e2e-test-results']) {
    writeArtifact(dir, PASSING_XML);
  }
  global.fetch = mockFetch([
    { method: 'GET', match: /\/actions\/runs\/999\/jobs/, respond: () => ({ status: 200, json: { jobs: [] } }) },
    { method: 'GET', match: /\/issues\/42\/comments/, respond: () => ({ status: 200, json: [] }) },
    { method: 'POST', match: /\/issues\/42\/comments$/, respond: () => ({ status: 201, json: { id: 1 } }) },
  ]);

  const { main } = require('../post-ci-comment');
  await main();

  const postCall = calls.find((c) => c.method === 'POST');
  assert.ok(postCall, 'expected a POST to create the comment');
  assert.match(postCall.body.body, /All CI checks passed/);
  assert.match(postCall.body.body, /8\/8 tests passed/);
});

test('failure path: one job has a failing test -> comment includes the failing test name and reason', async () => {
  writeArtifact('qml-test-results', PASSING_XML);
  writeArtifact('functions-test-results', FAILING_XML);
  writeArtifact('firestore-rules-test-results', PASSING_XML);
  writeArtifact('e2e-test-results', PASSING_XML);
  process.env.FUNCTIONS_TESTS_RESULT = 'failure';

  global.fetch = mockFetch([
    {
      method: 'GET',
      match: /\/actions\/runs\/999\/jobs/,
      respond: () => ({
        status: 200,
        json: { jobs: [{ name: 'Functions Tests', html_url: 'https://github.com/x/y/actions/runs/999/job/5' }] },
      }),
    },
    { method: 'GET', match: /\/issues\/42\/comments/, respond: () => ({ status: 200, json: [] }) },
    { method: 'POST', match: /\/issues\/42\/comments$/, respond: () => ({ status: 201, json: { id: 1 } }) },
  ]);

  const { main } = require('../post-ci-comment');
  await main();

  const postCall = calls.find((c) => c.method === 'POST');
  assert.match(postCall.body.body, /CI checks failed/);
  assert.match(postCall.body.body, /c › b/); // classname › name from FAILING_XML
  assert.match(postCall.body.body, /boom/);
  assert.match(postCall.body.body, /job\/5/);
});

test('upsert behavior: an existing marker comment is updated (PATCH) instead of duplicated (POST)', async () => {
  for (const dir of ['qml-test-results', 'functions-test-results', 'firestore-rules-test-results', 'e2e-test-results']) {
    writeArtifact(dir, PASSING_XML);
  }
  global.fetch = mockFetch([
    { method: 'GET', match: /\/actions\/runs\/999\/jobs/, respond: () => ({ status: 200, json: { jobs: [] } }) },
    {
      method: 'GET',
      match: /\/issues\/42\/comments/,
      respond: () => ({ status: 200, json: [{ id: 777, body: '<!-- ci-status-comment:checks.yml -->\nold content' }] }),
    },
    { method: 'PATCH', match: /\/issues\/comments\/777/, respond: () => ({ status: 200, json: { id: 777 } }) },
  ]);

  const { main } = require('../post-ci-comment');
  await main();

  const patchCall = calls.find((c) => c.method === 'PATCH');
  const postCall = calls.find((c) => c.method === 'POST');
  assert.ok(patchCall, 'expected a PATCH to update the existing comment');
  assert.equal(postCall, undefined, 'should not also create a duplicate comment');
});

test('edge case: a job with no artifact file (crashed before producing results) does not throw and is reported distinctly', async () => {
  writeArtifact('qml-test-results', PASSING_XML);
  // functions-test-results, firestore-rules-test-results, e2e-test-results intentionally absent
  process.env.FUNCTIONS_TESTS_RESULT = 'failure';
  process.env.FIRESTORE_RULES_TESTS_RESULT = 'failure';
  process.env.E2E_TESTS_RESULT = 'failure';

  global.fetch = mockFetch([
    { method: 'GET', match: /\/actions\/runs\/999\/jobs/, respond: () => ({ status: 200, json: { jobs: [] } }) },
    { method: 'GET', match: /\/issues\/42\/comments/, respond: () => ({ status: 200, json: [] }) },
    { method: 'POST', match: /\/issues\/42\/comments$/, respond: () => ({ status: 201, json: { id: 1 } }) },
  ]);

  const { main } = require('../post-ci-comment');
  await assert.doesNotReject(main());

  const postCall = calls.find((c) => c.method === 'POST');
  assert.match(postCall.body.body, /produced no test results/);
  assert.match(postCall.body.body, /Functions Tests/);
});

test('edge case: missing required env vars aborts without making any network calls', async () => {
  delete process.env.PR_NUMBER;
  global.fetch = mockFetch([]);

  const { main } = require('../post-ci-comment');
  await main();
  process.exitCode = 0; // main() sets a non-zero exit code by design; reset so it doesn't leak into the test runner's own exit status

  assert.equal(calls.length, 0, 'should not call the GitHub API at all if required env vars are missing');
});

test('negative case: GitHub API failure (e.g. bad token) propagates as a rejected promise, not a silent success', async () => {
  writeArtifact('qml-test-results', PASSING_XML);
  global.fetch = mockFetch([
    { method: 'GET', match: /\/actions\/runs\/999\/jobs/, respond: () => ({ status: 401, json: { message: 'Bad credentials' } }) },
  ]);

  const { main } = require('../post-ci-comment');
  // Job-list fetch failure is non-fatal (logged, links omitted) by design -- but the comments
  // list call after it will also fail with no mock registered, which should surface.
  await assert.rejects(main());
});
