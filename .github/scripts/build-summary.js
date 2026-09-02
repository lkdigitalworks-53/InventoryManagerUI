'use strict';

const COMMENT_MARKER = '<!-- ci-status-comment:checks.yml -->';

const STATUS_EMOJI = {
  success: '✅',
  failure: '❌',
  cancelled: '⚠️',
  skipped: '⏭️',
  missing: '❓',
};

/**
 * @typedef {Object} JobSummaryInput
 * @property {string} display        Human-readable job name, e.g. "QML Tests"
 * @property {string} jobResult       'success' | 'failure' | 'cancelled' | 'skipped'
 * @property {string|null} jobUrl     Deep link to that job's log page, or null if unresolved
 * @property {{tests:number, failed:number, errors:number, skipped:number, passed:number, failedTests:Array}|null} parsed
 *           Parsed JUnit summary, or null if no results file was found (e.g. job crashed before
 *           tests ran, or the artifact download failed).
 */

/**
 * Builds the full PR comment markdown body from per-job test results.
 * Pure function -- no network calls, no filesystem, no GitHub API -- so behavior can be
 * verified with plain unit tests independent of CI/network state.
 *
 * @param {{jobs: JobSummaryInput[], runUrl: string}} input
 * @returns {string} markdown comment body, including the upsert marker
 */
function buildCommentBody({ jobs, runUrl }) {
  const totals = jobs.reduce(
    (acc, job) => {
      if (!job.parsed) return acc;
      acc.tests += job.parsed.tests;
      acc.passed += job.parsed.passed;
      acc.failed += job.parsed.failed + job.parsed.errors;
      acc.skipped += job.parsed.skipped;
      return acc;
    },
    { tests: 0, passed: 0, failed: 0, skipped: 0 }
  );

  const anyJobFailed = jobs.some((j) => j.jobResult === 'failure' || (j.parsed && (j.parsed.failed > 0 || j.parsed.errors > 0)));
  const anyJobUnresolved = jobs.some((j) => j.jobResult === 'cancelled' || (!j.parsed && j.jobResult !== 'skipped'));
  const overallStatus = anyJobFailed ? 'failure' : anyJobUnresolved ? 'cancelled' : 'success';

  const headline =
    overallStatus === 'success'
      ? `${STATUS_EMOJI.success} **All CI checks passed** — ${totals.passed}/${totals.tests} tests passed` +
        (totals.skipped > 0 ? ` (${totals.skipped} skipped)` : '')
      : overallStatus === 'failure'
        ? `${STATUS_EMOJI.failure} **CI checks failed** — ${totals.failed} of ${totals.tests} tests failed`
        : `${STATUS_EMOJI.cancelled} **CI did not complete cleanly** — one or more jobs were cancelled or produced no results`;

  const lines = [COMMENT_MARKER, `### ${headline}`, ''];

  lines.push('| Job | Status | Tests | Passed | Failed | Skipped | Logs |');
  lines.push('|---|---|---|---|---|---|---|');
  for (const job of jobs) {
    const emoji = job.parsed
      ? job.parsed.failed + job.parsed.errors > 0
        ? STATUS_EMOJI.failure
        : STATUS_EMOJI.success
      : STATUS_EMOJI[job.jobResult] || STATUS_EMOJI.missing;
    const p = job.parsed;
    const link = job.jobUrl ? `[View logs](${job.jobUrl})` : '_(unavailable)_';
    lines.push(
      `| ${job.display} | ${emoji} ${job.jobResult} | ${p ? p.tests : '—'} | ${p ? p.passed : '—'} | ${
        p ? p.failed + p.errors : '—'
      } | ${p ? p.skipped : '—'} | ${link} |`
    );
  }
  lines.push('');

  const failingJobs = jobs.filter((j) => j.parsed && j.parsed.failedTests.length > 0);
  if (failingJobs.length > 0) {
    lines.push('<details open>');
    lines.push('<summary><strong>Failed tests</strong></summary>');
    lines.push('');
    for (const job of failingJobs) {
      lines.push(`**${job.display}** (${job.jobUrl ? `[logs](${job.jobUrl})` : 'logs unavailable'})`);
      for (const ft of job.parsed.failedTests) {
        const location = ft.classname ? `${ft.classname} › ` : '';
        lines.push(`- \`${location}${ft.name}\` — ${ft.message}`);
      }
      lines.push('');
    }
    lines.push('</details>');
    lines.push('');
  }

  const noResultJobs = jobs.filter((j) => !j.parsed && j.jobResult !== 'skipped');
  if (noResultJobs.length > 0) {
    lines.push('<details>');
    lines.push('<summary>Jobs that produced no test results (likely failed before tests ran)</summary>');
    lines.push('');
    for (const job of noResultJobs) {
      lines.push(`- **${job.display}**: \`${job.jobResult}\`${job.jobUrl ? ` — [logs](${job.jobUrl})` : ''}`);
    }
    lines.push('');
    lines.push('</details>');
    lines.push('');
  }

  lines.push(`[View full CI run](${runUrl})`);

  return lines.join('\n');
}

module.exports = { buildCommentBody, COMMENT_MARKER };
