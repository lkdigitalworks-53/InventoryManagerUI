# Product picker v2, slice S5g: delete the two dead Auth buttons, prepare the final device pass (S5e-4)

**Date:** 2026-11-25. **Branch:** `feat/2026-11-25-picker-s5g-auth-button-cleanup-and-final-pass`, cut from `main` @ `4ce6a48` (#220 S5f merged). **Test plan:** `test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5g rows, device checks 213 and 214) and the new `test-plans/2026-11-25-picker-v2-s5e4-final-device-pass.md`. **Closes:** KNOWN-ISSUES 146; shrinks 143 (56 to 49). **New:** KNOWN-ISSUES 162.

## 0. Where the roadmap stands (read from the repo and the GitHub API, 2026-11-25)
| Item | State |
|---|---|
| Picker v2 S1 to S5f | MERGED (#185 to #220). The picker CODE is finished (S5f plan section 0 said so; nothing in the repo contradicts it). |
| S5e-4, curated final device pass, KI 29 decided with a number | The only roadmap row left. A PHONE job. No code. Status in the test plan: "PLANNED". |
| Open PRs | #219 (NO3b, atomic-operations roadmap, not picker), #211 (docs), #178 (deps), #39, #29. None touches the picker. |
| Leftovers named by S5f | KI 146 (two dead Auth buttons, Q3 default "yes, own slice"), KI 143 (colour literals), KI 147 (photo sheet unverified on a phone), KI 148, 149. |
| Written device results in the repo | None, for any S5 slice. Slices S5c to S5f changed layout, hit areas and fonts that no one has recorded seeing. |

**What I did NOT find:** a code task inside the picker roadmap. Inventing one would be scope creep. Honest reading: after S5f the right move is the phone pass, and the code I can add in between is cleanup.

## 1. Decisions (each has a default; veto in the PR)

**S5g-D1. Which task this turn?** Options: (a) S5e-4 only, as the document the owner runs; (b) KI 146 only (delete two dead files); (c) KI 143, move 49 colour literals into `Constants` tokens; (d) code a lower cap for a completed order's edit now (KI 29); (e) stop and say "nothing to code".
For (a): it is the roadmap's last row and the one thing that turns 15 slices of "built" into "seen". Against: it produces a document, not code; I cannot run it. For (b): finishes S5f's named follow-up, 83 lines out, 7 literals out, one more ratchet exception gone, tiny and revertable. Against: not a picker feature, it is hygiene. For (c): value only if a second theme is coming; the app has one light palette, the Profile "Appearance" row does nothing (KI 129, 144), and 40 of the 49 literals sit in the two login fields and the photo sheet, files that were just changed and have not been seen on a phone. Churn with a visual-regression risk and no user benefit. Against: KI 143 stays open. For (d): see D4, rejected. For (e): honest but wastes the turn when (a) and (b) are cheap and safe.
**Taken: (a) + (b), as two commits** (A code, B docs), so the cleanup reverts alone. **Rejected: (c) and (d).** Grill: do you plan a dark theme? If no, I recommend closing KI 143 as "won't fix" instead of ever doing it (Q-S5G-3).

**S5g-D2. Delete `AuthPrimaryButton` and `AuthSecondaryButton`?** For: nothing uses them (S5f's reachability scan, plus a tree-wide grep this turn: only test pins, docs and a scanner comment name them); the login screen builds its buttons from `PrimaryButton` and `GhostButton` (S5G-04 pins that); they carry 7 colour literals and an exception in the "named wrappers" ratchet. Against: someone may have meant to reuse them; they look like the intended login buttons. Git keeps them: `git show 4ce6a48:qml/components/AuthPrimaryButton.qml`. **Taken: delete (commit A).** Veto = revert commit A alone; `S5G-01` then fails on purpose and says which file came back. This is S5f's Q3, taken by its stated default because no answer is written anywhere in the repo or the PR.

**S5g-D3. Where do the three ratchet edits go?** The two buttons were named in three tests: `S5E3-29` (the list of components whose root is a raw button, and the `text: root.text` pin), `S5F-03` (the set of unreachable files, now one: `AnalysisService`), `S5E3C-12` (colour literals by file). All three changed in the same commit as the deletion (Skill 190 rule 2). The decoy string in `S5E3-03` (`AuthPrimaryButton { }` as a look-alike type name) stays: it is test input, not a reference.

**S5g-D4. KNOWN-ISSUES 29 (a completed order's edit has no operation cap): code a number now?** Options: (1) measure first (checks F8, F9 in the S5e-4 file), then decide; (2) code a lower line cap for completed edits now (say 30); (3) move `_tryAdjustOrder` onto an atomic operation (the real fix, already on the atomic-operations roadmap as "recommended first among the stock-touching paths", Q-NO3-1).
(2) now: a number without a measurement is a guess. Too low blocks real orders; too high changes nothing; and it is throwaway code if (3) lands (an operation brings its own `MAX_OPS` 200 limit and the dry run already reads it). It also does not fix the real risk: the chain is a per-line sequence with compensations and no transaction, so a dropped connection can leave stock and order disagreeing, at ANY line count above 1. (1) costs two checks and ten minutes of phone time. **Taken: (1).** The S5e-4 file carries a measurement table and a decision rule written BEFORE the result: all rows 10 s or less on a slow network and no partial state (F9) means "measured, no cap needed at 60"; a slow row means the largest row under 10 s is the proposed cap; a partial state means no cap and `_tryAdjustOrder` moves up the atomic arc. The 10 seconds is MY number; Q-S5G-2 asks whether it is yours.

**S5g-D5. Why 20 checks and not 214?** The long plan has 214 numbered checks and the repo holds not one written result. A list nobody finishes teaches nothing. The 20 are chosen by risk: the order flow and stock rule (the money path), the size limits and KI 29 (the unproven path), then the latest unseen UI (dark theme, 2.0x font, photo sheet, toast, TalkBack), then the safety nets (every page opens, monkey). Each check carries the old numbers so nothing is lost. The cost: 194 checks are not in the pass (the ones that are variations of these). Anything they would have caught that F1 to F20 do not is a gap I cannot name from here.

**S5g-D6. What is NOT changed.** No QML behaviour, no wording, no signal, no anchor. `AnalysisService` stays (dormant on purpose). KI 143's other 49 literals, KI 147 (photo sheet on a phone), KI 148 and 149 are untouched. The picker cap and every stock rule are untouched.

## 2. What changed
- Commit A: two QML files deleted (83 lines, 7 colour literals, 2 `QQC.Button` roots). `pickerS5e3Names` (list of 9 roots now 7, pin loop 5 files now 3), `pickerS5fDeadHelpers` (S5F-03 now `AnalysisService` only), `pickerS5e3cAudit` (S5E3C-12 two keys out). New `pickerS5gAuthButtons.test.js` (S5G-01..09).
- Commit B: docs only. This plan, the S5e-4 file, test plan rows, KNOWN-ISSUES (146 closed, 143 shrunk, 162 new), README, AGENTS, Skill 192, the atomic-operations status line, checkpoint.

## 3. Test strategy
Node only (CI is the oracle, no Qt in the sandbox). `S5G-01` the files are gone, from every directory a QML file can live in. `S5G-02` no name in any QML file (comments stripped), `qmldir`, QML test, C++ or CMake. `S5G-03` the matcher on hand-built trees: a real use in a page, a qmldir, CMake and a QML test is found; a comment, a longer name, a shorter name, a prefixed name and an empty tree are not. `S5G-04` regression: `LoginPage` still instantiates `PrimaryButton`, `GhostButton`, `AuthTextField` and `AuthPasswordField`, and those four files exist. `S5G-05` the literals outside `Constants.qml` are exactly 49. `S5G-06` a seeded monkey of 300 trees, a name placed in a random real or decoy position plus a random CMake mention; the matcher count equals the count by construction. `S5G-07..09` (sweep): JS helpers, nested `qmldir`, sub-folder tests; the file-name check over every `qml/` folder; temp trees removed.
**Hand mutants: 11, all killed** (the file restored, a page that names it, GhostButton renamed in the login page, an extra colour literal, a CMake mention, a qmldir line, a stale root pin, a NEW dead file, a QML test that names it, PrimaryButton renamed, an Auth field renamed). Two mistakes of mine on the way, both written down in Skill 192: the first loop left an untracked restored file behind (`git reset --hard` does not remove untracked files), so every later mutant looked killed by the leftover; and my first version of mutant 11 edited the test it was supposed to test. Both redone, baseline run empty first.
**Not run:** CI (read on the PR head), any device check (213, 214, F1 to F20).

## 4. What is NOT done (written down)
- Everything that needs a phone. The whole S5e-4 file is unrun.
- KI 29 has no number (D4).
- KI 143's other 49 literals, KI 147, KI 148, KI 149.
- No QML test changed: nothing in `tests/` loads a Felgo page, so the deletion is covered by source scans only; CI's QML job compiling every `qml/` file is the second net, check 207 and F17 the third.

## 5. Advice
1. **Stop adding slices after this one until F1 to F9 are run.** Fifteen slices have been built, reviewed and merged on source scans, hand mutants and CI. None has a written phone result. The longer the list grows, the more a single phone failure costs to untangle (S5f's commits B and C are layout code nobody has seen).
2. **Run F8 and F9 even if you skip the rest.** They are the only checks that can show a half-applied completed edit, which is a stock-accuracy risk, not a polish item.
3. **Answer Q-S5G-3 honestly.** If no dark theme is planned, KI 143 and KI 144 are churn; the cheap, safe move is to close them.

## 6. Questions for Taher (none block the merge)
- **Q-S5G-1.** Delete the two dead Auth buttons? Default: yes (veto = revert commit A).
- **Q-S5G-2.** Is 10 seconds on a slow network the right bar for a completed-order edit? Default: yes. If not, name yours before you run F8.
- **Q-S5G-3.** Do you plan a dark theme or any second theme? Default: no, so KI 143 and 144 are closed as "won't fix" after the phone pass (not before: F14 may show a real dark-mode defect).
- **Q-S5G-4.** Commit address: this session used `dextran52@gmail.com` (owner instruction 2026-11-25). Older commits carry three other addresses (KI 125).

## 7. Result (2026-11-25)
New Node tests 9 (`S5G-01..09`; 07..09 from the PR review sweep, section 8); functions suite 2414/2414 (main @ `4ce6a48` measured 2408), scripts 1199/1199, `skills-index.js --check` current after Skill 192. Hand mutants 11, all killed. Not run: CI (read on the PR head), any device check.

## 8. PR review sweep (2026-11-26, owner ask: deep review of PR #221, fixes in the same PR, no parallel agents)
**Method (all inline, no subagents, no build):** merged `main` (#219 NO3b landed after the PR was cut: 6 doc conflicts, no code file; ours renumbered KNOWN-ISSUES 150 to 162 and Skill 191 to 192), baseline functions 2443/2443, QML linter on the 8 picker, dialog and login files (500 findings: 156 `ORD-1`, 176 `JS-1`, 63 `BND-2`, 41 `JS-2`, 31 `BND-1`, 18 `DEL-1`, the rest under 6 each), six qt-qml-review domains by hand, ponytail audit of the diff, claims in the PR body checked against git (58 + 25 = 83 lines, 1 + 6 = 7 literals: true).

**Findings, fixed here (code is Node tests only, no QML behaviour changed):**
1. The matcher read only `.qml` files, so a JS helper naming a deleted button by string (`Qt.createComponent`) would have passed. 54 JS files live under `qml/`; none does it today (checked), the guard now reads them. `S5G-07`.
2. A `qmldir` was read only in `components`, `helper`, `model`; tests only at the top of `tests/`. Now every `qmldir` under `qml/` and `tests/` recursively.
3. `S5G-01` listed four folders, not `qml/logic` or the root. Now every folder (`S5G-08`).
4. The tests left 303 `s5g-*` folders in the temp dir per run (300 monkey trees). Now removed after the run, proven 303 to 0 (`S5G-09`).
6 hand mutants (drop JS from the matcher, search one folder only, no-op cleanup, a dead file back in `logic/`, a JS helper naming it, a `qmldir` naming it): 6 of 6 killed, each by the test that owns it.

**Judged, NOT changed (trade-offs):**
- **Mass-fixing the linter's style findings** (332 `ORD-1` order and `JS-1` `var` hits in those files, all pre-existing, KNOWN-ISSUES 149): not done. They change no behaviour, every edit is a blind QML edit (no Qt here), and a review sweep that rewrites 300+ lines hides the 4 real findings. Do it as its own slice with the CI as oracle, or not at all.
- **`S5G-05` repeats `S5E3C-12`** (the per-file literal table already fails on any change): a duplicate that must change in two places. Kept: removing it renumbers `S5G` in ten places for no defect. Delete it together with the next ratchet change.
- **Pin the phone to a light scheme in `main.cpp`:** NOT done. Reasons: Qt is not pinned in `CMakeLists.txt` (the setter exists only from Qt 6.8), CI compiles no C++, and the real effect is unmeasured (KNOWN-ISSUES 142). Decide after check F14.
- **`OrderDetailDialog` delegates read `model.roleName` without `required property`** (linter DEL-1, 18 hits): real for `qmlsc` compilation and type safety, but it is the Edit Order dialog that NO3c will edit next. Fold it into NO3c, where its tests and device pass already exist.

**Owner facts recorded:** all picker slices tested on a device (no result lines in the repo, KNOWN-ISSUES 164); no second theme planned: KNOWN-ISSUES 143 is WON'T FIX, but 142 (the phone's own dark mode) and 144 (contrast) are NOT closed by that.

**Questions for Taher (defaults taken, none block the merge):**
- Q-S5G-5 F8 and F9 numbers: what did you see? Default: unknown, KI 29 stays open, no number invented.
- Q-S5G-6 keep `S5E3C-12` after the won't-fix? Default yes (it blocks NEW literals for free).
- Q-S5G-7 is F14 (dark phone) on your list? Default: it must be, because "no theme" does not stop a phone in dark mode.

**Measured by running (2026-11-26, merged tree, after the fixes):** functions 2446/2446 (2443 on the merged tree before, +3), scripts 1199/1199, `skills-index.js --check` current (193 skills). Not run: CI (read after the push), any device check.
