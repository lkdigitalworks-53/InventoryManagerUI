# CHECKPOINT — 2026-10-05 session: PH3b design review (resume here)

**Branch:** `docs/2026-10-05-ph3b-design-review` (off `main` @ `7ec2fc6`). Docs only; no code, no deploy, nothing built or run except the existing functions suite (491/491 green, baseline).
**Commit identity:** `tsadmin <tsadmin@gmail.com>` (user instruction this session), passed per commit with `git -c`, never written to a global config. Push via `/tmp/push.sh` (PAT only in the push header; recreate it if the sandbox reset).
**Standing rules (user, this session):** clone repo each session; branch only; push without asking; no app build/run; no Qt tooling in sandbox (CI = QML signal); small scope, resumable by another account; honest advisor, grill decisions; tests + test plan for every change; update SKILLS/AGENTS/README as needed; terse ("caveman") chat replies.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-05-pr121-final-sweep-CHECKPOINT.md` (its NEXT: read CI on the stacked PR #121 sweep, merge, then PR #121; and Taher to pick a way to force a server rejection for device cases 4.2/4.3/4.4/4.10). Not touched here.

## Task
Next roadmap step after BC1/BC2/PR #121-#122 = **PH3b** (scheduled `pending_cleanup` sweeper). Already designed (v1, 2026-10-01). Reviewed against `main`, updated to v2, made ready for implementation.

## Step log
1. Read skills (brainstorming, ponytail, qt-qml, qt-ui-design), cloned repo, read CHECKPOINT, roadmap, PH3b section, BC design "PH3b implications", `photoCleanup.js`, `index.js` sweep binding, firebase.json, workflows.
2. Classified: architectural-lite (design exists; server-only Node work; no QML/UI, so qt-qml / qt-ui-design have nothing to apply). Review found P1-P10 (spec ledger). Three High: (P1) legacy markers have no `nextAttemptAt` so v1's query never returns them; (P2) the collection-group index cannot reach `dev1`/`test` via `firebase.json`, emulator CI would not catch it; (P3) `updateMarker` `set(merge)` re-creates a deleted marker as a zombie once handler + scheduler overlap.
3. Verified by run/doc: functions suite 491/491; `firebase-functions/v2/scheduler` exports `onSchedule`, `ScheduleFunction.run()` exists; Firebase docs say an unfiltered collection-group query needs no index. NOT verified: scheduler location `asia-south1`, handler default timeout 60 s, emulator index behaviour, `maxInstances` on `onSchedule` at runtime.
4. Design v2 written into `docs/superpowers/specs/2026-09-30-photos-s3-s4-design.md` (PH3b section replaced; v1 in git at `7ec2fc6`). Pushed.
5. Test plan `docs/superpowers/test-plans/2026-10-05-ph3b-scheduled-cleanup-test-plan.md` (unit 45, functional 10, e2e 4, real-project 8; incl. monkey tests, coverage target). README index row added (also fixed a broken link to the photos plan). Docs: AGENTS pointer, KNOWN-ISSUES, roadmap, photos plan note, SKILLS 102.
6. Q-J decided (park at 12) + tick-slack fix. Q-K and Q-L decided (defaults). Merge-readiness pass on the PR: docs-only diff (10 files, 0 non-.md), `main` has not moved since the base, no conflicts, secret scan 0 hits, table columns consistent, relative links valid, row counts re-derived from the test plan (unit 46, functional 10, e2e 4, DV 8), no placeholders. Self-review found and fixed 3 stale statements outside the PH3b section (spec said `firestore.indexes.json` exemption and listed the scheduled function under "Not building"; acceptance lacked PH3b).

## Decisions
- **Q-J DECIDED (Taher, 2026-10-05): park at 12**, delay `min(attempts,3) x 10 min`. Never-park and a shorter cap were offered and declined. Follow-up fix: `DUE_SLACK_MS = 60 s` (without it each wait slips a tick: ~410 min to park instead of ~300). In spec, test plan (US02 changed, US13 added, unit now 46), Skill 102 rule 5.

- **Q-K DECIDED (Taher, 2026-10-05, reverses Q-E): no index.** Due time computed in code, unfiltered collection-group read capped at `MAX_SCAN = 500`. Reopen only if the run logs `backlog:true`.
- **Q-L DECIDED (Taher, 2026-10-05): no alerting now.** Runbook = console query `parked == true` + Logs Explorer severity ERROR. **Production-publish BLOCKER:** add the alert (or re-decide) before any production data exists.

**No open design questions remain for PH3b.**

## NEXT
1. Review and merge PR #124 (docs only, merge-ready).
2. Implement S-A (`lib/photoCleanup.js` pure functions + unit tests, sandbox-runnable), then S-B (index.js `update()` fix + `cleanupPendingMarkers` + harness `update`/`collectionGroup`), then S-C (e2e + docs). One branch per slice, push each.
3. Taher deploys ALL functions manually, records the deploy here, runs section 4 of the test plan.


---
## 2026-10-05 addendum: PR #124 second review (resume here)
Branch `review/2026-10-05-pr124-design-review` (stacked on `docs/2026-10-05-ph3b-design-review`). Docs only; no build/run; CI = signal. Commit identity `taher.lkdw@gmail.com`.
1. Cloned repo, read PR #124 body, spec PH3b section, memory notes. Skills read: requesting-code-review, ponytail-audit; qt-qml-review N/A (no QML).
2. Verified P3 at `functions/index.js:105`, `scopedDb`, `isServerOnlyCollection`.
3. Wrote `docs/superpowers/specs/2026-10-05-pr124-ph3b-design-second-review.md` (R1 Med, R2/R3 Low).
4. User asked: why PH3b, what if skipped (ELI5). Answered in chat.
NEXT: Taher reads review, merges #124 (or answers R1), then S-A.
5. Taher decided: R1 = paged read; Q-L = set up alert. Researched Cloud Monitoring (log-based policy needs rate limit; channels incl. Google Cloud console mobile app; mobile/Slack/PagerDuty share a failure point so keep email). Cannot create the policy (no GCP access): wrote `docs/superpowers/specs/2026-10-05-ph3b-alert-runbook.md`.
6. Updated spec (Q-K/Q-L amended, Paging + Alerting sections), test plan (unit 57, e2e 5, DV 9; UL01-07, UR15-18, E5, DV-9), AGENTS, KNOWN-ISSUES, test-plans README, SKILLS 102 rules 7-8. Pushed to PR #125.
NEXT: Taher merges #124 then #125. Then S-A (`lib/photoCleanup.js` incl. `readAllMarkers`, alert logs, + unit tests). At S-C deploy Taher creates the alert and runs DV-9.
7. Taher asked why a scheduler (vs Firestore-data-plus-code, trigger, queue). Answered in chat; decided: KEEP scheduler (E). Added ledger rows Q-M (Firestore trigger C declined), Q-N (Cloud Tasks D declined), Q-O (client drain B / piggyback A not chosen) to the PH3b decision ledger in the spec, with reasons and reopen conditions.
8. PR #124 squash-merged to main as dc8e901. PR #125 rebased onto main (`git rebase --onto origin/main c95b89c`, no conflicts, tree identical to pre-rebase `e2892d2`), force-pushed with lease, base retargeted to `main`.
