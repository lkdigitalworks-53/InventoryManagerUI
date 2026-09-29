const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  classifyError, nextBackoffMs, reduceQueueItem, breakerReducer, isBreakerOpen,
} = require('./testSupport/photoQueueLogicParity');

test('classifyError: terminal codes', () => {
  for (const s of [400, 413, 404, 409]) assert.equal(classifyError(s), 'terminal');
});
test('classifyError: transient codes', () => {
  for (const s of [401, 429, 500, 502, 503, 0]) assert.equal(classifyError(s), 'transient');
});
test('classifyError: unknown status defaults to transient (never lose a photo to an unmapped code)', () => {
  assert.equal(classifyError(599), 'transient');
});

test('nextBackoffMs matches OutboxStore schedule exactly, capped', () => {
  assert.deepEqual([1, 2, 3, 4, 5, 6].map(nextBackoffMs), [2000, 8000, 30000, 120000, 600000, 600000]);
});

const base = { photoId: 'p1', state: 'enqueued', attempts: 0, nextAttemptAt: 0, lastError: null };

test('reduceQueueItem: sent -> removed (null)', () => {
  assert.equal(reduceQueueItem({ ...base, state: 'uploading' }, { type: 'sent' }), null);
});
test('reduceQueueItem: transient failure under attempt cap -> retrying with backoff', () => {
  const r = reduceQueueItem({ ...base, state: 'uploading', attempts: 0 }, { type: 'failed', status: 500 });
  assert.equal(r.state, 'retrying');
  assert.equal(r.attempts, 1);
  assert.equal(r.nextAttemptAt > 0, true);
});
test('reduceQueueItem: terminal failure -> failed regardless of attempt count', () => {
  const r = reduceQueueItem({ ...base, state: 'uploading', attempts: 0 }, { type: 'failed', status: 400 });
  assert.equal(r.state, 'failed');
  assert.equal(r.lastError, 400);
});
test('reduceQueueItem: 8th transient failure while online -> failed (attempt cap)', () => {
  const r = reduceQueueItem({ ...base, state: 'uploading', attempts: 7 }, { type: 'failed', status: 500 });
  assert.equal(r.state, 'failed');
  assert.equal(r.attempts, 8);
});
test('reduceQueueItem: 7th transient failure while online -> still retrying (below the cap)', () => {
  const r = reduceQueueItem({ ...base, state: 'uploading', attempts: 6 }, { type: 'failed', status: 500 });
  assert.equal(r.state, 'retrying');
  assert.equal(r.attempts, 7);
});
test('reduceQueueItem: retry resets attempts and reopens the item', () => {
  const r = reduceQueueItem({ ...base, state: 'failed', attempts: 8, lastError: 400 }, { type: 'retry' });
  assert.equal(r.state, 'enqueued');
  assert.equal(r.attempts, 0);
  assert.equal(r.nextAttemptAt, 0);
  assert.equal(r.lastError, null);
});
test('reduceQueueItem: discard -> removed (null) from any state', () => {
  for (const state of ['enqueued', 'uploading', 'retrying', 'failed']) {
    assert.equal(reduceQueueItem({ ...base, state }, { type: 'discard' }), null);
  }
});
test('reduceQueueItem: a failed event against an item that is not currently uploading is ignored', () => {
  const failedItem = { ...base, state: 'failed', attempts: 8, lastError: 400 };
  const r = reduceQueueItem(failedItem, { type: 'failed', status: 500 });
  assert.deepEqual(r, failedItem);
  assert.equal(r.attempts, 8, 'must not exceed the attempt cap via a stale/duplicate failure report');
});
test('reduceQueueItem: unrecognised event type is a no-op (returns the item unchanged)', () => {
  const item = { ...base, state: 'uploading' };
  const r = reduceQueueItem(item, { type: 'bogus' });
  assert.deepEqual(r, item);
});

