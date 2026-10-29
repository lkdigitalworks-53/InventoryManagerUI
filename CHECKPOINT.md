# CHECKPOINT — 2026-10-29 review sweep of PR #173 (CI deploy-on-merge) — resume here

**Branch:** `ci/2026-10-28-deploy-on-merge` (PR #173 head; fixes go on the SAME branch/PR). Base `main` @ `fbd7dec`.
**Commit identity:** `tsadmin@gmail.com`. PAT from the chat prompt only, via `git -c http.extraHeader=...` (helper `/home/claude/gitp.sh` in the sandbox, lost on a new session: recreate). Never in remote URL/config/repo. After a push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build/run; no Qt in sandbox (CI is the QML oracle); push without asking; tests + test plan for every change; caveman FULL in chat only; keep scope per turn small, state in remote branch.
**Skills run:** requesting-code-review, ponytail-audit, qt-ui-design, qt-qml-review. **Qt skills: N/A** (PR touches no QML/C++; only `.github/**` + docs).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-29-pr170-sweep-prev-CHECKPOINT.md`.

## Facts checked against the live repo (GitHub API, 2026-10-29)
- Repo is **public**, id `1151883837`, owner id `256964261`. No branch protection on `main`.
- **Environment `firebase-deploy` does NOT exist yet.** No `deployed-main` tag yet.
- `google-github-actions/auth` `v2` = `v2.1.13` = `c200f3691d83b41bf9bbd8638997a462592937ed` (checked).
- `firebase-tools@15.25.1` exists, published 2026-07-30 (>14 days), Node >=20 OK. Newer exists (15.34.2), pin is deliberate.
- Functions are v2 (`firebase-functions/v2/*`), no custom runtime service account => default compute SA at runtime.

## Findings (numbered; F = fix in this PR, D = documented, A = accepted)
1. **F** Approval gate can be absent: a workflow that names a missing Environment AUTO-CREATES it with NO reviewers; the job then runs unapproved. Env does not exist today. Fix: runtime fail-closed gate check (`verify-deploy-gate.js`) + doc order "arm GCP last".
2. **F/D** WIF bound to `attribute.repository` only: ANY branch workflow in the repo can mint a token and deploy, bypassing the Environment. Fix (doc): provider condition = repository_id + owner_id + `sub` of the Environment + `ref == main`.
3. **D** `roles/iam.serviceAccountUser` at project level lets the deploy SA act as any SA (privilege escalation). Fix (doc): bind on the runtime SA only.
4. **F** Stale deploy: an older approved run could overwrite newer code and move the tag backwards. Fix: `deploy-tag.sh stale` guard + forward-only tag move.
5. **F** Path filter blind spots: renames (`functions/x.js` -> `docs/x.js` shows only the new path) and non-ASCII names (git quotes them). Fix: `--no-renames`, `-z`, NUL-aware script.
6. **F** Job that runs `npm ci` + `npx` holds `contents: write` + persisted token + `id-token`. Fix: split tag move into `mark-deployed` job; deploy = `contents: read`, `persist-credentials: false`.
7. **F** No `timeout-minutes`: a hung deploy holds the non-cancelling lock 6 h. Fix: 45 min.
8. **F** Wiring tests miss the worst mutation (`always()` in the deploy `if`), the `needed == 'true'` gate, privilege split, pinning. Fix: new rules + mutants; plus REAL executed tests of the shell logic in temp git repos.
9. **F** `google-github-actions/auth@v2` is a movable tag in the job holding cloud creds: pin to SHA.
10. **F** stale name in `deploy-paths.js` header (`deploy-changes`).
11. **A/D** `npx --yes firebase-tools@15.25.1` has no lockfile integrity at deploy time (pinned version only). Accepted, documented.
12. **A/D** Tag `deployed-main` can be moved by anyone with write access. Accepted (single-owner repo), documented.

## Steps
- [x] S1. Clone, checkout PR branch, read workflow, scripts, tests, design, test plan, repo state via API.
- [x] S2. Findings list above.
- [ ] S3. Scripts: `deploy-check.sh`, `deploy-tag.sh`, `verify-deploy-gate.js`, `deploy-paths.js` NUL split + header fix.
- [ ] S4. Workflow: use scripts, split `mark-deployed`, permissions, timeout, SHA pin, gate + stale steps.
- [ ] S5. Tests: executed shell tests (temp git repos), gate unit tests, wiring rules + mutants, DP updates. Run all in sandbox.
- [ ] S6. Docs: design (setup order, WIF condition, IAM), test plan (counts, new real-run checks), README, AGENTS, SKILLS Skill 141 + index regen.
- [ ] S7. Push, read CI comment on PR #173, record observed counts here.
