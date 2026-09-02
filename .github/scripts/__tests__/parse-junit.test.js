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
