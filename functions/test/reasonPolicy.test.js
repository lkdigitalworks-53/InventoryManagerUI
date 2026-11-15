'use strict';

// P1 S2e-1: (1) which movement kinds need a reason, (2) the SERVER stamps the cost value of the six
// non-supply outward kinds from the product's cost, never from the client. One battery of checks that
// COLLECTS failures, run on the real file and on every hand mutant (mutants must be noticed).
// Design: docs/superpowers/specs/2026-11-13-p1-s2e1-reason-policy-and-cost-design.md
// Test plan: docs/superpowers/test-plans/2026-11-13-p1-s2e1-reason-policy-and-cost-test-plan.md
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ML = require('../lib/movementLogic');

const SRC_PATH = path.join(__dirname, '..', 'lib', 'movementLogic.js');
const SRC = fs.readFileSync(SRC_PATH, 'utf8');
const HELPER = fs.readFileSync(path.join(__dirname, '..', '..', 'qml', 'helper', 'StockMovements.js'), 'utf8');
const plain = (v) => JSON.parse(JSON.stringify(v));
const show = (v) => String(JSON.stringify(v));

function loadLogic(src) {
  const m = { exports: {} };
  new Function('module', 'exports', 'require', src)(m, m.exports, require);
  return m.exports;
}
function loadHelper(src) {
  const ctx = {};
  vm.runInNewContext(src.replace(/^\.pragma library\s*$/m, '') + '\nthis.api = { REASON_REQUIRED, MIN_REASON_LENGTH, reasonRequired, reasonProblem, validate, KIND_DIRECTION };', ctx);
  return ctx.api;
}

const REQUIRED = ['loss', 'theft', 'destroyed', 'write_off', 'gift'];
const VALUE = ['loss', 'theft', 'destroyed', 'write_off', 'free_sample', 'gift'];
const OPTIONAL = ['receipt', 'sales_return', 'sale', 'free_sample', 'adjustment'];
const BAD_REASONS = [undefined, null, '', ' ', '  \t\n ', 'a', 'ab', ' ab ', 'a b'.slice(0, 2), '\n\n\n'.slice(0, 2)];
const GOOD_REASONS = ['abc', ' abc ', 'ab c', 'water damage', 'x'.repeat(500), '\u0939\u093f\u0902\u0926\u0940', '\ud83d\ude00\ud83d\ude00'];
const dirOf = (m, k) => m.KIND_DIRECTION[k] || -1;

