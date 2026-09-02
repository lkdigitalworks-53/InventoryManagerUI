'use strict';

/**
 * Minimal, dependency-free JUnit XML parser.
 *
 * Scope is deliberately narrow: this only needs to handle the JUnit XML
 * produced by the two generators used in this repo's CI --
 * `qmltestrunner -o results.xml,junitxml` and
 * `node --test --test-reporter=junit` -- both of which emit standard
 * <testsuite>/<testcase>/<failure|error|skipped> structures. It is not a
 * general-purpose XML parser and will not handle arbitrary JUnit dialects
 * (e.g. nested <testsuites> attributes beyond name/tests/failures/errors,
 * or <system-out>/<system-err> content, which are ignored on purpose).
 */

function decodeXmlEntities(str) {
  if (!str) return str;
  return str
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

function extractAttr(tag, attrName) {
  // \b prevents "name" from matching inside "classname" (both are word chars,
  // so \b correctly refuses to match at the class/name boundary).
  const match = tag.match(new RegExp(`\\b${attrName}="([^"]*)"`));
  return match ? decodeXmlEntities(match[1]) : null;
}

/**
 * Parses raw JUnit XML text into a normalized summary.
 * @param {string} xml raw file contents
 * @returns {{tests:number, failed:number, errors:number, skipped:number, passed:number, failedTests:Array<{name:string, classname:string, message:string}>}}
 */
function parseJUnitXml(xml) {
  if (!xml || !xml.trim()) {
    return { tests: 0, failed: 0, errors: 0, skipped: 0, passed: 0, failedTests: [] };
  }

  const testsuiteBlocks = [...xml.matchAll(/<testsuite\b[^>]*>[\s\S]*?<\/testsuite>|<testsuite\b[^>]*\/>/g)];

  let tests = 0;
  let failed = 0;
  let errors = 0;
  let skipped = 0;
  const failedTests = [];

  // If the file has no <testsuite> wrapper at all (unexpected but be lenient),
  // treat the whole document as one implicit suite so testcases still parse.
  const suiteSources = testsuiteBlocks.length > 0 ? testsuiteBlocks.map((m) => m[0]) : [xml];

  for (const suite of suiteSources) {
    const testcaseBlocks = [
      ...suite.matchAll(/<testcase\b[^>]*\/>|<testcase\b[^>]*>[\s\S]*?<\/testcase>/g),
    ];

    for (const tcMatch of testcaseBlocks) {
      const tc = tcMatch[0];
      const openTag = tc.match(/<testcase\b[^>]*>/) ? tc.match(/<testcase\b[^>]*>/)[0] : tc;
      const name = extractAttr(openTag, 'name') || '(unnamed test)';
      const classname = extractAttr(openTag, 'classname') || '';

      tests += 1;

      const failureMatch = tc.match(/<failure\b([^>]*)(?:\/>|>([\s\S]*?)<\/failure>)/);
      const errorMatch = tc.match(/<error\b([^>]*)(?:\/>|>([\s\S]*?)<\/error>)/);
      const skippedMatch = tc.match(/<skipped\b[^>]*\/?>|<skipped\b[^>]*>[\s\S]*?<\/skipped>/);

      if (failureMatch || errorMatch) {
        const which = failureMatch || errorMatch;
        const attrsPart = which[1] || '';
        const bodyPart = which[2] || '';
        const message =
          decodeXmlEntities(extractAttr(`<x${attrsPart}>`, 'message')) ||
          decodeXmlEntities(bodyPart.trim()) ||
          'No failure message provided.';

        if (failureMatch) failed += 1;
        else errors += 1;

        failedTests.push({
          name,
          classname,
          message: message.split('\n')[0].slice(0, 300),
        });
      } else if (skippedMatch) {
        skipped += 1;
      }
    }
  }

  const passed = Math.max(0, tests - failed - errors - skipped);

  return { tests, failed, errors, skipped, passed, failedTests };
}

module.exports = { parseJUnitXml, decodeXmlEntities };
