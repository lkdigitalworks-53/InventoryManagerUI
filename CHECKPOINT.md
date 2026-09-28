# CHECKPOINT — 2026-09-28: DELETE-FEATURE-ROADMAP item 1 part C (server write-error classification) — DESIGN PHASE, awaiting Taher's answer to Q-C1, no code yet

**Session date:** 2026-09-28
**Branch:** `fix/2026-09-28-gateway-write-error-classification`, off `main` @ `96c07bd` (PR #92 merged).
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-28-gateway-stuck-write-retry-discard-options-CHECKPOINT.md`
**Skills invoked by Taher:** `superpowers:brainstorming`, `qt-development-skills:qt-qml`, `ponytail:ponytail`, caveman FULL (chat replies only).
**Commit identity:** `Taher (via Claude session) <dextran52@gmail.com>`.

## Steps done
1. Cloned repo, fetched `refs/pull/84/head`. 59 files, +7096/-248, 44 commits. CI on head SHA all green (the 1643-test bot comment is from 09-24 and stale).
2. Ran qml lint on PR-added lines: 112 hits, mostly the repo's `var`/`==` convention. Real ones are in the findings below.
3. Read all new QML, PhotoQueue logic, functions handlers, rules, C++ additions, store diffs.
4. Docs trim: 4 addendum test plans folded into `test-plans/2026-09-21-product-photos-firebase-storage-test-plan.md` (now: root-cause table, gaps F1-F5, one current on-device checklist); README index updated; executed 779-line implementation plan deleted and its 4 references repointed; this file compacted.

- Branch only, never `main`; push without asking (Taher reviews in the PR). PAT only for `git push` / PR API, never written to the repo.
- No build/run of the app, no Qt tooling in the sandbox; CI is the only QML signal. Node tests do run for real in the sandbox (`cd functions && npm ci && npm test`, baseline 251 passing).
- Every code change: tests toward 100% + test plan from template (Skill 49) + `SKILLS.md`/`AGENTS.md`/`README.md` as needed.
- Honest advisor: trade-offs, grill before deciding, do not just agree.
- Small scope per session (token budget); leave a resumable remote branch.

## Step log

1. Read project notes (decisions Q1-Q5 from PR #92). Cloned repo. `main` head = PR #92 merge.
2. Created branch (renamed from the handoff's `2026-09-29` name to today's date). Archived previous CHECKPOINT.
3. Read options doc "If Option 1 is chosen" sketch: map Firestore codes to 4xx (terminal) / 503 (transient) via pure `classifyWriteError` in `functions/lib/`, five catch sites, client reads status.
4. Traced client handling of 4xx before touching anything. **Finding that contradicts the sketch:**
   - `Gateway._classifyDeltaResponse` (`qml/model/Gateway.qml` ~L840): any 4xx with a well-formed `ok:false` body is treated as a definitive server decision, so the write is removed from the outbox and its callback fires. `_sendOperation` (~L925) applies the same rule.
   - So mapping a terminal Firestore error to 4xx on the delta or operation endpoints would make the client DROP the write. That breaks the "client never drops in this PR" decision (Q1).
   - Precedent already in the codebase: `_classifyBatchMutationFailure` (~L730) does NOT trust status alone; it allowlists `body.error` strings (`_terminalBatchErrors`) and deliberately keeps 401/403 retrying.
   - `StuckWrites.isStuckStatus` counts any status >= 400 except 401/409, so 4xx vs 5xx does not change stuck counting either way.
5. Design question Q-C1 raised to Taher: signal channel (HTTP status vs body `error` string). Recommendation: keep status 500 everywhere, add distinct `error` strings, client reads `body.error` (batch precedent). Awaiting answer.

## Open question (blocks design approval)

**Q-C1. How does the server tell the client "terminal" vs "transient"?**
- A. New 4xx/503 statuses (the sketch). Needs client guards in `_classifyDeltaResponse` and `_sendOperation` to stop them dropping; touches two more QML senders; CI-only signal.
- B. (recommended) Status stays 500; new `error` strings (`write-rejected` terminal, `write-unavailable` transient, `write-failed` stays for unknown). Old clients behave identically. Client reads `body.error`. No drop risk. Cost: HTTP status alone no longer separates them in Cloud Logs (the `console.error` still logs the Firestore code).
- C. Add a `terminal: true|false` boolean to the body, status unchanged. Same safety as B but a second field to keep in sync with `error`.

## NEXT (after Q-C1)

1. Finish brainstorming: remaining design sections (mapping table, client label text, tests), spec to `docs/superpowers/specs/2026-09-28-gateway-write-error-classification-design.md`.
2. `superpowers:writing-plans` -> `docs/superpowers/plans/2026-09-28-gateway-write-error-classification.md`.
3. Implement (Node tests real, QML tests CI-only), test plan, `SKILLS.md`, `KNOWN-ISSUES.md`, roadmap status, PR.
4. Then B (park + Retry/Discard). Then item 4 once the photos branch merges.

## Not done

- No code, tests, test plan, or `SKILLS.md`/`AGENTS.md`/`README.md` change yet (design not approved; brainstorming hard gate). Nothing built or run.
