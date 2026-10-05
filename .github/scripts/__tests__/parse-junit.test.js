'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { parseJUnitXml } = require('../parse-junit');

test('happy path: all tests pass, no failures', () => {
  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="orderMath" tests="3" failures="0" errors="0" skipped="0">
  <testcase name="lineTax computes correctly" classname="orderMath.test.js" time="0.01"/>
  <testcase name="refundPerUnit rounds down" classname="orderMath.test.js" time="0.02"/>
  <testcase name="applies GST rate" classname="orderMath.test.js" time="0.03"/>
</testsuite>`;
  const result = parseJUnitXml(xml);
  assert.equal(result.tests, 3);
  assert.equal(result.passed, 3);
  assert.equal(result.failed, 0);
  assert.equal(result.errors, 0);
  assert.equal(result.skipped, 0);
  assert.deepEqual(result.failedTests, []);
});

test('failure case: extracts test name, classname, and message from message attribute', () => {
  const xml = `<testsuite name="orderMath" tests="2" failures="1" errors="0" skipped="0">
  <testcase name="lineTax computes correctly" classname="orderMath.test.js" time="0.01"/>
  <testcase name="refundPerUnit rounds down" classname="orderMath.test.js" time="0.02">
    <failure message="Expected 10 but got 11" type="AssertionError">AssertionError: Expected 10 but got 11
    at Object.&lt;anonymous&gt; (/functions/test/orderMath.test.js:42:10)</failure>
  </testcase>
</testsuite>`;
  const result = parseJUnitXml(xml);
  assert.equal(result.tests, 2);
  assert.equal(result.passed, 1);
  assert.equal(result.failed, 1);
  assert.equal(result.failedTests.length, 1);
  assert.equal(result.failedTests[0].name, 'refundPerUnit rounds down');
  assert.equal(result.failedTests[0].classname, 'orderMath.test.js');
  assert.equal(result.failedTests[0].message, 'Expected 10 but got 11');
});

test('failure case: falls back to element body when no message attribute present', () => {
  const xml = `<testsuite name="rules" tests="1" failures="1" errors="0" skipped="0">
  <testcase name="denies cross-tenant read" classname="firestore.rules.test.js">
    <failure>PERMISSION_DENIED expected but request succeeded</failure>
  </testcase>
</testsuite>`;
  const result = parseJUnitXml(xml);
  assert.equal(result.failedTests[0].message, 'PERMISSION_DENIED expected but request succeeded');
});

test('error element is counted separately from failure but both surface as failedTests', () => {
  const xml = `<testsuite name="mixed" tests="2" failures="1" errors="1" skipped="0">
  <testcase name="a" classname="c">
    <failure message="assertion mismatch"/>
  </testcase>
  <testcase name="b" classname="c">
    <error message="unexpected exception thrown"/>
  </testcase>
</testsuite>`;
  const result = parseJUnitXml(xml);
  assert.equal(result.failed, 1);
  assert.equal(result.errors, 1);
  assert.equal(result.failedTests.length, 2);
});

test('skipped tests are counted but not treated as failures', () => {
  const xml = `<testsuite name="s" tests="2" failures="0" errors="0" skipped="1">
  <testcase name="a" classname="c"/>
  <testcase name="b" classname="c"><skipped/></testcase>
</testsuite>`;
  const result = parseJUnitXml(xml);
  assert.equal(result.tests, 2);
  assert.equal(result.skipped, 1);
  assert.equal(result.passed, 1);
  assert.equal(result.failed, 0);
  assert.deepEqual(result.failedTests, []);
});

test('multiple <testsuite> blocks in one file are aggregated', () => {
  const xml = `<testsuites>
  <testsuite name="suiteA" tests="1" failures="0">
    <testcase name="a" classname="A"/>
  </testsuite>
  <testsuite name="suiteB" tests="1" failures="1">
    <testcase name="b" classname="B"><failure message="boom"/></testcase>
  </testsuite>
</testsuites>`;
  const result = parseJUnitXml(xml);
  assert.equal(result.tests, 2);
  assert.equal(result.passed, 1);
  assert.equal(result.failed, 1);
  assert.equal(result.failedTests[0].name, 'b');
});

test('edge case: empty string input produces zeroed-out summary, no throw', () => {
  const result = parseJUnitXml('');
  assert.deepEqual(result, { tests: 0, failed: 0, errors: 0, skipped: 0, passed: 0, failedTests: [] });
});

test('edge case: whitespace-only input produces zeroed-out summary', () => {
  const result = parseJUnitXml('   \n\t  ');
  assert.equal(result.tests, 0);
});

test('edge case: null/undefined input does not throw', () => {
  assert.doesNotThrow(() => parseJUnitXml(null));
  assert.doesNotThrow(() => parseJUnitXml(undefined));
});

test('edge case: testsuite with zero testcases', () => {
  const xml = `<testsuite name="empty" tests="0" failures="0"></testsuite>`;
  const result = parseJUnitXml(xml);
  assert.equal(result.tests, 0);
  assert.equal(result.passed, 0);
});

test('edge case: self-closing testcase with no children (passing, terse form)', () => {
  const xml = `<testsuite name="s"><testcase name="passes" classname="c" time="0.00"/></testsuite>`;
  const result = parseJUnitXml(xml);
  assert.equal(result.tests, 1);
  assert.equal(result.passed, 1);
});

test('edge case: failure message contains XML entities that must be decoded', () => {
  const xml = `<testsuite name="s"><testcase name="t" classname="c">
    <failure message="expected a &lt; b &amp; c &quot;quoted&quot;"/>
  </testcase></testsuite>`;
  const result = parseJUnitXml(xml);
  assert.equal(result.failedTests[0].message, 'expected a < b & c "quoted"');
});

test('edge case: multi-line failure message body is truncated to first line, capped at 300 chars', () => {
  const longLine = 'x'.repeat(400);
  const xml = `<testsuite name="s"><testcase name="t" classname="c">
    <failure>${longLine}
second line ignored</failure>
  </testcase></testsuite>`;
  const result = parseJUnitXml(xml);
  assert.equal(result.failedTests[0].message.length, 300);
  assert.ok(!result.failedTests[0].message.includes('second line'));
});

test('edge case: testcase missing classname attribute does not throw and defaults to empty string', () => {
  const xml = `<testsuite name="s"><testcase name="t"/></testsuite>`;
  const result = parseJUnitXml(xml);
  assert.equal(result.tests, 1);
});

test('edge case: unnamed testcase falls back to placeholder name', () => {
  const xml = `<testsuite name="s"><testcase classname="c"><failure message="oops"/></testcase></testsuite>`;
  const result = parseJUnitXml(xml);
  assert.equal(result.failedTests[0].name, '(unnamed test)');
});

test('regression: passed count never goes negative even if attribute-derived math would', () => {
  // Constructed pathological input: more failures reported in message parsing than testcases
  // (shouldn't happen from real generators, but the parser must not emit negative numbers).
  const xml = `<testsuite name="s"><testcase name="a" classname="c"><failure message="x"/></testcase></testsuite>`;
  const result = parseJUnitXml(xml);
  assert.ok(result.passed >= 0);
});

// ---- 2026-10-06: ">" in attribute values + bare testcases next to a <testsuite> file -------------------
// Regression for CI undercounting (Functions 370 of 585: the 215 names containing "->"; E2E: node
// --test files invisible next to qmltestrunner's results.xml). node's JUnit reporter writes ">" raw.

test('regression: ">" inside a testcase name does not swallow its neighbours', () => {
  const xml = `<testsuites>
  <testcase name="F31 batch -> 400 cascade-delete-not-allowed" time="0.1" classname="test"/>
  <testcase name="plain" time="0.1" classname="test"/>
  <testcase name="a > b and c -> d" time="0.1" classname="test"/>
</testsuites>`;
  const r = parseJUnitXml(xml);
  assert.equal(r.tests, 3);
  assert.equal(r.passed, 3);
});

test('regression: bare node testcases are counted when a <testsuite> file is concatenated in front', () => {
  const qml = `<testsuite name="tst_X" tests="2" failures="0"><testcase name="a" classname="tst_X"/><testcase name="b" classname="tst_X"/></testsuite>`;
  const node = `<testsuites>\n<testcase name="E1 x" time="0.1" classname="test"/>\n<testcase name="E2 y" time="0.1" classname="test"/>\n<!-- tests 2 -->\n</testsuites>`;
  const r = parseJUnitXml(qml + '\n' + node);
  assert.equal(r.tests, 4);
  assert.equal(r.passed, 4);
});

test('a failing testcase whose name and message contain ">" is reported with its full name and message', () => {
  const xml = `<testsuites>
  <testcase name="P1 -> 400" time="0.1" classname="test"/>
  <testcase name="P2 -> 500" time="0.1" classname="test">
    <failure message="expected 1 > 0 but got -> nothing" type="testCodeFailure">AssertionError</failure>
  </testcase>
  <testcase name="P3 -> 200" time="0.1" classname="test"/>
</testsuites>`;
  const r = parseJUnitXml(xml);
  assert.equal(r.tests, 3);
  assert.equal(r.failed, 1);
  assert.equal(r.passed, 2);
  assert.equal(r.failedTests[0].name, 'P2 -> 500');
  assert.equal(r.failedTests[0].message, 'expected 1 > 0 but got -> nothing');
});

test('self-closing failure (qmltestrunner style) next to a ">" name still parses', () => {
  const xml = `<testsuite name="s"><testcase name="q -> r" classname="s"><failure message="boom" result="fail"/></testcase><testcase name="ok" classname="s"/></testsuite>`;
  const r = parseJUnitXml(xml);
  assert.equal(r.tests, 2);
  assert.equal(r.failed, 1);
  assert.equal(r.failedTests[0].message, 'boom');
});

test('error and skipped testcases with ">" names are classified, not merged into neighbours', () => {
  const xml = `<testsuites>
  <testcase name="a -> b" classname="t"><error message="e > f"/></testcase>
  <testcase name="c -> d" classname="t"><skipped/></testcase>
  <testcase name="e -> f" classname="t"/>
</testsuites>`;
  const r = parseJUnitXml(xml);
  assert.deepEqual([r.tests, r.errors, r.skipped, r.passed, r.failed], [3, 1, 1, 1, 0]);
});

test('nested <testsuite> (describe) with ">" names: every testcase counted once', () => {
  const xml = `<testsuites><testsuite name="outer -> x"><testcase name="a" classname="t"/><testsuite name="inner"><testcase name="b -> c" classname="t"/></testsuite><testcase name="d" classname="t"/></testsuite></testsuites>`;
  assert.equal(parseJUnitXml(xml).tests, 3);   // a, "b -> c", d
});

test('a document with no testcase at all (only comments / empty suites) yields zero', () => {
  const r = parseJUnitXml('<testsuites>\n<!-- tests 0 -->\n<testsuite name="empty" tests="0"/>\n</testsuites>');
  assert.deepEqual([r.tests, r.passed, r.failed], [0, 0, 0]);
});

test('MONKEY: 5 seeds x 300 testcases with random ">", "<" (escaped), "&", quotes: count and failures exact', () => {
  const alphabet = ['a', 'B', ' ', '-', '>', ' > ', '->', '&amp;', '&lt;', '&gt;', '&quot;', "'", '/', '=', '(', ')', '0', '9'];
  for (let seed = 1; seed <= 5; seed++) {
    let x = seed * 2654435761 % 4294967296;
    const rnd = () => { x = (x * 1664525 + 1013904223) % 4294967296; return x / 4294967296; };
    let xml = '<testsuites>\n';
    let wantFailed = 0;
    for (let i = 0; i < 300; i++) {
      let name = 'T' + i + ' ';
      for (let k = 0, n = 1 + Math.floor(rnd() * 12); k < n; k++) name += alphabet[Math.floor(rnd() * alphabet.length)];
      if (rnd() < 0.1) { wantFailed++; xml += `<testcase name="${name}" classname="t"><failure message="m &gt; n">x</failure></testcase>\n`; }
      else xml += `<testcase name="${name}" classname="t"/>\n`;
    }
    xml += '</testsuites>';
    const r = parseJUnitXml(xml);
    assert.equal(r.tests, 300, 'seed ' + seed + ' tests');
    assert.equal(r.failed, wantFailed, 'seed ' + seed + ' failed');
    assert.equal(r.failedTests.length, wantFailed, 'seed ' + seed + ' failedTests');
  }
});

test('REGRESSION FIXTURE: 585-case node junit shape with 215 ">" names counts all 585', () => {
  let xml = '<?xml version="1.0" encoding="utf-8"?>\n<testsuites>\n';
  for (let i = 0; i < 585; i++) xml += `\t<testcase name="case ${i}${i < 215 ? ' -> 400' : ''}" time="0.001" classname="test"/>\n`;
  xml += '\t<!-- tests 585 -->\n</testsuites>\n';
  assert.equal(parseJUnitXml(xml).tests, 585);
});

test('edge: testcase without a name and a failure without message or body fall back to placeholders', () => {
  const r = parseJUnitXml('<testsuite><testcase classname="t"><failure/></testcase></testsuite>');
  assert.equal(r.failed, 1);
  assert.equal(r.failedTests[0].name, '(unnamed test)');
  assert.equal(r.failedTests[0].message, 'No failure message provided.');
});

test('hardening: truncated/garbage XML with 20000 unterminated <testcase tags parses in linear time', () => {
  const started = Date.now();
  const r = parseJUnitXml('<testcase name="'.repeat(20000));
  assert.equal(r.tests, 0);
  assert.ok(Date.now() - started < 2000, `took ${Date.now() - started} ms (was ~20000 ms with the looser tag class)`);
});

test('hardening: a truncated final tag (runner killed mid-write) does not hide the complete testcases before it', () => {
  const r = parseJUnitXml('<testcase name="a -> b" classname="c"/>\n<testcase name="b" classname="c"/>\n<testcase name="cut off -> ');
  assert.equal(r.tests, 2);
  assert.equal(r.failed, 0);
});

test('hardening: a raw "<" inside an attribute value (invalid XML) ends that tag instead of swallowing the rest', () => {
  const r = parseJUnitXml('<testcase name="bad < name" classname="c"/><testcase name="ok" classname="c"/><testcase name="ok2" classname="c"/>');
  assert.equal(r.tests, 2); // the invalid tag is dropped; its valid neighbours are still counted
});
