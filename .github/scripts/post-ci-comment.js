'use strict';

/**
 * Posts (or updates) a single PR comment summarizing this workflow run's test results.
 *
 * Run only by the `pr-comment` job in .github/workflows/checks.yml, on `pull_request` events,
 * after all test jobs have finished (`if: always()`). Reads:
 *   - one JUnit XML file per test job, downloaded into ./artifacts/<artifact-name>/results.xml
 *   - GITHUB_TOKEN (built-in Actions token, not Taher's PAT) for the GitHub API
 *   - job result strings passed in via env vars (needs.<job>.result)
 *
 * All the actual logic (parsing, URL resolution, markdown construction) lives in
 * parse-junit.js / resolve-job-url.js / build-summary.js and is unit tested there.
 * This file is intentionally thin I/O glue.
 */

const fs = require('node:fs');
const path = require('node:path');
const { parseJUnitXml } = require('./parse-junit');
const { resolveJobUrl } = require('./resolve-job-url');
const { buildCommentBody, COMMENT_MARKER } = require('./build-summary');

const JOB_CONFIG = [
  { display: 'QML Tests', artifactDir: 'qml-test-results', resultEnv: 'QML_TESTS_RESULT' },
  { display: 'Functions Tests', artifactDir: 'functions-test-results', resultEnv: 'FUNCTIONS_TESTS_RESULT' },
  { display: 'Firestore Rules Tests', artifactDir: 'firestore-rules-test-results', resultEnv: 'FIRESTORE_RULES_TESTS_RESULT' },
  { display: 'E2E Tests', artifactDir: 'e2e-test-results', resultEnv: 'E2E_TESTS_RESULT' },
];

const ARTIFACTS_ROOT = process.env.ARTIFACTS_ROOT || 'artifacts';
const RESULT_FILENAME = 'results.xml';

function readResultsFile(artifactDir) {
  const filePath = path.join(ARTIFACTS_ROOT, artifactDir, RESULT_FILENAME);
  try {
    return fs.readFileSync(filePath, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') return null;
    throw err;
  }
}

async function githubRequest(method, url, token, body) {
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`GitHub API ${method} ${url} failed: ${res.status} ${text}`);
  }
  return res.status === 204 ? null : res.json();
}

async function findExistingCommentId({ apiBase, token, prNumber }) {
  // Paginate defensively; PRs rarely have enough comments to need more than one page,
  // but a long-lived PR with lots of review chatter could.
  let page = 1;
  while (page < 20) {
    const comments = await githubRequest(
      'GET',
      `${apiBase}/issues/${prNumber}/comments?per_page=100&page=${page}`,
      token
    );
    const found = comments.find((c) => c.body && c.body.startsWith(COMMENT_MARKER));
    if (found) return found.id;
    if (comments.length < 100) return null;
    page += 1;
  }
  return null;
}

async function main() {
  const token = process.env.GITHUB_TOKEN;
  const prNumber = process.env.PR_NUMBER;
  const runId = process.env.RUN_ID;
  const repo = process.env.GITHUB_REPOSITORY; // "owner/repo", set automatically by Actions
  const serverUrl = process.env.GITHUB_SERVER_URL || 'https://github.com';
  const apiUrl = process.env.GITHUB_API_URL || 'https://api.github.com';

  if (!token || !prNumber || !runId || !repo) {
    console.error('Missing required env vars (GITHUB_TOKEN, PR_NUMBER, RUN_ID, GITHUB_REPOSITORY). Skipping comment.');
    process.exitCode = 1;
    return;
  }

  const apiBase = `${apiUrl}/repos/${repo}`;
  const runUrl = `${serverUrl}/${repo}/actions/runs/${runId}`;

  let jobsResponse = null;
  try {
    jobsResponse = await githubRequest('GET', `${apiBase}/actions/runs/${runId}/jobs?per_page=100`, token);
  } catch (err) {
    console.error(`Could not fetch job list (links will be unavailable): ${err.message}`);
  }

  const jobs = JOB_CONFIG.map(({ display, artifactDir, resultEnv }) => {
    const xml = readResultsFile(artifactDir);
    const parsed = xml !== null ? parseJUnitXml(xml) : null;
    const jobUrl = resolveJobUrl(jobsResponse, display);
    const jobResult = (process.env[resultEnv] || 'skipped').toLowerCase();
    return { display, jobResult, jobUrl, parsed };
  });

  const body = buildCommentBody({ jobs, runUrl });

  const existingCommentId = await findExistingCommentId({ apiBase, token, prNumber });
  if (existingCommentId) {
    await githubRequest('PATCH', `${apiBase}/issues/comments/${existingCommentId}`, token, { body });
    console.log(`Updated existing PR comment ${existingCommentId}.`);
  } else {
    await githubRequest('POST', `${apiBase}/issues/${prNumber}/comments`, token, { body });
    console.log('Created new PR comment.');
  }
}

module.exports = { main, JOB_CONFIG };

if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exitCode = 1;
  });
}
