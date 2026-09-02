'use strict';

/**
 * Given the GitHub API response for "list jobs for a workflow run"
 * (GET /repos/{owner}/{repo}/actions/runs/{run_id}/jobs), find the html_url
 * for the job matching the given display name.
 *
 * Separated out as a pure function (input: parsed JSON, output: string|null)
 * so the matching logic can be unit tested without hitting the network.
 *
 * @param {{jobs: Array<{name: string, html_url: string}>}} jobsResponse
 * @param {string} jobName
 * @returns {string|null}
 */
function resolveJobUrl(jobsResponse, jobName) {
  if (!jobsResponse || !Array.isArray(jobsResponse.jobs)) return null;
  const match = jobsResponse.jobs.find((j) => j.name === jobName);
  return match ? match.html_url : null;
}

module.exports = { resolveJobUrl };
