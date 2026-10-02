# CHECKPOINT — photos PH3 (server cascade + hardening), implementation (2026-10-03)

**Branch:** `feat/2026-10-03-photos-ph3-server` (off `main` @ `af2d5b1`, PR #108 merged). **Commit identity:** `dextran52@gmail.com` (Taher's instruction this session).
**Skills invoked by Taher:** qt-qml, qt-ui-design, brainstorming, ponytail; caveman FULL (chat only). qt-qml / qt-ui-design: no QML in PH3 (server only), nothing to apply. Brainstorming gate: design approved in PR #108 (Q1-Q15), no new decision needed.
**Design:** `specs/2026-09-30-photos-s3-s4-design.md` (file is named s3-s4, content = PH3/PH4/PH5). **Test plan:** `test-plans/2026-09-30-photos-s3-s4-s5-test-plan.md`.
**Not this workstream:** root `CHECKPOINT.md` (stuck-writes S3). Not touched.
**Rules:** branch only; push without asking (PAT only in the push header, never in `.git/config` or the repo); no build/run; no Qt tooling (CI is the QML/rules/e2e signal); Node tests CAN run in the sandbox; small scope; honest advisor.

## Step log
1. Read memory, skills, cloned repo, read design + test plan + PR #108 review checkpoint. Next priority item = **PH3** (server). PH3b blocked on Q-I, PH4/PH5 after PH3.
2. Baseline: `cd functions && npm ci && node --test` = 347 pass, 0 fail.
3. Read `index.js` (recordMutation, upload/deletePhoto, deriveContext), `gatewayLogic.applyMutation`, batch/ops validators, handlerHarness, firestore.rules.

## Deviations from the design (decided here, flagged for review)
- `isCascadeEntityDelete` lives in the NEW leaf module `functions/lib/photoCleanup.js` (design said `gatewayLogic.js`, test plan said `photoCleanup.js`). Reason: batch/ops would otherwise need a new import of gatewayLogic internals; a leaf module avoids a cycle.
