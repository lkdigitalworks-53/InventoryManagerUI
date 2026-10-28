const fs = require('fs'), cp = require('child_process'), path = require('path');
const os = require('os');
const SP = fs.mkdtempSync(path.join(os.tmpdir(), 'sheet-footer-mut-'));
const SHIM = path.join(__dirname, 'qtest-shim.cjs');
// Usage (from the repo root): node scripts/probes/sheet-footer-mutants.cjs
// Every mutant of qml/helper/SheetFooter.js must turn tests/tst_SheetFooter.qml red (run by the shim).
// Known equivalent mutant: `v >= 0` for `v > 0` (0 maps to 0 either way).
const src = fs.readFileSync('qml/helper/SheetFooter.js', 'utf8');
const M = [
  ['var SLACK = 2', 'var SLACK = 0'], ['var SLACK = 2', 'var SLACK = 1'], ['var SLACK = 2', 'var SLACK = 3'],
  ['var MAX_SHARE = 0.65', 'var MAX_SHARE = 1'], ['var MAX_SHARE = 0.65', 'var MAX_SHARE = 0.5'], ['var MAX_SHARE = 0.65', 'var MAX_SHARE = 0.7'],
  ['typeof v === "number" && isFinite(v) && v > 0', 'isFinite(v) && v > 0'],
  ['typeof v === "number" && isFinite(v) && v > 0', 'typeof v === "number" && v > 0'],
  ['typeof v === "number" && isFinite(v) && v > 0', 'typeof v === "number" && isFinite(v) && v >= 0'],
  ['typeof v === "number" && isFinite(v) && v > 0', 'typeof v === "number" && isFinite(v)'],
  ['? v : 0', '? v : 1'],
  ['if (label === 0) return 0', ''],
  ['if (label === 0) return 0', 'if (label === 0) return 1'],
  ['Math.ceil(label)', 'label'], ['Math.ceil(label)', 'Math.floor(label)'], ['Math.ceil(label)', 'Math.round(label)'],
  ['Math.min(need,', 'Math.max(need,'],
  ['_size(padding)', 'padding'], ['+ _size(padding)', ''], ['+ SLACK', ''],
  ['_size(rowWidth) * MAX_SHARE', 'rowWidth * MAX_SHARE'], ['_size(rowWidth) * MAX_SHARE', '_size(rowWidth)'],
  ['var label = _size(labelWidth)', 'var label = labelWidth'],
  ['Math.ceil(label) + _size(padding) + SLACK', 'Math.ceil(label) - _size(padding) + SLACK'],
  ['Math.ceil(label) + _size(padding) + SLACK', 'Math.ceil(label) * _size(padding) + SLACK'],
];
let killed = 0, survived = [];
M.forEach(([a, b], i) => {
  if (!src.includes(a)) { console.log('VACUOUS mutant', i, a); survived.push(i); return; }
  const f = path.join(SP, 'mut.js'); fs.writeFileSync(f, src.replace(a, b));
  const r = cp.spawnSync('node', [SHIM, 'tests/tst_SheetFooter.qml', f, 'SF']);
  if (r.status !== 0) killed++; else survived.push(`${i}: ${a} -> ${b}`);
});
console.log(`mutants killed ${killed}/${M.length}`); survived.forEach(s => console.log('  SURVIVED', s));
process.exit(survived.length === 1 && /v >= 0/.test(String(survived[0])) ? 0 : (survived.length ? 1 : 0));
