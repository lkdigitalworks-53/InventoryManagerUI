# CHECKPOINT — 2026-09-29: DELETE-FEATURE-ROADMAP item 1 part B — S1 (PR #97, CI green, awaiting merge) + S2a (persist stuck state, P5) IMPLEMENTED, CI PENDING

**Branches:** S1 `feat/2026-09-29-stuck-writes-dialog-retry-now` (PR #97, off `main` @ `1a81554`, P5 docs PR #98 already merged into it). **S2a `feat/2026-09-29-s2a-persist-stuck-state`, stacked on the S1 branch** (retarget its PR to `main` after #97 merges; expect a small rebase if #97 is squash-merged).
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-29-gateway-park-retry-discard-scope-CHECKPOINT.md`.
**Skills invoked by Taher:** brainstorming, qt-qml, qt-ui-design, ponytail; caveman FULL (chat replies only).
**Commit identity:** `Taher <taher.lkdw53@gmail.com>` (Taher's claude.ai account email, per his instruction 2026-09-30; earlier commits on this branch used other addresses).

## Standing instructions (unchanged)

Branch only, push without asking (PAT only in the push URL, never in `.git/config` or the repo), no build/run, no Qt tooling in the sandbox (CI is the QML signal), tests toward 100% + test plan + SKILLS/AGENTS/README, honest advisor, small scope per session.

## Step log

1. Read memory + plan doc (`2026-09-29-gateway-park-retry-discard-plan.md`), roadmap, test-plan README. Cloned repo, stripped the PAT from `origin`, archived old checkpoint.
2. Traced `OutboxStore`, `StuckWrites.js`, `Gateway` (`_noteFailure`, `_pruneStuck`, `drainNow`, `_send` no-auth guard), `GlassHeader`, `Main.qml` back-button list, `BottomSheet`, `NotificationsSheet`.
3. Wrote: `DescribeItem.js`; `StuckWrites.isStuck/rows`; `OutboxStore.retryNow/isInFlight/inFlightCount`; `Gateway.stuckRows/retryStuck`; `StuckWritesSheet.qml`; `Main.qml` wiring; `GlassHeader` tap.
4. Tests: new `tst_DescribeItem.qml`; extended `tst_StuckWrites`, `tst_OutboxStore`, `tst_Gateway` (42 new cases).
5. Ran in Node (not Qt): pure-JS test files 51/51 + 40/40; real `OutboxStore.qml` function bodies via a mirror 57/57. Found and fixed 2 test bugs. `tst_Gateway.qml` NOT executed.
6. Docs: design doc (D1-D8), test plan + index row, roadmap + plan status, AGENTS, README, SKILLS Skill 85. Pushed.
7. PR #97 on-device review (Taher): forced a stuck write (temp wrong `functionUrl`), dialog showed; stuck list did NOT survive relaunch. Confirmed intentional in S1 (in-memory `_stuckState`; write itself survives in `OutboxStore`). Found the test-plan setup line is wrong (a rules change cannot fail a Functions write: Admin SDK bypasses rules; emulator down = status 0 = offline, not stuck). Working setups: member `status` inactive -> 403 `no-tenant-context`, or temp wrong `functionUrl` -> 404.
8. **Decision P5 (Taher):** S2 persists the stuck flag for ALL stuck writes, amending P1's persistence scope (park stays terminal-only). Docs only, on stacked branch `docs/2026-09-29-s2-persist-stuck-decision` (base = PR #97's branch): plan (P5 row, alternatives, open S2 questions a-d), S1 design "Next", roadmap. No code.
9. Taher answered the P5 questions: (a) persist failure count too, (b) make stuck items due once at launch, (c) Claude's choice, (d) show header line at launch. Recorded in the plan (S2 split into S2a persistence / S2b park, overrulable). PR #98 merged into #97's branch; #97 CI all green, `mergeable_state` clean, not yet merged.
10. **S2a code:** `StuckWrites.metaOf/hydrate`; `OutboxStore.setStuckMeta/wakeStuck` (+ item shape doc); `Gateway.resumeStuck` (once per launch, `_stuckResumed`, re-armed by `clear()`), `_noteFailure` calls `resumeStuck()` first then mirrors to the item; `Main.qml` calls `Gateway.resumeStuck()` before the first `drainNow()` in `onTenantContextReady`. (c) decided: `terminal` is persisted. No toast at launch. `attempts` not reset by the wake.
11. **S2a tests:** 16 `tst_StuckWrites`, 18 `tst_OutboxStore`, 16 `tst_Gateway` (incl. 3 monkeys). Node-ran the pure-JS logic incl. relaunch monkey: 1217 assertions OK. `tst_OutboxStore` / `tst_Gateway` NOT run (need Qt).
12. Lint: no real new findings (the extra JS-2 / ORD-1 hits are linter false positives on `!==` and nested `function rnd()`; the extra BND-2 is the existing `items = arr` idiom). `Main.qml` shows a paren imbalance in the checker, present at `HEAD` too (checker quirk); my edit adds one balanced pair.
13. Docs: test plan `2026-09-29-stuck-state-persist-s2a-test-plan.md` + index row, plan (a)-(d) resolved, roadmap, SKILLS Skill 88 (was 86 before rebase), AGENTS, README. Pushed, PR opened stacked on #97.
14. **Rebase onto `main` (2026-09-30, Taher's request):** `main` moved to `13375cf` (PR #99, photo follow-ups). Rebased PR #97 (linearised; merge commits of #100/#103 replaced by their underlying commits). Conflicts: `SKILLS.md` (main already had Skills 85 + 86 from PR #99 -> kept both, renumbered this branch's retry-now skill 85 -> **87** and S2a's stuck-flag skill 86 -> **88**; README pointer updated to 88), `CHECKPOINT.md` (kept this branch's version, per Taher). `AGENTS.md` / `README.md` auto-merged. No `.qml`/`.js` conflicts. Nothing executed (no build, no Qt). Pushed with `--force-with-lease`.

15. **PR #97 on-device finding (Taher, 2026-09-30):** suspended member, restock a product -> waiting list showed, survived relaunch. Member set active, Retry now -> batch created, **product stock NOT increased**. Root cause by code reading (NOT reproduced, NOT verified on device, pre-existing, not caused by S1/S2a): `InventoryStore.restock` fires TWO independent writes in parallel, `StockBatchStore.addBatch` (`recordMutation`, `_send`) and `Gateway.recordDelta` (`_sendDelta`). Server answers a suspended member with 403 `{ok:false,error:\"no-tenant-context\"}` on both. `_send` treats any non-2xx non-conflict as retryable -> batch stays queued and stuck. `_classifyDeltaResponse` treats 4xx + `ok:false` as a definitive rejection -> delta is `markSent` (dropped), callback gets `{ok:false}`, restock shows \"Could not restock\" and never records ActivityLog/purchase. Retry now later lands only the batch: ledger has qty, `product.stock` does not. Fix NOT started; awaiting Taher's decision (options in chat). Still to confirm on device: Firestore `stock` unchanged, and a \"Could not restock\" toast appeared at restock time.

16. **Taher's answers + decision (2026-09-30):** toast \"Could not restock\" was seen, Firestore `stock` unchanged -> step 15 root cause confirmed by device evidence. **Decision: restock's batch + stock delta must become ONE atomic operation (`recordOperation`, new opType). Document it and leave it: NO code in PR #97.** Documented on separate branch `docs/2026-09-30-restock-atomic-operation` (off `main`, KNOWN-ISSUES.md). S1 test plan got a caution: force the stuck write with a product-name edit, not Restock.

17. **Final-sweep review (2026-09-30, Taher's request):** requesting-code-review + qt-qml-review + ponytail-review run on S1+S2a (single manual pass, no subagents in chat). No Critical/Important. Fixed 2 nits (AGENTS Skill ref 86 -> 88, `Main.qml` comment order). 3 investigation targets + 2 ponytail notes left for device check / later. Details: `docs/superpowers/specs/2026-09-30-pr97-review-CHECKPOINT.md`. Review PR stacked on #97; merge it, then merge #97 as a merge commit.

## Deviation from the plan (for Taher to overrule in the PR)

Retry now keeps the stuck flag (design D1) instead of dropping it from `StuckWrites` state. Reason: silent 3-minute window after a rejected retry. S2's Retry (parked items) uses the plan's original wording.

## NEXT SESSION — start here

1. Merge order: #97 first (CI green, clean), then the S2a PR (retarget to `main`; CI on S2a is the first real run of the 50 new cases). Likely trouble spots on S2a CI: `tst_Gateway.qml` new relaunch cases (real singleton graph, `_relaunch()` helper resets `_stuckResumed`), `tst_OutboxStore` `setStuckMeta` JSON-compare no-op test, monkey tests.
2. Taher on-device: run section 3 of `docs/superpowers/test-plans/2026-09-29-stuck-state-persist-s2a-test-plan.md` (setups: member `status` inactive -> 403, or temp wrong `functionUrl` -> 404).
3. Then **S2b only** (park terminal writes: `parked`/`parkedAt`, no auto-retry, `dueItems` skips parked; header/dialog show parked; Discard is S3). New branch off `main` after S2a merges. Opens with the brainstorming gate. Do not combine slices.
4. Done 2026-09-30: S1 test plan section 3 setup corrected (suspended member -> 403, or wrong `functionUrl` -> 404; new tenant each test). Docs PR stacked on #100.
5. No migration for S1-queued stuck writes (Taher, 2026-09-30): S1 never ships alone and every PR is tested on a new tenant, so no stuck writes exist at the start of a test.
6. Merge plan (Taher's call, 2026-09-30): merge the S2a PR (#100) into #97's branch and continue from there, one merge to `main`. Keep it a merge commit (not squash) so S1 and S2a stay separately revertable.
