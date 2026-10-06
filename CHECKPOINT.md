# CHECKPOINT — 2026-10-06 session: SKILLS-INDEX + safe doc trim (resume here)

**Branch:** `chore/2026-10-06-skills-index-doc-trim` off `main` @ b455f72 (#129 and #130 merged). Docs/CI-tooling only. NOTHING IS DEPLOYED.
**Commit identity:** `taher.lkdw@gmail.com`. Push with the PAT in the push URL only; never in a file / git config / memory.
**Design:** `docs/superpowers/specs/2026-10-06-skills-index-design.md` (D1-D5, vetoable in the PR).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-05-pr129-final-sweep-CHECKPOINT.md`.

## Plan (tick as done)
- [ ] 1 generator `.github/scripts/skills-index.js` + tests (unit, edge, negative, monkey, repo-state)
- [ ] 2 rename older duplicate `Skill 89` -> `89b`; generate `SKILLS-INDEX.md`
- [ ] 3 AGENTS.md read-order rule; SKILLS.md overview note; README script list
- [ ] 4 trim: README Concurrency blocks that cite an existing Skill; dead refs; false Staff-delete status row
- [ ] 5 test plan + index row, Skill 106, roadmap/README rows
- [ ] 6 push, open PR, CI green, update memory

## Step log
1. Cloned, branch from main, read brainstorming + ponytail skills, scanned SKILLS/AGENTS/README (no exact duplicate long lines; README "Concurrency" = 34 KB dated changelog; 8 dead-looking refs; duplicate `Skill 89`).