function battery(m) {
  const bad = [];
  const eq = (name, got, want) => { if (JSON.stringify(plain(got)) !== JSON.stringify(want)) bad.push(name + ': got ' + JSON.stringify(plain(got)) + ' want ' + JSON.stringify(want)); };
  const mv = (kind, reason, extra) => { const o = { kind: kind, qty: dirOf(m, kind) * 2 }; if (reason !== undefined) o.reason = reason; return m.validateMovements([Object.assign(o, extra || {})]); };

  // the decision itself is pinned in words
  eq('required list', m.REASON_REQUIRED, REQUIRED);
  eq('value list', m.VALUE_KINDS, VALUE);
  eq('min length', m.MIN_REASON_LENGTH, 3);
  eq('every required kind is a kind', REQUIRED.every((k) => m.MOVEMENT_KINDS.indexOf(k) >= 0), true);
  eq('every value kind is a kind', VALUE.every((k) => m.MOVEMENT_KINDS.indexOf(k) >= 0), true);

  // required kinds: refused without a real reason
  for (const k of REQUIRED) {
    for (const r of BAD_REASONS) eq(k + ' refused for ' + JSON.stringify(r), plain(mv(k, r)), { ok: false, status: 400, error: 'movement-reason-required' });
    for (const r of GOOD_REASONS) eq(k + ' accepted for ' + show(r).slice(0, 12), mv(k, r).ok, true);
    eq(k + ' stores the TRIMMED reason', mv(k, '  water  ').movements[0].reason, 'water');
  }
  // optional kinds: any reason, including none
  for (const k of OPTIONAL) for (const r of BAD_REASONS.concat(GOOD_REASONS)) eq(k + ' needs nothing ' + show(r).slice(0, 12), mv(k, r).ok, true);
  // boundary: exactly MIN counts, one less does not (after trim)
  eq('3 chars ok', mv('loss', 'abc').ok, true);
  eq('2 chars refused', mv('loss', 'ab').error, 'movement-reason-required');
  eq('3 chars padded with spaces ok', mv('loss', '   abc   ').ok, true);
  eq('2 chars padded refused', mv('loss', '   ab   ').error, 'movement-reason-required');
  // order of checks: kind, then direction, then value, then length/type, then required
  eq('unknown kind first', plain(m.validateMovements([{ kind: 'stolen', qty: -1 }])).error, 'invalid-movement-kind');
  eq('wrong direction before reason', plain(m.validateMovements([{ kind: 'theft', qty: 1 }])).error, 'invalid-movement-qty');
  eq('bad value before reason', plain(m.validateMovements([{ kind: 'theft', qty: -1, valueAtCost: -1 }])).error, 'invalid-movement-value');
  eq('non-string reason is invalid, not required', mv('theft', 5).error, 'invalid-movement-reason');
  eq('too long is invalid, not required', mv('theft', 'x'.repeat(501)).error, 'invalid-movement-reason');
  eq('whitespace-only 500 chars is required', mv('theft', ' '.repeat(500)).error, 'movement-reason-required');
  // one bad movement fails the whole list, nothing partial
  const mixed = plain(m.validateMovements([{ kind: 'sale', qty: -1 }, { kind: 'theft', qty: -1, reason: '' }]));
  eq('second movement missing reason fails all', mixed, { ok: false, status: 400, error: 'movement-reason-required' });
  eq('all fine passes both', m.validateMovements([{ kind: 'sale', qty: -1 }, { kind: 'theft', qty: -1, reason: 'stolen at counter' }]).movements.length, 2);
  // no movements at all is still fine (derived rows need no reason)
  eq('undefined movements', plain(m.validateMovements(undefined)), { ok: true, movements: [] });
  eq('derived adjustment has no reason and is allowed', m.deriveMovement(-2, 'adjustment')[0].reason, '');

  // unitCostOf
  for (const [doc, want] of [[{ price: 12.5 }, 12.5], [{ price: 0.01 }, 0.01], [{ price: 1e9 }, 1e9], [{ price: 0 }, 0], [{ price: -3 }, 0], [{ price: NaN }, 0],
    [{ price: Infinity }, 0], [{ price: '12' }, 0], [{ price: null }, 0], [{ price: [] }, 0], [{}, 0], [null, 0], [undefined, 0], [7, 0], ['x', 0], [[], 0]]) {
    eq('unitCostOf ' + JSON.stringify(doc), m.unitCostOf(doc), want);
  }
  eq('sellingPrice is not cost', m.unitCostOf({ sellingPrice: 99 }), 0);

  // valueFor
  for (const k of VALUE) {
    eq('stamp ' + k, m.valueFor({ kind: k, qty: -3, valueAtCost: 999 }, 12.5), 37.5);
    eq('stamp ignores the client value ' + k, m.valueFor({ kind: k, qty: -3, valueAtCost: 0 }, 12.5), 37.5);
    eq('stamp uses |qty| ' + k, m.valueFor({ kind: k, qty: -2, valueAtCost: 0 }, 5), 10);
    eq('unknown cost stamps 0 ' + k, m.valueFor({ kind: k, qty: -3, valueAtCost: 999 }, 0), 0);
    eq('no product doc leaves the value ' + k, m.valueFor({ kind: k, qty: -3, valueAtCost: 999 }, undefined), 999);
  }
  for (const k of ['receipt', 'sales_return', 'sale', 'adjustment']) eq('untouched ' + k, m.valueFor({ kind: k, qty: dirOf(m, k) * 3, valueAtCost: 50 }, 12.5), 50);
  eq('paise rounding down', m.valueFor({ kind: 'loss', qty: -0.333, valueAtCost: 0 }, 3.33), 1.11);
  eq('paise rounding up', m.valueFor({ kind: 'loss', qty: -1, valueAtCost: 0 }, 0.005), 0.01);
  eq('fraction qty', m.valueFor({ kind: 'loss', qty: -2.5, valueAtCost: 0 }, 19.99), 49.98);
  eq('overflow is 0, never Infinity', m.valueFor({ kind: 'loss', qty: -1e308, valueAtCost: 0 }, 1e10), 0);
  eq('a big honest value survives', m.valueFor({ kind: 'loss', qty: -1000000, valueAtCost: 0 }, 99999.99), 99999990000);

  // buildRows end to end
  const ctx = { baseId: 'b', productId: 'p', actorUid: 'u', actorRole: 'staff', serverTimestamp: 'TS', clientTimestamp: 1, requestId: 'b' };
  const rows = m.buildRows([{ kind: 'loss', qty: -2, reason: 'wet', valueAtCost: 999, derived: false }, { kind: 'sale', qty: -1, reason: '', valueAtCost: 7, derived: false }], Object.assign({ unitCost: 20 }, ctx));
  eq('row 0 stamped', rows[0].data.valueAtCost, 40);
  eq('row 1 untouched', rows[1].data.valueAtCost, 7);
  const rows2 = m.buildRows([{ kind: 'loss', qty: -2, reason: 'wet', valueAtCost: 999, derived: false }], ctx);
  eq('no unitCost in ctx leaves value', rows2[0].data.valueAtCost, 999);
  const rows3 = m.buildRows([{ kind: 'loss', qty: -2, reason: 'wet', valueAtCost: 999, derived: false }], Object.assign({ unitCost: 0 }, ctx));
  eq('unitCost 0 in ctx stamps 0', rows3[0].data.valueAtCost, 0);
  eq('row shape keeps its keys', Object.keys(rows[0].data).sort(), ['actorRole', 'actorUid', 'clientTimestamp', 'derived', 'id', 'kind', 'productId', 'qty', 'reason', 'requestId', 'serverTimestamp', 'valueAtCost']);
  return bad;
}

