'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { buildIndex, checkIndex, main } = require('../skills-index');

const REPO = path.resolve(__dirname, '..', '..', '..');
const lines = (idx) => idx.text.split('\n').filter((l) => l.startsWith('- '));

// ---- unit: happy path ----
test('happy: one index line per skill heading, in file order, id and full title kept', () => {
  const r = buildIndex('# SKILLS.md\n\n## Overview\n\n## Skill 1: Using CardKPI\n\nbody\n\n## Skill 2: Using `StatusBadge` (RBAC)\n');
  assert.deepEqual(r.errors, []);
  assert.equal(r.count, 2);
  assert.deepEqual(lines(r), ['- 1: Using CardKPI', '- 2: Using `StatusBadge` (RBAC)']);
});

test('happy: header tells the reader how to open one skill (awk) and how to search (grep)', () => {
  const r = buildIndex('## Skill 7: x\n');
  assert.match(r.text, /awk -v id=104/);
  assert.match(r.text, /grep -n -i/);
  assert.match(r.text, /GENERATED from SKILLS\.md/);
});

test('happy: the documented awk one-liner returns exactly the requested skill, including a suffixed id', () => {
  const { execFileSync } = require('child_process');
  const md = '## Skill 88: a\nA body\n## Skill 89: b\nB body\n## Skill 89b: c\nC body\n## Skill 90: d\n';
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'awk-'));
  fs.writeFileSync(path.join(dir, 'SKILLS.md'), md);
  const run = (id) => execFileSync('awk', ['-v', `id=${id}`, '/^## Skill /{p=($3==id":")} p', 'SKILLS.md'], { cwd: dir, encoding: 'utf8' });
  assert.equal(run('89'), '## Skill 89: b\nB body\n');
  assert.equal(run('89b'), '## Skill 89b: c\nC body\n');
  assert.equal(run('999'), '');
});

// ---- edge ----
test('edge: empty SKILLS.md yields an index with zero skills and no errors', () => {
  const r = buildIndex('');
  assert.equal(r.count, 0);
  assert.deepEqual(r.errors, []);
});

test('edge: ### and # headings and "## Overview" are not skills', () => {
  const r = buildIndex('# Skill 1: no\n## Overview\n### Skill 2: no\n#### Skill 3: no\n## Skill 4: yes\n');
  assert.deepEqual(lines(r), ['- 4: yes']);
});

test('edge: a skill heading inside a code fence is example text, not a skill', () => {
  const r = buildIndex('## Skill 1: real\n```md\n## Skill 2: example\n```\n~~~\n## Skill 3: example\n~~~\n## Skill 4: real too\n');
  assert.deepEqual(lines(r), ['- 1: real', '- 4: real too']);
  assert.deepEqual(r.errors, []);
});

test('edge: CRLF files and trailing spaces in the title produce clean lines', () => {
  const r = buildIndex('## Skill 1: Title with trailing space   \r\n## Skill 2: next\r\n');
  assert.deepEqual(lines(r), ['- 1: Title with trailing space', '- 2: next']);
});

test('edge: letter-suffixed ids (89b) are valid and distinct from 89', () => {
  const r = buildIndex('## Skill 89: a\n## Skill 89b: b\n');
  assert.deepEqual(r.errors, []);
  assert.equal(r.count, 2);
});

// ---- negative ----
test('negative: duplicate id is an error naming both lines and the fix', () => {
  const r = buildIndex('## Skill 5: a\n\n## Skill 5: b\n');
  assert.equal(r.errors.length, 1);
  assert.match(r.errors[0], /line 3: duplicate Skill 5 \(first at line 1\).*5b/);
  assert.equal(r.count, 1);
});

test('negative: malformed headings (no colon, no title, dash) are errors, not silently dropped', () => {
  const r = buildIndex('## Skill 5 - dash title\n## Skill 6:\n## Skill six: words\n## Skills 7: plural\n## Skill 8: ok\n');
  assert.equal(r.count, 1);
  assert.equal(r.errors.length, 3);
  assert.match(r.errors[0], /line 1: malformed skill heading/);
});

test('negative: checkIndex fails on a stale index and says how to fix it', () => {
  const md = '## Skill 1: a\n';
  const r = checkIndex(md, 'old content');
  assert.equal(r.ok, false);
  assert.match(r.problems[0], /--write/);
});

test('negative: checkIndex reports heading errors and does not also claim the index is stale', () => {
  const r = checkIndex('## Skill 1: a\n## Skill 1: b\n', 'whatever');
  assert.equal(r.ok, false);
  assert.equal(r.problems.length, 1);
  assert.match(r.problems[0], /duplicate/);
});

test('positive: checkIndex passes on freshly built text, fails after one heading changes', () => {
  const md = '## Skill 1: a\n## Skill 2: b\n';
  const fresh = buildIndex(md).text;
  assert.equal(checkIndex(md, fresh).ok, true);
  assert.equal(checkIndex(md.replace('b', 'c'), fresh).ok, false);
});

