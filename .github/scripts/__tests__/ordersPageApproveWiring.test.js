'use strict';

// OrdersPage.qml cannot be instantiated under qmltestrunner (Constants imports Felgo), so the
// wiring of the "Approve all pending" progress is pinned here by reading the source. The
// logic itself is tested in tests/tst_BulkApproveProgress.qml.
// Plan: docs/superpowers/test-plans/2026-10-13-approve-all-progress-test-plan.md

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..', '..');
const PAGE = path.join(REPO, 'qml', 'pages', 'OrdersPage.qml');

// Body of `function <name>(...) { ... }` by brace matching; '' when absent.
function bodyOf(src, name) {
  const at = src.indexOf(`function ${name}(`);
  if (at < 0) return '';
  const open = src.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    if (src[i] === '}' && --depth === 0) return src.slice(open + 1, i);
  }
  return '';
}

// Returns the list of broken wiring rules for a page source (empty = wired).
function problems(src) {
  const out = [];
  const fn = bodyOf(src, '_approveAllPending');
  const firstLine = fn.split('\n').map((l) => l.trim()).find((l) => l.length > 0) || '';
  if (!src.includes('import "../helper/BulkApproveProgress.js" as BAP')) out.push('import');
  if (firstLine !== 'if (!BAP.canStart(root._approveState)) return') out.push('guard-first-line');
  if (!/root\._approveState = BAP\.start\(toApprove\.length\)/.test(fn)) out.push('start');
  // three sites since the PR #171 lock-no-access fix: the lock stage, the fail-fast skip after a 403, and the
  // loop that drains the remaining orders after it (a loop, not recursion: stack depth must not grow with the batch)
  if ((fn.match(/BAP\.step\(root\._approveState, "locked"\)/g) || []).length !== 3) out.push('step-locked');
  if (!/BAP\.step\(root\._approveState, success \? "ok" : "failed"\)/.test(fn)) out.push('step-result');
  if (!/if \(root\._approveState\.phase === "done"\) approveHold\.restart\(\)/.test(fn)) out.push('hold-start');
  if (!/enabled: BAP\.canStart\(root\._approveState\)/.test(src)) out.push('button-enabled');
  if (!/approveBtn\.pressed \? Qt\.rgba\(1,1,1,0\.38\)/.test(src)) out.push('pressed-colour');
  if (!/_approveState\.phase !== "idle"\)/.test(src)) out.push('banner-held-open');
  if (!/id: approveHold\s+interval: 1200\s+onTriggered: root\._approveState = BAP\.newState\(\)/.test(src)) out.push('hold-timer');
  if (!/width: parent\.width \* BAP\.fraction\(root\._approveState\)/.test(src)) out.push('bar-fraction');
  for (const s of ['"All approved"', '"Done"', '"Approving… %1 of %2 done"', '"%1 / %2"']) {
    if (!src.includes(`qsTr(${s})`)) out.push(`qsTr ${s}`);
  }
  return out;
}

const real = fs.readFileSync(PAGE, 'utf8');

// ---- happy ----
test('happy: the real OrdersPage.qml has every piece of the approve-progress wiring', () => {
  assert.deepEqual(problems(real), []);
});

test('happy: the helper is a QML library and is imported by the page', () => {
  const helper = fs.readFileSync(path.join(REPO, 'qml', 'helper', 'BulkApproveProgress.js'), 'utf8');
  assert.ok(helper.startsWith('.pragma library'));
});

// ---- negative: each rule fires when its line is removed ----
const MUTANTS = [
  ['import', 'import "../helper/BulkApproveProgress.js" as BAP\n', ''],
  ['guard-first-line', '        if (!BAP.canStart(root._approveState)) return\n', ''],
  ['start', 'root._approveState = BAP.start(toApprove.length)', 'var x = 0'],
  ['step-locked', 'BAP.step(root._approveState, "locked")', 'root._approveState'],
  ['step-result', 'BAP.step(root._approveState, success ? "ok" : "failed")', 'root._approveState'],
  ['hold-start', 'if (root._approveState.phase === "done") approveHold.restart()', ''],
  ['button-enabled', 'enabled: BAP.canStart(root._approveState)', 'enabled: true'],
  ['pressed-colour', 'approveBtn.pressed ? Qt.rgba(1,1,1,0.38)', 'approveBtn.pressed ? Qt.rgba(1,1,1,0.22)'],
  ['banner-held-open', '_approveState.phase !== "idle")\n                radius', 'true)\n                radius'],
  ['hold-timer', 'onTriggered: root._approveState = BAP.newState()', 'onTriggered: {}'],
  ['bar-fraction', 'BAP.fraction(root._approveState)', '1'],
  ['qsTr "All approved"', 'qsTr("All approved")', '"All approved"'],
];

for (const [rule, from, to] of MUTANTS) {
  test(`negative: removing "${rule}" is reported`, () => {
    assert.ok(real.includes(from), `fixture drifted: ${rule}`);
    assert.ok(problems(real.replace(from, to)).some((p) => p.startsWith(rule)), rule);
  });
}

// ---- edge ----
test('edge: bodyOf returns empty for a missing function and for an unbalanced one', () => {
  assert.equal(bodyOf('no functions here', '_approveAllPending'), '');
  assert.equal(bodyOf('function _approveAllPending() { if (x) {', '_approveAllPending'), '');
});

test('edge: an empty page reports every rule instead of throwing', () => {
  assert.ok(problems('').length >= 12);
});

test('edge: the guard must be the FIRST statement, not just present', () => {
  const moved = real.replace('        if (!BAP.canStart(root._approveState)) return\n        var scoped', '        var scoped');
  const late = moved.replace('var toApprove = []', 'if (!BAP.canStart(root._approveState)) return\n        var toApprove = []');
  assert.ok(problems(late).includes('guard-first-line'));
});

// ---- regression ----
test('regression: the approve button keeps a pressed look (it was a fixed 22% white)', () => {
  assert.doesNotMatch(real, /radius: dp\(Constants\.radiusPill\)\s+color: Qt\.rgba\(1,1,1,0\.22\)\s+}/);
});