test('RP-01 the policy and stamping battery passes on the real file', () => {
  const bad = battery(loadLogic(SRC));
  assert.deepEqual(bad, [], bad.slice(0, 6).join('\n'));
});

test('RP-02 the client helper agrees with the server for every kind and reason (parity matrix + monkey)', () => {
  const H = loadHelper(HELPER);
  assert.deepEqual(plain(H.REASON_REQUIRED), ML.REASON_REQUIRED);
  assert.equal(H.MIN_REASON_LENGTH, ML.MIN_REASON_LENGTH);
  const reasons = BAD_REASONS.concat(GOOD_REASONS, [5, {}, [], true, 'x'.repeat(501)]);
  let checked = 0;
  for (const kind of Object.keys(ML.KIND_DIRECTION)) {
    for (const reason of reasons) {
      const qty = dirOf(ML, kind) * 2;
      const mvm = { kind, qty }; if (reason !== undefined) mvm.reason = reason;
      const server = ML.validateMovements([mvm]);
      const client = H.validate('inventory', { stock: qty }, {}, [mvm]);
      assert.equal(client, server.ok ? '' : server.error, `${kind} ${show(reason).slice(0, 14)}`);
      checked++;
    }
  }
  assert.ok(checked > 150);
  // reasonProblem: words only when needed
  for (const k of ML.MOVEMENT_KINDS) {
    for (const r of reasons) {
      const p = H.reasonProblem(k, r);
      const needs = ML.REASON_REQUIRED.indexOf(k) >= 0 && !(typeof r === 'string' && r.trim().length >= 3);
      assert.equal(p !== '', needs, `${k} ${show(r).slice(0, 14)}`);
    }
    assert.equal(H.reasonRequired(k), ML.REASON_REQUIRED.indexOf(k) >= 0);
  }
  assert.equal(H.reasonProblem('theft', ''), 'Add a short reason (at least 3 characters).');
  for (const j of [undefined, null, 5, {}, [], 'constructor', '__proto__']) assert.equal(H.reasonRequired(j), false);
  // monkey: random mixed lists agree
  let seed = 31337;
  const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  let agreeOk = 0, agreeBad = 0;
  const kinds = Object.keys(ML.KIND_DIRECTION).concat(['stolen', '', undefined]);
  for (let i = 0; i < 3000; i++) {
    const list = [];
    for (let j = 0; j < 1 + Math.floor(rnd() * 3); j++) {
      const kind = pick(kinds);
      const o = { kind, qty: (ML.KIND_DIRECTION[kind] || pick([1, -1])) * pick([1, 2, 0.5, 0]) };
      const r = pick(reasons.concat([undefined, undefined]));
      if (r !== undefined) o.reason = r;
      list.push(o);
    }
    const server = ML.validateMovements(list);
    const stock = list.reduce((a, x) => a + (typeof x.qty === 'number' ? x.qty : 0), 0);
    const client = H.validate('inventory', { stock }, {}, list);
    if (!server.ok) { assert.equal(client, server.error, JSON.stringify(list)); agreeBad++; } else { assert.equal(client, '', JSON.stringify(list)); agreeOk++; }
  }
  assert.ok(agreeOk > 100 && agreeBad > 100, `monkey reached both outcomes: ${agreeOk}/${agreeBad}`);
});

