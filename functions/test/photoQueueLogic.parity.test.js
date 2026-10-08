const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  classifyError, nextBackoffMs, reduceQueueItem, breakerReducer, isBreakerOpen, breakerWaitMs, shouldDiscardOnFailure, productPresence,
} = require('./testSupport/photoQueueLogicParity');

test('classifyError: terminal codes', () => {
  for (const s of [400, 413, 404, 409, 403]) assert.equal(classifyError(s), 'terminal'); // 403 = PH4 item 1 (C01/C02)
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

// ---- PH4 item 1: 403 terminal (C04) ----
test('PH4 C04: reduceQueueItem failed 403 -> failed on attempt 1, no backoff scheduled', () => {
  const r = reduceQueueItem({ ...base, state: 'uploading', attempts: 0 }, { type: 'failed', status: 403 });
  assert.equal(r.state, 'failed');
  assert.equal(r.lastError, 403);
  assert.equal(r.attempts, 1);
  assert.equal(r.nextAttemptAt, 0, 'terminal must not schedule a retry');
});
test('PH4 C03 regression: 401/429/500/502/503/0 stay transient next to the new 403', () => {
  for (const s of [401, 429, 500, 502, 503, 0]) assert.equal(classifyError(s), 'transient');
  assert.equal(classifyError('403'), 'terminal', 'object-key lookup: a numeric string 403 is the same key');
});

// ---- PH4 item 4: L1 breakerWaitMs (C22/C23, pure part) ----
test('PH4 L1: breakerWaitMs = time left on an open breaker', () => {
  const open = { status: 'open', consecutiveFailures: 5, cooldownUntil: 61000, cooldownMs: 60000 };
  assert.equal(breakerWaitMs(open, 1000), 60000);
  assert.equal(breakerWaitMs(open, 60999), 1);
});
test('PH4 L1: breakerWaitMs is 0 when closed, expired, exactly at cooldownUntil, or the state is empty-ish', () => {
  assert.equal(breakerWaitMs({ status: 'closed', cooldownUntil: 99999 }, 1000), 0);
  const open = { status: 'open', cooldownUntil: 5000 };
  assert.equal(breakerWaitMs(open, 5000), 0, 'at the boundary the breaker is closed (t < cooldownUntil is false)');
  assert.equal(breakerWaitMs(open, 9000), 0, 'never negative');
  assert.equal(breakerWaitMs({}, 1000), 0);
});
test('PH4 L1: with no explicit now it uses the clock', () => {
  const open = { status: 'open', cooldownUntil: Date.now() + 100000 };
  const w = breakerWaitMs(open);
  assert.ok(w > 99000 && w <= 100000, String(w));
});
// ---- PH4 follow-up: discard a queued photo on 404 only when the product row is gone locally too ----
test('PH4 D1: 404 and product row gone locally -> discard', () => {
  assert.equal(shouldDiscardOnFailure(404, false), true);
});
test('PH4 D2: 404 but the product row exists locally (first photo, create not visible yet) -> keep the terminal 404 (failed + Retry/Discard)', () => {
  assert.equal(shouldDiscardOnFailure(404, true), false);
  assert.equal(classifyError(404), 'terminal');
});
test('PH4 D3: an unknown answer (undefined/null/0/"") never discards', () => {
  for (const v of [undefined, null, 0, '', NaN]) assert.equal(shouldDiscardOnFailure(404, v), false);
});
test('PH4 D4: only 404 discards: every other status with the row gone is left to the normal reducer', () => {
  for (const st of [0, 400, 401, 403, 409, 413, 429, 500, 503, '404']) assert.equal(shouldDiscardOnFailure(st, false), false, String(st));
});
test('PH4 D5 MONKEY: 5 seeds x 200 random (status, exists) pairs match the one-line truth table', () => {
  for (let seed = 1; seed <= 5; seed++) {
    let st = seed * 15485863;
    const rnd = (n) => { st = (st * 1103515245 + 12345) & 0x7fffffff; return st % n; };
    const statuses = [0, 200, 400, 401, 403, 404, 404, 409, 413, 429, 500, 503];
    const exists = [true, false, undefined, null];
    for (let i = 0; i < 200; i++) {
      const status = statuses[rnd(statuses.length)];
      const e = exists[rnd(exists.length)];
      assert.equal(shouldDiscardOnFailure(status, e), status === 404 && e === false);
    }
  }
});

// ---- PH4 follow-up 2 (Taher 2026-10-07): "row gone" may only be answered from the FULL product list ----
test('PH4 P1: row found -> true, whether or not the list is complete', () => {
  assert.equal(productPresence(true, true), true);
  assert.equal(productPresence(true, false), true);
  assert.equal(productPresence(true, undefined), true);
});
test('PH4 P2: row not found AND list complete -> false (the only case that may discard)', () => {
  assert.equal(productPresence(false, true), false);
});
test('PH4 P3: row not found in a PARTIAL list (first page of 50, failed page, reset in flight) -> undefined, never false', () => {
  assert.equal(productPresence(false, false), undefined);
  assert.equal(productPresence(false, undefined), undefined);
  assert.equal(productPresence(false, null), undefined);
});
test('PH4 P4: garbage never yields false (strict === true on both args)', () => {
  for (const f of [undefined, null, 0, 1, '', 'x', NaN]) for (const c of [1, 'true', {}, [], 0, '']) {
    assert.notEqual(productPresence(f, c), false, `${String(f)}/${String(c)}`);
  }
  assert.equal(productPresence('true', true), false); // not === true -> treated as not found, list complete
});
test('PH4 P5 END-TO-END RULE: a 404 for a product sitting on page 3 of 3 is NOT discarded while only page 1 is loaded', () => {
  const PAGE = 50, all = Array.from({ length: 130 }, (_, i) => 'SKU-' + i);
  const target = 'SKU-120'; // lives on page 3
  const decide = (loadedPages, hasMore) => {
    const loaded = all.slice(0, loadedPages * PAGE);
    return shouldDiscardOnFailure(404, productPresence(loaded.includes(target), !hasMore));
  };
  assert.equal(decide(1, true), false);  // only page 1 loaded: the old behaviour discarded here (the bug)
  assert.equal(decide(2, true), false);
  assert.equal(decide(3, false), false); // fully loaded and the row IS there -> keep terminal 404
  const gone = (loadedPages, hasMore) => shouldDiscardOnFailure(404, productPresence(all.slice(0, loadedPages * PAGE).includes('SKU-999'), !hasMore));
  assert.equal(gone(1, true), false);    // absent but list partial -> unknown -> keep
  assert.equal(gone(3, false), true);    // absent and list complete -> discard
});
test('PH4 P6 MONKEY: 5 seeds x 300 random (found, complete) pairs match the truth table', () => {
  for (let seed = 1; seed <= 5; seed++) {
    let st = seed * 32452843;
    const rnd = (n) => { st = (st * 1103515245 + 12345) & 0x7fffffff; return st % n; };
    const vals = [true, false, undefined, null, 0, 1, '', 'x'];
    for (let i = 0; i < 300; i++) {
      const f = vals[rnd(vals.length)], c = vals[rnd(vals.length)];
      const want = f === true ? true : (c === true ? false : undefined);
      assert.equal(productPresence(f, c), want);
    }
  }
});
