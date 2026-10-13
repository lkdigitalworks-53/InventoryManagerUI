# Test plan — cause of a failed / discarded / parked order completion

**Branch (planned):** `feat/2026-10-13-completion-error-cause` (S1..S3). **Design:** `docs/superpowers/specs/2026-10-13-completion-error-cause-design.md` (decisions Q-EC-1..3 OPEN; this plan assumes the recommended defaults A/A/A).
**STATUS 2026-10-13: written BEFORE implementation. NOTHING run.** Design session, no Qt toolchain (standing rule).
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