test('RP-03 the failure-cause table treats the new code as an app problem, and no UI needs it as a person message', () => {
  const fc = fs.readFileSync(path.join(__dirname, '..', '..', 'qml', 'helper', 'FailureCause.js'), 'utf8');
  assert.match(fc, /"movement-reason-required": true/);
  // the picker must stop the person BEFORE a request is queued (reasonProblem), so reaching the server is a bug
  assert.match(HELPER, /function reasonProblem\(/);
});

// ---- hand mutants ------------------------------------------------------------------------------------------------
const MUTANTS = [
  ['loss not required', 'const REASON_REQUIRED = ["loss", "theft", "destroyed", "write_off", "gift"]', 'const REASON_REQUIRED = ["theft", "destroyed", "write_off", "gift"]'],
  ['gift not required', '"write_off", "gift"];\nconst MIN_REASON_LENGTH', '"write_off"];\nconst MIN_REASON_LENGTH'],
  ['free_sample required', 'const REASON_REQUIRED = ["loss", "theft", "destroyed", "write_off", "gift"]', 'const REASON_REQUIRED = ["loss", "theft", "destroyed", "write_off", "gift", "free_sample"]'],
  ['adjustment required', 'const REASON_REQUIRED = ["loss", "theft", "destroyed", "write_off", "gift"]', 'const REASON_REQUIRED = ["loss", "theft", "destroyed", "write_off", "gift", "adjustment"]'],
  ['min length 1', 'const MIN_REASON_LENGTH = 3', 'const MIN_REASON_LENGTH = 1'],
  ['min length 4', 'const MIN_REASON_LENGTH = 3', 'const MIN_REASON_LENGTH = 4'],
  ['length not trimmed', 'if (REASON_REQUIRED.indexOf(m.kind) >= 0 && trimmed.length < MIN_REASON_LENGTH)', 'if (REASON_REQUIRED.indexOf(m.kind) >= 0 && reason.length < MIN_REASON_LENGTH)'],
  ['boundary off by one', 'trimmed.length < MIN_REASON_LENGTH', 'trimmed.length <= MIN_REASON_LENGTH'],
  ['policy dropped', 'if (REASON_REQUIRED.indexOf(m.kind) >= 0 && trimmed.length < MIN_REASON_LENGTH) return _fail("movement-reason-required")', ''],
  ['wrong error code', '_fail("movement-reason-required")', '_fail("invalid-movement-reason")'],
  ['stored reason untrimmed', 'movements.push({ kind: m.kind, qty: m.qty, reason: trimmed,', 'movements.push({ kind: m.kind, qty: m.qty, reason: reason,'],
  ['stamp dropped from rows', 'valueAtCost: valueFor(m, ctx.unitCost),', 'valueAtCost: m.valueAtCost,'],
  ['free_sample not stamped', 'const VALUE_KINDS = ["loss", "theft", "destroyed", "write_off", "free_sample", "gift"]', 'const VALUE_KINDS = ["loss", "theft", "destroyed", "write_off", "gift"]'],
  ['sale stamped', 'const VALUE_KINDS = ["loss", "theft", "destroyed", "write_off", "free_sample", "gift"]', 'const VALUE_KINDS = ["loss", "theft", "destroyed", "write_off", "free_sample", "gift", "sale"]'],
  ['receipt stamped', 'const VALUE_KINDS = ["loss", "theft", "destroyed", "write_off", "free_sample", "gift"]', 'const VALUE_KINDS = ["loss", "theft", "destroyed", "write_off", "free_sample", "gift", "receipt"]'],
  ['client value kept', 'if (unitCost === undefined || VALUE_KINDS.indexOf(m.kind) < 0) return m.valueAtCost;', 'if (unitCost === undefined || VALUE_KINDS.indexOf(m.kind) < 0 || m.valueAtCost > 0) return m.valueAtCost;'],
  ['abs dropped', 'Math.round(Math.abs(m.qty) * unitCost * 100 + 1e-6) / 100', 'Math.round(m.qty * unitCost * 100 + 1e-6) / 100'],
  ['no rounding', 'Math.round(Math.abs(m.qty) * unitCost * 100 + 1e-6) / 100', 'Math.abs(m.qty) * unitCost'],
  ['rounding to rupees', 'Math.round(Math.abs(m.qty) * unitCost * 100 + 1e-6) / 100', 'Math.round(Math.abs(m.qty) * unitCost)'],
  ['float nudge dropped', '* 100 + 1e-6) / 100', '* 100) / 100'],
  ['float nudge relative', '* 100 + 1e-6) / 100', '* 100 * (1 + 1e-12)) / 100'],
  ['overflow kept', 'return isFinite(v) ? v : 0;', 'return v;'],
  ['undefined cost stamps 0', 'if (unitCost === undefined || VALUE_KINDS', 'if (VALUE_KINDS'],
  ['negative cost allowed', 'typeof c === "number" && isFinite(c) && c > 0) ? c : 0', 'typeof c === "number" && isFinite(c)) ? c : 0'],
  ['string cost allowed', 'return (typeof c === "number" && isFinite(c) && c > 0) ? c : 0;', 'return (Number(c) > 0 && isFinite(Number(c))) ? Number(c) : 0;'],
  ['selling price used', 'doc.price : undefined', 'doc.sellingPrice : undefined'],
  ['infinite cost allowed', 'typeof c === "number" && isFinite(c) && c > 0) ? c : 0', 'typeof c === "number" && c > 0) ? c : 0']
];

test('RP-04 every hand mutant is noticed by the battery', () => {
  const survivors = [], broken = [];
  for (const [name, from, to] of MUTANTS) {
    const n = SRC.split(from).length - 1;
    if (n !== 1) { broken.push(`${name} (${n} matches)`); continue; }
    let bad;
    try { bad = battery(loadLogic(SRC.replace(from, to))); } catch (e) { continue; }
    if (bad.length === 0) survivors.push(name);
  }
  assert.deepEqual(broken, [], 'mutants that do not match exactly once: ' + broken.join(', '));
  assert.deepEqual(survivors, [], 'survivors: ' + survivors.join(', '));
});
