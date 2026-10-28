'use strict';
// Throwaway QtTest shim for PURE-JS helpers (not a replacement for qmltestrunner; CI is the oracle).
// Runs every test_* function of a TestCase in a .qml test against a .pragma library file.
// Usage: node scripts/probes/qtest-shim.cjs tests/tst_SheetFooter.qml qml/helper/SheetFooter.js SF
// Limits: no _data rows, no signals, no tryCompare; compare() is fuzzy for numbers only.
const fs = require('fs'), vm = require('vm');
const [,, qmlPath, jsPath, alias] = process.argv;
const qml = fs.readFileSync(qmlPath, 'utf8');
const start = qml.indexOf('TestCase {');
let body = qml.slice(qml.indexOf('{', start) + 1, qml.lastIndexOf('}'));
body = body.replace(/^\s*name:.*$/m, '');
const fnNames = [...body.matchAll(/function (\w+)\(/g)].map(m => m[1]);
const js = fs.readFileSync(jsPath, 'utf8').replace(/^\.pragma library/m, '');
const ctx = vm.createContext({ console });
vm.runInContext(js + '\n;this.__exports = {' + [...js.matchAll(/^(?:function|var) (\w+)/gm)].map(m => `${m[1]}: typeof ${m[1]} !== 'undefined' ? ${m[1]} : undefined`).join(',') + '}', ctx);
const mod = ctx.__exports;
const approx = (a, b) => typeof a === 'number' && typeof b === 'number' ? (a === b || Math.abs(a - b) <= 1e-9 * Math.max(1, Math.abs(a), Math.abs(b))) : (JSON.stringify(a) === JSON.stringify(b) && Object.is(a, b) || JSON.stringify(a) === JSON.stringify(b));
let cur = '';
const compare = (a, b) => { if (!approx(a, b)) throw new Error(`compare failed: ${String(a)} vs ${String(b)}`); };
const verify = (c, m) => { if (!c) throw new Error('verify failed' + (m ? ': ' + m : '')); };
const fail = m => { throw new Error('fail: ' + m); };
const factory = new Function(alias, 'compare', 'verify', 'fail', body + '\nreturn {' + fnNames.map(n => `${n}: ${n}`).join(',') + '}');
const t = factory(mod, compare, verify, fail);
let pass = 0, bad = [];
for (const n of fnNames.filter(n => n.startsWith('test_'))) {
  try { t[n](); pass++; } catch (e) { bad.push(`${n}: ${e.message}`); }
}
console.log(`${pass} passed, ${bad.length} failed`);
bad.forEach(b => console.log('  FAIL ' + b));
process.exit(bad.length ? 1 : 0);
