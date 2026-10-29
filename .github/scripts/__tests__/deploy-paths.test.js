'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { needsDeploy } = require('../deploy-paths');

// ---- happy path: every deployable artifact triggers ------------------------------------------
test('DP01 functions source triggers', () => {
  assert.equal(needsDeploy(['functions/index.js']), true);
});
test('DP02 functions lib and package files trigger (a dependency bump changes the deployed bundle)', () => {
  assert.equal(needsDeploy(['functions/lib/photoCleanup.js']), true);
  assert.equal(needsDeploy(['functions/package.json']), true);
  assert.equal(needsDeploy(['functions/package-lock.json']), true);
});
test('DP03 firestore.rules triggers', () => {
  assert.equal(needsDeploy(['firestore.rules']), true);
});
test('DP04 firestore.indexes.json triggers', () => {
  assert.equal(needsDeploy(['firestore.indexes.json']), true);
});
test('DP05 firebase.json triggers (deploy config)', () => {
  assert.equal(needsDeploy(['firebase.json']), true);
});

// ---- negatives: things that must NOT ask for a deploy ----------------------------------------
test('DP06 docs, QML, C++ and CI-only changes do not trigger', () => {
  assert.equal(needsDeploy(['README.md', 'docs/superpowers/specs/x.md', 'qml/pages/A.qml', 'src/a.cpp', '.github/workflows/checks.yml']), false);
});
test('DP07 functions tests alone do not trigger, but a source change next to them does', () => {
  assert.equal(needsDeploy(['functions/test/a.test.js', 'functions/test/testSupport/h.js']), false);
  assert.equal(needsDeploy(['functions/test/a.test.js', 'functions/index.js']), true);
});
test('DP08 look-alikes do not trigger', () => {
  for (const p of ['functions-old/index.js', 'myfunctions/index.js', 'FIRESTORE_RULES.md', 'firestore.rules.md',
    'test/firestore.rules.test.js', 'docs/firestore.rules', 'firestore.indexes.json.bak', 'sub/firebase.json', 'storage.rules']) {
    assert.equal(needsDeploy([p]), false, p);
  }
});
test('DP09 storage.rules is out of scope on purpose (Taher 2026-10-28)', () => {
  assert.equal(needsDeploy(['storage.rules']), false);
});

// ---- edge cases ------------------------------------------------------------------------------
test('DP10 empty list, blank lines and whitespace-only entries do not trigger', () => {
  assert.equal(needsDeploy([]), false);
  assert.equal(needsDeploy(['', '   ', '\t']), false);
});
test('DP11 surrounding whitespace is trimmed (CRLF, trailing space)', () => {
  assert.equal(needsDeploy(['firestore.rules\r']), true);
  assert.equal(needsDeploy(['  functions/index.js ']), true);
});
test('DP12 one deployable file among many triggers, order does not matter', () => {
  const noise = Array.from({ length: 200 }, (_, i) => `docs/f${i}.md`);
  assert.equal(needsDeploy([...noise, 'firestore.indexes.json']), true);
  assert.equal(needsDeploy(['firestore.indexes.json', ...noise]), true);
});
test('DP13 non-array and non-string members never throw and do not trigger', () => {
  for (const bad of [null, undefined, 'functions/index.js', 42, {}, () => {}]) {
    assert.equal(needsDeploy(bad), false);
  }
  assert.equal(needsDeploy([null, undefined, 7, {}, ['functions/index.js']]), false);
});
test('DP14 unicode and odd names are matched literally, not by accident', () => {
  assert.equal(needsDeploy(['docs/é.md', 'qml/日本.qml']), false);
  assert.equal(needsDeploy(['functions/é.js']), true);
});

// ---- monkey ----------------------------------------------------------------------------------
test('DP15 MONKEY: 3000 random paths never throw, always return a boolean, and agree with an independent oracle', () => {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz./_- \t\r\né日';
  const pieces = ['functions/', 'firestore.rules', 'firestore.indexes.json', 'firebase.json', 'test/', 'docs/', 'storage.rules'];
  let seed = 42;
  const rnd = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; };
  for (let i = 0; i < 3000; i++) {
    let s = '';
    const n = Math.floor(rnd() * 5);
    for (let j = 0; j < n; j++) {
      s += rnd() < 0.5 ? pieces[Math.floor(rnd() * pieces.length)] : alphabet[Math.floor(rnd() * alphabet.length)];
    }
    const out = needsDeploy([s]);
    assert.equal(typeof out, 'boolean');
    const p = s.trim();
    const oracle = (p.startsWith('functions/') && !p.startsWith('functions/test/'))
      || p === 'firestore.rules' || p === 'firestore.indexes.json' || p === 'firebase.json';
    assert.equal(out, oracle, JSON.stringify(s));
  }
});

// ---- CLI (what the workflow actually runs) ---------------------------------------------------
const SCRIPT = path.join(__dirname, '..', 'deploy-paths.js');
const run = (input) => spawnSync(process.execPath, [SCRIPT], { input, encoding: 'utf8' });

test('DP16 CLI: prints true for a deployable diff, false for docs only, false for empty stdin', () => {
  assert.equal(run('README.md\nfirestore.rules\n').stdout, 'true\n');
  assert.equal(run('README.md\ndocs/a.md\n').stdout, 'false\n');
  assert.equal(run('').stdout, 'false\n');
  assert.equal(run('functions/index.js').status, 0);
});
