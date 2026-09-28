# CHECKPOINT — 2026-09-28: DELETE-FEATURE-ROADMAP item 1 part C (server write-error classification) — IMPLEMENTED, PR raised, awaiting Taher's review; QML tests CI-only

**Session date:** 2026-09-28
**Branch:** `fix/2026-09-28-gateway-write-error-classification`, off `main` @ `96c07bd` (PR #92 merged).
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-28-gateway-stuck-write-retry-discard-options-CHECKPOINT.md`
**Skills invoked by Taher:** `superpowers:brainstorming`, `qt-development-skills:qt-qml`, `ponytail:ponytail`, caveman FULL (chat replies only).
**Commit identity:** `Taher (via Claude session) <dextran52@gmail.com>`.

## Standing instructions (unchanged)

Branch only, push without asking, PAT never written to the repo, no build/run, no Qt tooling in sandbox (CI is the QML signal; Node tests run for real), tests toward 100% + test plan + SKILLS/AGENTS/README, honest advisor, small scope per session.

## Step log

1. Read notes, cloned repo, created branch, archived previous checkpoint. Pushed checkpoint-only branch.
2. Traced client 4xx handling: `_classifyDeltaResponse` / `_sendOperation` drop a write on any 4xx with an `ok:false` body. The sketched 4xx/503 mapping would have made the client drop poison writes. Asked Taher (Q-C1).
3. **Taher chose B:** status stays 500, body `error` = `write-rejected` / `write-unavailable` / `write-failed`.
4. Server: `functions/lib/writeError.js`, five catch sites in `functions/index.js`. Node: 8 + 10 new tests, suite 269 pass (baseline 251). Committed and pushed (`1266f82`).
5. Client: `StuckWrites.js` (`REJECTED`, `errorCodeOf`, `terminalCount`, 5th arg to `noteFailure`, prune), `Gateway.qml` (`stuckTerminalCount`, `_noteFailure(item, status, body)` at four call sites, reset in `clear()`), `Main.qml` (`syncStuckTerminalCount`), `GlassHeader.qml` (caption text). `StuckWrites.js` logic smoke-checked in Node.
6. QML tests: +14 `tst_StuckWrites.qml`, +10 `tst_Gateway.qml` (CI only, not run here).
7. Docs: design+plan spec, test plan, SKILLS Skill 74, KNOWN-ISSUES, roadmap status, README, AGENTS.
8. Committed, pushed, opened PR.

## Watch in CI

- `tst_StuckWrites`, `tst_Gateway`: 24 new test functions, never run. If red, read `results.xml`, not the code.
- `GlassHeader` nested ternary in `qsTr`: rendering is on-device only.

## NEXT SESSION — start here

1. Check the PR's CI result and Taher's review comments; fix if red.
2. Then part B (park + Retry/Discard), decisions Q2-Q4 in the options doc: re-pull on Discard, persisted parked flag, tappable caption -> dialog. Needs its own brainstorm/spec/plan; per-store refresh path for Party / Category / OrderChannel and the operation sender; Discard disabled offline (proposed).
3. Item 4 (photo cleanup on delete): on-device check once the photos branch merges.

## Not done

- Nothing built or run. QML tests not run. No persisted terminal flag (belongs to B). Mixed-case caption names only the rejected count (documented ceiling).
