# Design — SKILLS-INDEX.md (generated) + safe doc trim (2026-10-06)

**Problem.** `SKILLS.md` is 305 KB (~75k tokens) and is read in full at every session start. Taher works on a free plan across several accounts, so that read eats the budget before any work starts.
**Decision (Taher approved the idea 2026-10-06; details below are defaults, veto in the PR).**

| # | Question | Options | Chosen | Why |
|---|---|---|---|---|
| D1 | Who writes the index lines? | hand-written one-liners / generated from `## Skill N:` headings | **generated** | Hand-written lines can drift and can hide a skill (the risk Taher asked about). Headings already are one-line lessons. Zero double edits. |
| D2 | Stop drift how? | CI step / a test in the existing script-test job | **test** (`node --test .github/scripts/__tests__/*.test.js` already runs on every PR) | No workflow edit; failure message says the fix command. |
| D3 | Line numbers or sizes in the index? | yes / no | **no** | They change on every edit above them and cause merge conflicts between parallel account sessions. An `awk` one-liner in the header reads one skill by id instead. |
| D4 | Duplicate skill id (two `Skill 89`) | renumber to 107 / suffix `89b` / leave | **suffix `89b`** on the older one | Docs cite both as "Skill 89"; a new number would need rewrites in history docs. The generator now FAILS on duplicate ids so it cannot recur. |
| D5 | Doc trim rule | trim by judgement / only provable cuts | **only provable cuts** | A block is removed only if it cites a Skill that exists (lesson kept elsewhere) or a path that does not exist. Everything else is listed in the PR as "candidates, not done". Git history keeps every removed byte. |

**Components.** `.github/scripts/skills-index.js` (`buildIndex`, `checkIndex`, CLI `--write` / `--check`), `SKILLS-INDEX.md` (output), tests, AGENTS.md read-order rule, SKILLS.md overview note, README script list.
**Error handling.** Duplicate id, malformed `## Skill` heading, id inside a code fence (ignored on purpose) are the edge cases; stale index exits 1 with the fix command.
**Out of scope.** Splitting SKILLS.md into files; rewriting AGENTS.md status prose (medium confidence only).
