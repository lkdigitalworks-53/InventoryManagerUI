'use strict';

// Task 11 wiring guard. DataModel/OrderDetailDialog cannot be fully driven by node, and the dialog
// cannot be instantiated under qmltestrunner (Felgo import), so the rules that keep the syncing
// state from going stale are pinned here by reading the sources. Behaviour is tested in
// tests/tst_DataModel_completionsSyncing.qml.
// Plan: docs/superpowers/test-plans/2026-10-14-task11-saved-syncing-test-plan.md

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..', '..');
const read = (...p) => fs.readFileSync(path.join(REPO, ...p), 'utf8');

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

// Broken rules for a DataModel source (empty = wired).
function modelProblems(src) {
  const out = [];
  if (!/property var syncingOrderIds: \(\{\}\)/.test(src)) out.push('prop-map');
  if (!/property int completionsSyncing: 0/.test(src)) out.push('prop-count');
  const refresh = bodyOf(src, '_refreshSyncing');
  if (!/syncingOrderIds = ids/.test(refresh)) out.push('refresh-assigns-new-object');
  if (!/completionsSyncing = n/.test(refresh)) out.push('refresh-assigns-count');
  if (!/open && open\.undo/.test(refresh)) out.push('refresh-counts-only-shown');
  const close = bodyOf(src, '_closeOpen');
  if (!/delete _openCompletions\[key\]/.test(close) || !/_refreshSyncing\(\)/.test(close)) out.push('close-deletes-and-refreshes');
  // The only raw delete of an open completion is the one inside _closeOpen.
  const rawDeletes = src.match(/delete (dataModel\.)?_openCompletions\[/g) || [];
  if (rawDeletes.length !== 1) out.push('raw-delete-outside-closeOpen:' + rawDeletes.length);
  // Showing a predicted state must refresh.
  if (!/open\.undo = _applyPredicted\(open\.plan\); _refreshSyncing\(\)/.test(src)) out.push('refresh-after-show');
  // Reopen path must use the funnel.
  if (!/dataModel\._closeOpen\(openKey\)/.test(bodyOf(src, '_reverseCompletedOrder'))) out.push('reopen-uses-closeOpen');
  return out;
}

function dialogProblems(src) {
  const out = [];
  if (!/visible: dataModel\.syncingOrderIds\[dlg\.orderId\] === true/.test(src)) out.push('visible-binding');
  if (!/text: qsTr\("Saved\. Syncing…"\)/.test(src)) out.push('text');
  if (!/Accessible\.name: qsTr\(/.test(src.slice(src.indexOf('id: syncingHint')))) out.push('accessible-name');
  return out;
}

const MODEL = read('qml', 'model', 'DataModel.qml');
const DIALOG = read('qml', 'pages', 'OrderDetailDialog.qml');

test('DataModel: syncing state is wired and every close goes through _closeOpen', () => {
  assert.deepEqual(modelProblems(MODEL), []);
});

test('OrderDetailDialog: caption is bound to this dialog\'s own order id', () => {
  assert.deepEqual(dialogProblems(DIALOG), []);
});

// Mutants: each broken variant must be caught (the guard itself is under test).
const modelMutants = {
  'raw delete added': (s) => s.replace('_closeOpen(openKey)', 'delete dataModel._openCompletions[openKey]'),
  'refresh dropped after show': (s) => s.replace('; _refreshSyncing() }', ' }'),
  'in-place mutation (no new object)': (s) => s.replace('syncingOrderIds = ids', 'syncingOrderIds[0] = ids'),
  'counts every open entry': (s) => s.replace('if (open && open.undo && !ids', 'if (open && !ids'),
  'close forgets refresh': (s) => s.replace('delete _openCompletions[key]\n        _refreshSyncing()', 'delete _openCompletions[key]'),
  'count property removed': (s) => s.replace('property int completionsSyncing: 0', ''),
};
for (const [name, mutate] of Object.entries(modelMutants)) {
  test(`mutant caught: ${name}`, () => {
    const mutated = mutate(MODEL);
    assert.notEqual(mutated, MODEL, 'mutation must change the source');
    assert.notDeepEqual(modelProblems(mutated), []);
  });
}

const dialogMutants = {
  'bound to a global count': (s) => s.replace('dataModel.syncingOrderIds[dlg.orderId] === true', 'dataModel.completionsSyncing > 0'),
  'text changed': (s) => s.replace('Saved. Syncing…', 'Done'),
  'accessible name removed': (s) => s.replace(/Accessible\.name: qsTr\("Saved\. Syncing with the server"\)/, ''),
};
for (const [name, mutate] of Object.entries(dialogMutants)) {
  test(`dialog mutant caught: ${name}`, () => {
    const mutated = mutate(DIALOG);
    assert.notEqual(mutated, DIALOG);
    assert.notDeepEqual(dialogProblems(mutated), []);
  });
}
