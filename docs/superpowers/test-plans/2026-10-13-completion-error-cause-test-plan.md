# Test plan — cause of a failed / discarded / parked order completion

**Branch:** `feat/2026-10-13-completion-error-cause` (S1..S3 in one PR, stacked on design PR #139). **Design:** `docs/superpowers/specs/2026-10-13-completion-error-cause-design.md` (decisions Q-EC-1 A, Q-EC-2 A, Q-EC-3 A taken by Taher 2026-10-13).
**STATUS 2026-10-13 (implemented, same session): see "Implementation status" at the end. Originally written before implementation.**
**Environment:** dev only, new tenant per PR. **Coverage bar (Taher):** 100% of new/changed code; happy + negative + edge + multi-scenario + monkey. Pure helper cases are Node-runnable in the sandbox (load `FailureCause.js` without its `.pragma` line); QML store/sheet/DataModel cases are CI-only (`tests/`).

**Totals (planned):** unit 16 + functional 12 + rules 0 + e2e 2 + regression 4 = **34 automated**, plus the device plan.

## 1. Unit: `tests/tst_FailureCause.qml` (S1, pure) — 16
| ID | Case |
|---|---|
| U01 | `forRejection` `insufficient-quantity` with a name -> "<name>: stock ran out..." |
| U02 | `conflict` -> "changed on another device" text |
| U03 | `not-found` -> record deleted elsewhere text |
| U04 | `invalid-entity-id`, `unsupported-kind`, `cascade-delete-not-allowed`, `too-many-ops` each map to their own text |
| U05 | `request-id-in-use` -> generic duplicate text |
| U06 | unknown code -> generic text, kind `unknown`, no throw |
| U07 | `forWriteError("write-rejected", 500)` -> refused text, kind `rejected`, wording says "usually" |
| U08 | `write-unavailable` -> temporary, still retrying |
| U09 | `write-failed` -> unknown failure, still retrying |
| U10 | status `timeout` / 0 with no code -> "no answer from the server" |
| U11 | NEGATIVE: `null`, `undefined`, string, number, array inputs -> generic, no throw (all 3 functions) |
| U12 | EDGE: huge / unicode / empty product name is passed through unchanged, trimmed, never concatenated into code paths |
| U13 | `orderLabel(item)` picks the `order` op's customer when present |
| U14 | `orderLabel` falls back to the order id, then to "" (never a batch id) |
| U15 | `orderLabel` with `ops` missing, empty, or not an array -> "" |
| U16 | MONKEY (seeded, 500 runs): random codes/statuses/shapes never throw and always return a non-empty `text` |

## 2. Functional (CI only) — 12
| ID | File | Case |
|---|---|---|
| F01 | `tst_StuckWrites.qml` | `noteFailure` stores `lastError` {code,status}; a later answer replaces it |
| F02 | `tst_StuckWrites.qml` | `metaOf` returns `lastError`; unknown request -> none |
| F03 | `tst_StuckWrites.qml` | `hydrate` restores `lastError`; missing / malformed field ignored (old saved items) |
| F04 | `tst_StuckWrites.qml` | `prune` forgets `lastError` with the item |
| F05 | `tst_OutboxStore.qml` | `setStuckMeta` persists `lastError` and a reload returns it |
| F06 | `tst_Gateway.qml` | `stuckRows()` carries `cause` text for a parked completion; sheet row for a non-parked write unchanged |
| F07 | `tst_Gateway.qml` | a successful retry (item leaves the outbox) clears the cause |
| F08 | `tst_DescribeItem.qml` | completion row detail is the order label, never `stock_batch` id |
| F09 | `tst_DataModel_completeOrderAtomic.qml` | P1: exhausted re-plans -> message uses the cause of the LAST rejection |
| F10 | same | P2: queued completion later rejected for good -> exactly ONE error toast signal, order back to `pending` |
| F11 | same | P2 re-plan loop: toast fires once per finished completion, not once per attempt |
| F12 | same | P5 regression: Discard still gives the existing "was discarded" text and NO extra toast |

## 3. E2E (emulator, CI) — 2
E01 online completion that the server rejects (record deleted in the emulator between plan and send) -> failure text names the cause. E02 park a completion via a rejected write, relaunch (reload OutboxStore), cause still shown.

## 4. Regression — 4
R01 `insufficient-quantity` text unchanged (existing case 3). R02 case 5 bounded re-plans unchanged. R03 S3 Discard cases 17-19 unchanged. R04 stuck sheet strings for a non-completion stuck write unchanged.

## 5. On-device (after CI green, only when Taher asks to build)
Happy: complete online -> no toast. Negative: delete a product in the web/other device, complete an order containing it offline, reconnect -> toast names the cause, order pending. Edge: very long customer name in the toast and in the sheet row (elide). Multi-scenario: two parked writes with different causes, each row shows its own. Relaunch: kill the app with a parked completion, reopen sheet, cause still there. Monkey: toggle airplane mode while completing 5 orders in a row; no duplicate toasts, guard released, no row stuck "being completed".


## Implementation status (2026-10-13)
**Built:** S1 `qml/helper/FailureCause.js`, S2 stuck path (`StuckWrites`, `OutboxStore.setStuckMeta`, `Gateway.stuckRows`, `StuckWritesSheet`, `DescribeItem`), S3 `DataModel` + `Logic.orderCompletionReverted` + `Main.qml` toast. Client-only, no server change, no deploy.
**Actually written (49 automated, +F13 from the PR #139 sweep):** unit `tests/tst_FailureCause.qml` 16 (U01..U16 re-numbered as in the file) / `tst_StuckWrites.qml` +10 (F01-F04d) / `tst_DescribeItem.qml` +3 (F08-F08c, replaces planned U13-U15, `orderLabel` lives in `DescribeItem`) / `tst_OutboxStore.qml` +5 (F05-F05e) / `tst_Gateway.qml` +5 (F06-F07) / `tst_DataModel_completeOrderAtomic.qml` +10 (F09, F09b, F10, F10b, F10c, F10d, F11 monkey, F12, F12b, F13).
**Genuinely RUN in the sandbox:** the three pure-JS files (`tst_FailureCause`, `tst_StuckWrites`, `tst_DescribeItem`) through a throw-away Node shim that evaluates the helper `.js` files and the test bodies: 142 cases green (113 before this change: 29 new, 0 regressed); 6 mutations all caught (drop the `lastError` write, drop prune, hydrate trusting input, ignore the order op, echo unsafe codes, loosen the status gate). `.github/scripts` skills-index tests 21/21. NOT run: `tst_OutboxStore`, `tst_Gateway`, `tst_DataModel_completeOrderAtomic` additions, the sheet row, the `Main.qml` toast (CI / device only).
**Not written:** e2e E01/E02. No verified recipe forces a server `write-rejected` or a record deleted between plan and send in the emulator; a blind e2e would risk a red CI for the wrong reason. Open item, same as the #90 sweep's "no recipe to force write-rejected".
**Reachable branch (corrected in the PR #139 sweep, 2026-10-14):** the first version of this plan called `_completeAttempt`'s `callback === null` announce unreachable. It is reachable: a queued completion is rejected, the product is deleted on this device before the re-plan runs, and the clamped re-plan fails with `<name>: not found in inventory` (CompletionPlan checks existence before the clamp). Covered by F13 in `tst_DataModel_completeOrderAtomic.qml` (CI only). F10d still pins the explicit-null contract.
**Known behaviour left as is:** the exhausted-re-plan branch still sets the order to `out of stock` whatever the cause (Skill 118 rule 6); the plan's "order stays pending" holds for Discard and for a queued completion reverted by the server, not for that branch.
**Device steps added (unticked):** section 5 above, plus: after a parked completion, the sheet row shows the customer name (not `B...` batch id) and the cause line; relaunch keeps the cause line.
**CI round 1 (2026-10-13):** Functions 626, Rules 45, E2E 93 green; QML 2025/2026, the one failure was `tst_FailureCause::compile` (a variable named `long`, reserved in QML's JS parser; Skill 116 rule 7). Fixed in the next commit.