// ---- functional: CLI against a temp repo ----
function tmpRepo(skills, index) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'skills-'));
  fs.writeFileSync(path.join(dir, 'SKILLS.md'), skills);
  if (index !== undefined) fs.writeFileSync(path.join(dir, 'SKILLS-INDEX.md'), index);
  return dir;
}
const quiet = (fn) => {
  const log = console.log, err = console.error;
  console.log = () => {}; console.error = () => {};
  try { return fn(); } finally { console.log = log; console.error = err; }
};

test('functional: --write then --check round-trips (exit 0), file content equals buildIndex', () => {
  const dir = tmpRepo('## Skill 1: a\n## Skill 2: b\n');
  assert.equal(quiet(() => main(['--write'], dir)), 0);
  assert.equal(fs.readFileSync(path.join(dir, 'SKILLS-INDEX.md'), 'utf8'), buildIndex('## Skill 1: a\n## Skill 2: b\n').text);
  assert.equal(quiet(() => main(['--check'], dir)), 0);
});

test('functional: --check exits 1 when the index file is missing or edited by hand', () => {
  const dir = tmpRepo('## Skill 1: a\n');
  assert.equal(quiet(() => main(['--check'], dir)), 1);
  quiet(() => main(['--write'], dir));
  fs.appendFileSync(path.join(dir, 'SKILLS-INDEX.md'), '- 99: hand-written lie\n');
  assert.equal(quiet(() => main(['--check'], dir)), 1);
});

test('functional: --write refuses (exit 1) and leaves no file when SKILLS.md has a duplicate id', () => {
  const dir = tmpRepo('## Skill 1: a\n## Skill 1: b\n');
  assert.equal(quiet(() => main(['--write'], dir)), 1);
  assert.equal(fs.existsSync(path.join(dir, 'SKILLS-INDEX.md')), false);
});

test('functional: no flag prints usage and exits 2', () => {
  assert.equal(quiet(() => main([], tmpRepo('## Skill 1: a\n'))), 2);
});

// ---- monkey: seeded random files ----
test('MONKEY: 5 seeds x 200 random headings/fences/noise: count = unique valid ids outside fences, order kept, deterministic', () => {
  for (let seed = 1; seed <= 5; seed++) {
    let s = seed * 7919;
    const rnd = (n) => { s = (s * 1103515245 + 12345) & 0x7fffffff; return s % n; };
    const out = [];
    const expected = [];
    const ids = new Set();
    let fence = false;
    for (let i = 0; i < 200; i++) {
      const k = rnd(8);
      if (k === 0) { fence = !fence; out.push('```'); continue; }
      if (k <= 3) {
        const id = String(rnd(60)) + (rnd(4) === 0 ? 'b' : '');
        const title = `T${rnd(1000)} -> a "q" <x> & \`c\``;
        out.push(`## Skill ${id}: ${title}`);
        if (!fence && !ids.has(id)) { ids.add(id); expected.push(`- ${id}: ${title}`); }
      } else if (k === 4) out.push('## Skill broken heading');
      else out.push(['', 'body text', '### Skill 1: sub', '## Overview'][rnd(4)]);
    }
    const md = out.join('\n');
    const r = buildIndex(md);
    assert.deepEqual(lines(r), expected, `seed ${seed}`);
    assert.equal(buildIndex(md).text, r.text, `deterministic, seed ${seed}`);
  }
});

// ---- repo-state: the live guard ----
test('REPO: SKILLS-INDEX.md matches SKILLS.md (fix: node .github/scripts/skills-index.js --write)', () => {
  const md = fs.readFileSync(path.join(REPO, 'SKILLS.md'), 'utf8');
  const idx = fs.readFileSync(path.join(REPO, 'SKILLS-INDEX.md'), 'utf8');
  const r = checkIndex(md, idx);
  assert.deepEqual(r.problems, []);
});

test('REPO: every skill id in SKILLS.md is findable in the index (nothing hidden)', () => {
  const md = fs.readFileSync(path.join(REPO, 'SKILLS.md'), 'utf8');
  const idx = fs.readFileSync(path.join(REPO, 'SKILLS-INDEX.md'), 'utf8');
  const inFile = (md.match(/^## Skill \d+[a-z]?:/gm) || []).length;
  assert.ok(inFile > 100);
  assert.equal((idx.match(/^- \d+[a-z]?: /gm) || []).length, inFile);
});

test('functional: the real CLI entry point runs --check against this repo and exits 0; unknown flag exits 2', () => {
  const { spawnSync } = require('child_process');
  const cli = path.join(__dirname, '..', 'skills-index.js');
  assert.equal(spawnSync(process.execPath, [cli, '--check'], { encoding: 'utf8' }).status, 0);
  assert.equal(spawnSync(process.execPath, [cli, '--nope'], { encoding: 'utf8' }).status, 2);
});
