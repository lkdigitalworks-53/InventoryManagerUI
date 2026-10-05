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

// Tag body that is aware of quoted attribute values. node's JUnit reporter does NOT escape ">" in
// attribute values (a test named "x -> 400" is written verbatim), so `[^>]*` ended the tag inside the
// name, fell into the open-tag branch and swallowed the following self-closing testcases: CI
// reported 370 of 585 functions tests (exactly the 215 names containing ">").
const TAG_BODY = '(?:[^>"]|"[^"]*")*';
const ATTRS_LAZY = '((?:[^>"]|"[^"]*")*?)'; // lazy so a trailing "/" is left for the self-closing branch
const TESTCASE_RE = new RegExp(`<testcase\\b${TAG_BODY}\\/>|<testcase\\b${TAG_BODY}>[\\s\\S]*?<\\/testcase>`, 'g');
const TESTCASE_OPEN_RE = new RegExp(`^<testcase\\b${TAG_BODY}>`);
const FAILURE_RE = new RegExp(`<failure\\b${ATTRS_LAZY}(?:\\/>|>([\\s\\S]*?)<\\/failure>)`);
const ERROR_RE = new RegExp(`<error\\b${ATTRS_LAZY}(?:\\/>|>([\\s\\S]*?)<\\/error>)`);

/**
 * Parses raw JUnit XML text into a normalized summary.
 * @param {string} xml raw file contents
 * @returns {{tests:number, failed:number, errors:number, skipped:number, passed:number, failedTests:Array<{name:string, classname:string, message:string}>}}
 */
function parseJUnitXml(xml) {
  if (!xml || !xml.trim()) {
    return { tests: 0, failed: 0, errors: 0, skipped: 0, passed: 0, failedTests: [] };
  }

  let tests = 0;
  let failed = 0;
  let errors = 0;
  let skipped = 0;
  const failedTests = [];

  // Every <testcase> in the document is counted, wherever it sits. <testsuite> wrappers are NOT
  // used: they carry nothing this summary needs, and keying on them dropped every bare
  // <testcase> (node's reporter emits no wrapper) whenever a qmltestrunner file was concatenated
  // in front of it -- the E2E job's node tests were invisible in the PR comment.
  for (const tcMatch of xml.matchAll(TESTCASE_RE)) {
    const tc = tcMatch[0];
    const openTag = tc.match(TESTCASE_OPEN_RE)[0];
    const name = extractAttr(openTag, 'name') || '(unnamed test)';
    const classname = extractAttr(openTag, 'classname') || '';

    tests += 1;

    const failureMatch = tc.match(FAILURE_RE);
    const errorMatch = tc.match(ERROR_RE);
    const skippedMatch = tc.match(/<skipped\b[^>]*\/?>|<skipped\b[^>]*>[\s\S]*?<\/skipped>/);

    if (failureMatch || errorMatch) {
      const which = failureMatch || errorMatch;
      const attrsPart = which[1] || '';
      const bodyPart = which[2] || '';
      const message =
        decodeXmlEntities(extractAttr(`<x ${attrsPart}>`, 'message')) ||
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

  const passed = Math.max(0, tests - failed - errors - skipped);

  return { tests, failed, errors, skipped, passed, failedTests };
}

module.exports = { parseJUnitXml, decodeXmlEntities };
