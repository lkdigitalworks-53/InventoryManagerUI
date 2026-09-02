'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { resolveJobUrl } = require('../resolve-job-url');

const sampleResponse = {
  jobs: [
    { name: 'QML Tests', html_url: 'https://github.com/org/repo/actions/runs/1/job/10' },
    { name: 'Functions Tests', html_url: 'https://github.com/org/repo/actions/runs/1/job/11' },
  ],
};

test('happy path: finds the matching job by exact name', () => {
  assert.equal(resolveJobUrl(sampleResponse, 'QML Tests'), 'https://github.com/org/repo/actions/runs/1/job/10');
});

test('negative case: unknown job name returns null instead of throwing', () => {
  assert.equal(resolveJobUrl(sampleResponse, 'Nonexistent Job'), null);
});

test('edge case: empty jobs array returns null', () => {
  assert.equal(resolveJobUrl({ jobs: [] }, 'QML Tests'), null);
});

test('edge case: malformed/missing response shape returns null, does not throw', () => {
  assert.equal(resolveJobUrl(null, 'QML Tests'), null);
  assert.equal(resolveJobUrl(undefined, 'QML Tests'), null);
  assert.equal(resolveJobUrl({}, 'QML Tests'), null);
  assert.equal(resolveJobUrl({ jobs: null }, 'QML Tests'), null);
});

test('edge case: job name matching is exact/case-sensitive (matrix-suffixed names must be passed exactly)', () => {
  assert.equal(resolveJobUrl(sampleResponse, 'qml tests'), null);
});
