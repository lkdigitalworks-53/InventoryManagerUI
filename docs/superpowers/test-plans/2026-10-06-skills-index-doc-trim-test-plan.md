# Test plan — SKILLS-INDEX.md (generated) + provable doc trim

**Branch:** `chore/2026-10-06-skills-index-doc-trim` off `main` @ b455f72. **Design:** `../specs/2026-10-06-skills-index-design.md` (D1-D5).
**Covers:** `.github/scripts/skills-index.js`, generated `SKILLS-INDEX.md`, rename of the older duplicate `Skill 89` to `89b`, the read-order rule in `AGENTS.md`, and the README/AGENTS trim. No QML, Functions, Rules or E2E code touched.
**Not covered:** the app. Nothing here ships to a device.

## 1. Unit (`.github/scripts/__tests__/skills-index.test.js`, 21 tests; whole script suite 76/76; `skills-index.js` 100% line / branch / function)
| Group | What |
|---|---|
| Happy | one line per heading in file order, full title kept (backticks, `->`, quotes); header carries the `awk` and `grep` usage; the documented `awk` one-liner returns exactly one skill, including `89b` and an unknown id (empty) |
| Edge | empty file; `#`, `###`, `####` and `## Overview` are not skills; headings inside ``` and ~~~ fences are ignored; CRLF and trailing spaces; letter-suffixed ids |
| Negative | duplicate id names both lines and suggests `5b`; malformed headings (dash, empty title, word instead of number, plural) are errors, never silently dropped; stale index and hand-edited index fail with the `--write` command in the message; heading errors are not double-reported as "stale" |
| Functional | CLI `--write` then `--check` round trip; missing / hand-edited index exits 1; duplicate id exits 1 and writes no file; no flag exits 2; the real entry point (`require.main`) exits 0 on this repo and 2 on an unknown flag |
| Monkey | 5 seeds x 200 random lines (headings, fences, malformed headings, noise): index equals the expected list, deterministic |
| Repo-state (the live guard) | `SKILLS-INDEX.md` equals what `SKILLS.md` generates; every `## Skill` id in the file is in the index (nothing hidden) |
Mutation check (run, then discarded): turning the duplicate check off makes 3 of the new tests fail (negative duplicate, double-report, `--write` refusal).

## 2. Regression / provable-trim checks (run once, results in the PR)
- Before: 106 skills, 1 duplicate id (`89`). After: 106 unique ids, index 11.5 KB vs `SKILLS.md` 306 KB (about 96% fewer tokens to read first).
- README cut rule: a block goes only if it cites an existing Skill AND at least 85% of its backticked identifiers occur in that Skill's text AND it has at least 7 identifiers. 5 of 25 blocks passed (9,019 bytes). The other 20 stay; scores are listed in the PR.
- Dead references: the never-committed code-review spec path is removed from AGENTS and SKILLS; the stale "staff row-level delete button missing" status row is corrected (`StaffPage.qml` has `deleteStaffBtn`).

## 3. E2E
None. The next CI run of any PR executes the repo-state tests.

## On-device test plan
Not applicable (docs and CI tooling). Sections kept for the convention:
- **Happy path:** start a new session with only the index; open one skill with the `awk` line from the index header; it prints exactly that skill.
- **Negative:** on a scratch branch rename a skill heading without regenerating: CI "Script tests" fails with the `--write` command in the message.
- **Edge cases:** add a skill whose title contains a backtick or `->`; regenerate; the index line is verbatim.
- **Multiple scenarios:** two parallel PRs each add a skill: the second to merge gets a one-line conflict in `SKILLS-INDEX.md`; resolve by running `--write`, never by hand.
- **Monkey:** covered by the seeded test.
- **Regression watch:** a session that skips `grep SKILLS-INDEX.md` before touching an area (the risk accepted in design D1).
