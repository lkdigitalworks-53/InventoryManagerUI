'use strict';

/**
 * Generates SKILLS-INDEX.md from the `## Skill <id>: <title>` headings of SKILLS.md.
 * Why: SKILLS.md is ~300 KB and was read in full every session. The index is ~12 KB; a session reads
 * it and opens only the skills whose title matches the task. Generated, never hand-edited, so it
 * cannot drift (checked by the script tests) and cannot hide a skill.
 *
 *   node .github/scripts/skills-index.js --write   regenerate SKILLS-INDEX.md
 *   node .github/scripts/skills-index.js --check   exit 1 if the index is stale or SKILLS.md is malformed
 */

const fs = require('fs');
const path = require('path');

const HEADING = /^## Skill (\d+[a-z]?): (.+?)\s*$/;
const LOOSE_HEADING = /^## Skill\b/;
const FENCE = /^\s*(```|~~~)/;

function buildIndex(skillsMd) {
  const errors = [];
  const seen = new Map();
  const entries = [];
  let inFence = false;

  String(skillsMd).split(/\r?\n/).forEach((line, i) => {
    if (FENCE.test(line)) { inFence = !inFence; return; }
    if (inFence || !LOOSE_HEADING.test(line)) return;
    const m = line.match(HEADING);
    if (!m) { errors.push(`line ${i + 1}: malformed skill heading "${line.slice(0, 60)}" (want "## Skill <n>: <title>")`); return; }
    const [, id, title] = m;
    if (seen.has(id)) { errors.push(`line ${i + 1}: duplicate Skill ${id} (first at line ${seen.get(id)}); give it a new id, e.g. ${id}b`); return; }
    seen.set(id, i + 1);
    entries.push({ id, title });
  });

  const text = [
    '# SKILLS-INDEX.md',
    '',
    '<!-- GENERATED from SKILLS.md by .github/scripts/skills-index.js. Do not edit. After changing a skill heading run: node .github/scripts/skills-index.js --write -->',
    '',
    'Read THIS file at session start, not SKILLS.md (about 75k tokens). Then read the full text of every skill whose title touches your task:',
    '',
    '    awk -v id=104 \'/^## Skill /{p=($3==id":")} p\' SKILLS.md      # replace 104 with the id',
    '    grep -n -i "keyword" SKILLS-INDEX.md                            # find skills by topic',
    '',
    ...entries.map((e) => `- ${e.id}: ${e.title}`),
    '',
  ].join('\n');

  return { text, errors, count: entries.length };
}

function checkIndex(skillsMd, currentIndex) {
  const built = buildIndex(skillsMd);
  const problems = built.errors.slice();
  if (built.errors.length === 0 && built.text !== currentIndex) {
    problems.push('SKILLS-INDEX.md is stale. Run: node .github/scripts/skills-index.js --write');
  }
  return { ok: problems.length === 0, problems };
}

function main(argv, root) {
  const skillsPath = path.join(root, 'SKILLS.md');
  const indexPath = path.join(root, 'SKILLS-INDEX.md');
  const md = fs.readFileSync(skillsPath, 'utf8');
  if (argv.includes('--write')) {
    const built = buildIndex(md);
    if (built.errors.length) { console.error(built.errors.join('\n')); return 1; }
    fs.writeFileSync(indexPath, built.text);
    console.log(`SKILLS-INDEX.md written: ${built.count} skills`);
    return 0;
  }
  if (argv.includes('--check')) {
    const current = fs.existsSync(indexPath) ? fs.readFileSync(indexPath, 'utf8') : '';
    const r = checkIndex(md, current);
    if (!r.ok) { console.error(r.problems.join('\n')); return 1; }
    console.log('SKILLS-INDEX.md is current');
    return 0;
  }
  console.error('usage: skills-index.js --write | --check');
  return 2;
}

if (require.main === module) process.exit(main(process.argv.slice(2), path.resolve(__dirname, '..', '..')));

module.exports = { buildIndex, checkIndex, main };
