# CHECKPOINT — 2026-10-23 P1 S2a-2: delete `Gateway` direct mode + `mode` property (resume here)

**Branch:** `feat/2026-10-23-p1-s2a2-delete-direct-mode` off `main` @ `d5882ee` (PR #152 + #153 merged). Open the PR against `main`.
**Commit identity:** `taher.lkdw@gmail.com`. PAT only in the push command, never in a file or git config; after push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** do not build/run the app; no Qt in the sandbox (CI is the QML oracle); push without asking, Taher reviews in the PR; short scope (token budget, multi-account hand-off); honest trade-offs; tests + test plan for every code change; caveman FULL.
**Skills used:** `requesting-code-review` + `ponytail-audit` + `qt-qml-review` (PR #152 sweep, done earlier today), `qt-qml`, `ponytail`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-23-p1-s2a1-prev-CHECKPOINT.md`.

## Why this item
Taher chose S2a-2 before S2c ("looks small"). Advice given: it is not small (CI is the only oracle) and S2c closes a real server-side bypass first; Taher kept the order. Direct mode wrote Firestore with no audit_log / ledger rows.

## Steps
- [x] 1. Read memory, cloned repo, confirmed #152/#153 merged, cut branch off `main`.
- [x] 2. Audit: `git grep -c "Gateway\.mode" -- . ':!*.md'` on main = 89 uses in 32 files (recipe said 79 / 22: it missed `test/e2e`). No non-test QML assigned `mode`. Nothing outside Gateway + tests used the two error strings.
- [x] 3. `Gateway.qml`: deleted `mode`, `_writeDirect`, `_writeDirectBatch`, 3 `direct` branches, 4 mode guards, 2 error strings; header comment + 4 doc comments fixed (+11 / -87).
- [x] 4. 3 stale comments fixed (`Main.qml`, `InventoryStore.qml`, `TransactionStore.qml`).
- [x] 5. 30 test files: removed `Gateway.mode = ...` and `_prevMode` save/restore (21 `tests/`, 9 `test/e2e/`).
- [x] 6. `tst_Gateway.qml`: deleted 4 direct-only tests, init block + header SCOPE NOTE rewritten, 3 tests renamed, pin `test_direct_mode_property_is_gone` added.
- [x] 7. Leak audit (Skill 125 rule 2): 6 files run after `tst_Gateway`, write via stores and never set a mode; 2 really enqueue, so `OutboxStore.clear()` added to `cleanup()` in `tst_InventoryStore_upsertMany.qml` and `tst_StockBatchStore.qml`.
- [x] 8. Docs: test plan + index row, Skill 125 + `SKILLS-INDEX.md` (126 skills), AGENTS.md (2), README (3), S2 design note, this file.
- [x] 9. `node --test .github/scripts/__tests__/*.test.js` and `skills-index.js --check` run in session (see PR).
- [ ] 10. **CI:** expect QML 2104 (2107 - 4 + 1), Functions 722, Rules 45, E2E 93. Any other number: read the diff of test counts first.
- [ ] 11. **Taher:** review PR, merge when CI is green, run the on-device list in the test plan.
- [ ] 12. **Next slice, own session:** S2c (lock `inventory` in rules + rules tests), then S2d (kinds on deltas).

## Open items / risks
- Not run anywhere locally: all QML (no Qt). Biggest CI risk: a test file that silently relied on the old leaked `"direct"` state and is not in the 6-file list (the list was found by grep, not proven). If a later-sorting file fails with an outbox count, check `OutboxStore.clear()` in its `init()`.
- Skill 124 rule 3 (`typeof` on an absent singleton member is `"undefined"`) was proven by CI on #152, so the new pin uses the same style.
- Q4 (damaged returns) and Q5 (`valueAtCost` client-stated) stay open for S2e/S2d.

## NEXT
Taher reviews/merges. Then S2c in a new session on a new branch off `main`; before locking `inventory` in rules, grep every client write path to `inventory` (photo fields, import, legacy `photoUrl`) to be sure none bypasses the gateway.
