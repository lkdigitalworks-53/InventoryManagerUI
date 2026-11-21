# Test plan: CA-QUESTIONS.md expert review (docs only)

Branch `docs/2026-11-21-ca-questions-review`. Standard format (Skill 49). **Honesty note:** no code changed, so there is nothing to unit-test, no rules or e2e change, and nothing to try on a device. What can be tested is that the docs are complete, consistent with the code they describe, and that the existing guard suites still pass.

## 1. Unit tests
None added (no code). Doc-structure check, RUN in the sandbox: every `### CA-n` block (19) has a research answer, a verdict, a confidence and a "real CA still needed" line; 0 `_(blank)_` answers left; every `[S#]` used exists in section 9.

## 2. Regression tests
Full functions suite RUN 2108/2108 green; `.github` scripts suite RUN 1061/1061 green; `node .github/scripts/skills-index.js --write` run, Skill 180 indexed, no other line changed.

## 3. E2E / 4. Rules
Unchanged (no app, rules or index change).

## Doc-to-code checks (RUN by reading the code, results in the doc's section 10)
Ledger kinds, five mandatory-reason kinds with 3 visible characters, server-stamped cost on six kinds (`functions/lib/movementLogic.js`); ledger write blocked and read limited to owner/admin/manager (`firestore.rules`); fixed IST periods (`qml/helper/StockRegisterModel.js`); damaged return leaves stock unchanged (`qml/model/DataModel.qml` 1366, 1575); no reversal link field on a ledger row; no back-up setup in the repo.

## On-device test plan (Taher)
Nothing to run on a phone. Review steps instead:
### Happy path
1. Read `docs/superpowers/CA-QUESTIONS.md` top to bottom; check each verdict is understandable and the sources open.
2. Decide F1 to F4 of section 8 (the session report lists options and trade-offs).
### Negative
3. Pick any answer you disagree with and say so; the doc is a draft until a real CA has seen the "Yes" items.
### Edge cases
4. Items marked "from my knowledge, not re-verified" (section 9) must go to the CA unchanged.
### Multiple scenarios
5. After S2e-2 is built, replay CA-4 (damaged return), CA-8 (shortage) and CA-13 (delete with stock) as device checks; their expected results are written in those answers.
### Monkey
6. Not applicable to a document.