test('breaker: opens after 5 consecutive failures, not before', () => {
  let s = { status: 'closed', consecutiveFailures: 0, cooldownUntil: 0, cooldownMs: 60000 };
  for (let i = 0; i < 4; i++) s = breakerReducer(s, { type: 'failure' });
  assert.equal(s.status, 'closed');
  s = breakerReducer(s, { type: 'failure' });
  assert.equal(s.status, 'open');
});
test('breaker: a success resets consecutiveFailures and closes it', () => {
  let s = { status: 'open', consecutiveFailures: 5, cooldownUntil: 1e15, cooldownMs: 60000 };
  s = breakerReducer(s, { type: 'success' });
  assert.equal(s.status, 'closed');
  assert.equal(s.consecutiveFailures, 0);
});
test('breaker: first trip cooldown is the 60s base', () => {
  let s = { status: 'closed', consecutiveFailures: 0, cooldownUntil: 0, cooldownMs: 60000 };
  for (let i = 0; i < 5; i++) s = breakerReducer(s, { type: 'failure' });
  assert.equal(s.cooldownMs, 60000);
});
test('breaker: cooldown doubles on a second trip without an intervening success, capped at 10 minutes', () => {
  let s = { status: 'closed', consecutiveFailures: 0, cooldownUntil: 0, cooldownMs: 60000 };
  for (let i = 0; i < 5; i++) s = breakerReducer(s, { type: 'failure' });
  assert.equal(s.cooldownMs, 60000);
  // The cooldown window elapsed and the breaker went back to allowing attempts (closed), but it
  // never saw a genuine 'success' -- the next probe failed again too.
  s = { ...s, status: 'closed', consecutiveFailures: 0 };
  for (let i = 0; i < 5; i++) s = breakerReducer(s, { type: 'failure' });
  assert.equal(s.cooldownMs, 120000);

  s = { ...s, status: 'closed', consecutiveFailures: 0 };
  for (let i = 0; i < 5; i++) s = breakerReducer(s, { type: 'failure' });
  assert.equal(s.cooldownMs, 240000);
});
test('breaker: a genuine success in between resets escalation back to the 60s base on the next trip', () => {
  let s = { status: 'closed', consecutiveFailures: 0, cooldownUntil: 0, cooldownMs: 60000 };
  for (let i = 0; i < 5; i++) s = breakerReducer(s, { type: 'failure' });
  assert.equal(s.cooldownMs, 60000);
  s = breakerReducer(s, { type: 'success' });
  for (let i = 0; i < 5; i++) s = breakerReducer(s, { type: 'failure' });
  assert.equal(s.cooldownMs, 60000);
});
test('breaker: escalation caps at 10 minutes and does not exceed it', () => {
  let s = { status: 'closed', consecutiveFailures: 0, cooldownUntil: 0, cooldownMs: 60000 };
  for (let trip = 0; trip < 10; trip++) {
    s = { ...s, status: 'closed', consecutiveFailures: 0 };
    for (let i = 0; i < 5; i++) s = breakerReducer(s, { type: 'failure' });
  }
  assert.equal(s.cooldownMs, 600000);
});
test('isBreakerOpen: true while now < cooldownUntil, false after', () => {
  const s = { status: 'open', consecutiveFailures: 5, cooldownUntil: 1000, cooldownMs: 60000 };
  assert.equal(isBreakerOpen(s, 500), true);
  assert.equal(isBreakerOpen(s, 1500), false);
});
test('isBreakerOpen: always false when the breaker is not open, regardless of cooldownUntil', () => {
  const s = { status: 'closed', consecutiveFailures: 0, cooldownUntil: 1e15, cooldownMs: 60000 };
  assert.equal(isBreakerOpen(s, 0), false);
});

// Monkey test: a long random sequence of events must never leave the reducer in an invalid state
// (attempts never negative, state always one of the four, terminal never auto-retried).
test('monkey: 500 random event sequences never produce an invalid queue item', () => {
  const events = [
    { type: 'failed', status: 500 }, { type: 'failed', status: 400 },
    { type: 'failed', status: 401 }, { type: 'retry' },
  ];
  for (let run = 0; run < 500; run++) {
    let item = { ...base };
    for (let step = 0; step < 20; step++) {
      const ev = events[Math.floor(Math.random() * events.length)];
      // Simulate the real PhotoQueue drain loop: an 'enqueued' or 'retrying' item that comes up
      // for a turn is attempted (moves to 'uploading') before any outcome event is fed to it.
      const inFlight = item.state === 'enqueued' || item.state === 'retrying';
      const current = { ...item, state: inFlight ? 'uploading' : item.state };
      const next = reduceQueueItem(current, ev);
      if (next === null) break;
      assert.ok(['enqueued', 'uploading', 'retrying', 'failed'].includes(next.state));
      assert.ok(next.attempts >= 0);
      assert.ok(next.attempts <= 8);
      item = next;
    }
  }
});

// Monkey test: the breaker's cooldown never exceeds the cap and consecutiveFailures never goes negative,
// across random interleavings of success/failure.
test('monkey: 500 random breaker sequences stay within invariants', () => {
  for (let run = 0; run < 500; run++) {
    let s = { status: 'closed', consecutiveFailures: 0, cooldownUntil: 0, cooldownMs: 60000 };
    for (let step = 0; step < 30; step++) {
      const ev = Math.random() < 0.5 ? { type: 'success' } : { type: 'failure' };
      s = breakerReducer(s, ev);
      assert.ok(s.consecutiveFailures >= 0);
      assert.ok(s.cooldownMs <= 600000);
      assert.ok(['open', 'closed'].includes(s.status));
    }
  }
});
