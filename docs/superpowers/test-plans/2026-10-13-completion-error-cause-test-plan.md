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

## 6. On-device test plan

**Who runs it:** Taher, after CI is green on the PR tip and he decides to build (nothing here is run by Claude; the sandbox has no Qt and no device).
**What it proves:** the cause text people see when an order completion fails or a write is stuck, on a real Android phone against the dev Firebase project. Everything else is covered in sections 1-5.
**How to record:** tick the box per step. Where a step says **Record**, write what you actually saw in a PR comment; that is not a pass/fail, it settles a behaviour the code cannot tell us in advance.

### Prerequisites (do all before step H1)
| # | Prerequisite | Detail |
|---|---|---|
| P1 | Build | CI green on the PR tip. Taher builds and installs the app on one Android phone ("Device A"). Device A is online. |
| P2 | Account | A **fresh test tenant** (new user + new tenant, as for every PR). On Device A log in as a **manager**, not the owner. Reason: you will flip this member's status to `inactive` in Firestore. Doing that to the owner would lock the tenant's owner out. |
| P3 | Console | Firestore console for the dev project, open in a browser, signed in with edit rights. Note the `tenantId` and the manager's `uid` (document `tenants/<tenantId>/members/<uid>`, field `status`, normally `active`). |
| P4 | Settings | Auto-approve is **OFF**, so new orders stay `pending` until you approve them. |
| P5 | Products | Create `Cause Widget A`, `Cause Widget B`, `Cause Widget C`, each with stock **100** and enough price/batch data to sell. Write down the stock after creating. |
| P6 | Orders | Create these orders, each with ONE line, status `pending`: **O1** customer `Alice Happy`, Widget A x1. **O2** `Bob Inactive`, Widget A x1. **O3** `Cara Deleted`, Widget B x1. **O4** `Dan Online Deleted`, Widget C x1. **O5** customer = an 80-character name (for example `Long Customer ` repeated until 80 characters, ending in an emoji), Widget A x1. **O6** customer left blank, Widget A x1. **O7..O11** `Monkey 1`..`Monkey 5`, Widget A x1 each. |
| P7 | Console edits | Recipe A (server refuses): set `tenants/<tenantId>/members/<uid>.status` to `inactive`. Recipe B (record deleted elsewhere): delete the product's document in the console (find it by name in the tenant's inventory collection). |
| P8 | Reset (between scenarios) | Set the member's `status` back to `active`. Wait until the red caption under the header is gone (each stuck write retries with backoff, so this can take a few minutes). If a row is still in the sheet after 10 minutes, open it and tap **Discard**, then confirm. Re-create any deleted product with the same name and stock. Re-create orders you need again. |
| P9 | Timing | A write counts as stuck after its **5th** failed send, with backoff in between. Allow up to **10 minutes** for the red caption after Recipe A. If nothing appears after 10 minutes, mark the step FAIL and note the elapsed time. |

### What Recipe A and Recipe B produce (read before testing)
- **Recipe A** (member `inactive`): the server answers a queued completion with HTTP **403** `no-tenant-context`. A 403 is "stuck, still retrying", **not** "Rejected". The cause line is therefore the generic **"The server returned an error (HTTP 403)"**. The wording "The server refused to save this. Usually a permission change..." belongs to a 500 `write-rejected` and does **not** appear with this recipe.
- **Recipe B** (product deleted): the server answers `not-found`, shown as **"A record this order needs was deleted on another device"**. If the phone has already learned the product is gone, the app stops earlier with **"<product name>: not found in inventory"** instead. Both are correct; you **Record** which one you got.

### Happy path
- [ ] **H1. Online completion, nothing wrong.** Open O1 (`Alice Happy`) and approve it. **Expected:** the order shows completed; no toast; no red caption under the header; Widget A stock is 1 lower than in P5.
- [ ] **H2. Cause visible for a stuck completion (Recipe A).** App open on the Orders list, online. In the console set the manager's `status` to `inactive`. Approve O2 (`Bob Inactive`). **Expected, immediately:** the order shows completed (the write is queued). **Expected, after up to 10 minutes:** the header shows a red underlined line **"1 change(s) not syncing. Still retrying."** Tap it. A sheet titled **"Changes not syncing"** opens with the sentence "These changes are saved on this device. Rejected ones wait until you tap Retry or Discard; the rest keep retrying." The row shows: the customer name **Bob Inactive** (not a code that starts with `B` followed by digits or letters, which would be a stock batch id), the cause line **"The server returned an error (HTTP 403)"**, the status line **"Not syncing. Still retrying."**, and a **Retry now** button. There is no "Rejected by the server" text. **Record:** whether a Discard button is visible on this row, and whether the app kept working normally while the member was `inactive`.
- [ ] **H3. Recovery clears the cause.** Set the member's `status` back to `active`. In the sheet tap **Retry now**. **Expected:** toast "Retrying…", then the row disappears, the red caption disappears, O2 stays completed, and Widget A stock is lower by **exactly 1** for O2 (not 2).

### Negative
- [ ] **N1. Product deleted, completion queued offline (Recipe B).** Turn airplane mode ON. Approve O3 (`Cara Deleted`): it shows completed locally. In the console delete `Cause Widget B`. Turn airplane mode OFF. **Expected:** exactly **one** toast that begins **"Order for Cara Deleted was not completed:"** and ends with either "A record this order needs was deleted on another device" or "Cause Widget B: not found in inventory". It does not repeat. O3 no longer shows as completed. **Record:** which ending you got, and O3's status afterwards (the code can leave it `out of stock`, whatever the cause: known, decision D-1 pending, so this is not a failure).
- [ ] **N2. Product deleted, completion online (Recipe B).** Online, open O4 (`Dan Online Deleted`) on its detail screen. In the console delete `Cause Widget C`. Tap approve. **Expected:** a message appears once containing either "Cause Widget C: not found in inventory" or "Could not complete this order: A record this order needs was deleted on another device". O4 is not completed. The approve button works again afterwards (tap it once more: you get the message again, the screen is not frozen). **Record:** where the message appeared (toast, dialog or inline).
- [ ] **N3. Retry while the cause still exists.** Redo H2 until the row is in the sheet, leave the member `inactive`, and tap **Retry now**. **Expected:** toast "Retrying…"; the row stays; the cause line still reads "The server returned an error (HTTP 403)" (not blank, not "undefined", not a different sentence); the header caption stays.
- [ ] **N4. Offline is not a server cause.** Airplane mode ON, approve an order from the pending list (use O5 only if you do not need it for E1; otherwise re-create one). **Expected:** the order completes locally; the header shows "App is offline, no operation allowed."; if you open the sheet (after going online and back to this state) it says "Nothing is stuck right now." No row with a cause line appears for an offline wait.

### Edge cases
- [ ] **E1. Very long customer name (80 characters + emoji).** Approve O5 under Recipe A. **Expected:** the sheet row shows the name without overlapping the cause line (it wraps or elides); the header line is unaffected. Then under Recipe B (re-create O5 and Widget A first) the toast text is readable and does not crash. **Record:** whether the toast truncates the name.
- [ ] **E2. Customer left blank.** Approve O6 under Recipe A. **Expected:** the sheet row detail shows the order id (not a stock batch id, not empty). Under Recipe B the toast reads "Order for <order id> was not completed: ...".
- [ ] **E3. Cause survives an app relaunch.** With the H2 row in the sheet and the member still `inactive`, force-stop the app from Android settings, then reopen it online. **Expected:** the red caption returns (it may take one retry cycle); in the sheet the row still shows **Bob Inactive** and the cause **"The server returned an error (HTTP 403)"** without needing five new failures. **Record:** how long until the caption came back.
- [ ] **E4. Large font and rotation.** Set the Android font size to the largest, rotate the phone, open the sheet with one stuck row. **Expected:** customer name, cause line and status line wrap without overlapping each other or the buttons.
- [ ] **E5. Known gap I-001 (record only).** Airplane mode ON, approve one order whose product you then delete (Recipe B), force-stop the app, reopen it online. **Record:** is there any message, and what is the order's status? Today a completion queued before a restart has no open entry in memory, so no toast and no cause is expected. This is a known, out-of-scope gap, not a failure of this change.

### Multi-scenario
- [ ] **M1. Two different stuck writes at once (Recipe A).** Member `inactive`. Approve one order, then also edit the name of `Cause Widget A` (any other write). Wait for both to be stuck. **Expected:** the sheet lists two rows, each with its own title/detail; the completion row shows the customer name; both rows show a cause line (the edit's cause may use a different code, but with Recipe A both read "The server returned an error (HTTP 403)"); tapping **Retry now** on one row does not change the other row's text.
- [ ] **M2. Five completions stuck together (Recipe A).** Member `inactive`. Approve O7..O11. **Expected:** after the 5th failed send each, the header reads "5 change(s) not syncing. Still retrying." and the sheet lists five rows, one per `Monkey n` customer, each with the cause line. Restore `status` to `active`, tap **Retry now** on each row. **Expected:** all rows clear; Widget A stock is lower by **exactly 5** in total (once per order).

### Monkey
- [ ] **K1.** With Recipe A active, approve O7..O11 as fast as you can, then for 2 minutes: toggle airplane mode on/off about 10 times, rotate the phone, send the app to the background and back, and open and close the sheet quickly. **Expected:** no crash; no order produces two toasts; no row is stuck on "Sending…" for good; no row has an empty customer name or empty cause line; the caption count equals the number of rows in the sheet. Then restore `active` and retry everything: all rows clear and stock is deducted once per order.
- [ ] **K2.** Flip the member between `inactive` and `active` in the console five times, about 20 seconds apart, while you approve orders. **Expected:** every completion either goes through exactly once or ends up in the sheet with a cause; none is lost and none is applied twice (check Widget A stock against the number of completed orders).

### Affected areas
| File | Automated coverage | If not covered, check on the device |
|---|---|---|
| `qml/helper/FailureCause.js` (new) | 16 QML cases, run in Node | n/a |
| `qml/helper/StuckWrites.js` (`lastError`) | 10 QML cases, run in Node | H2, E3 |
| `qml/helper/DescribeItem.js` (customer label) | 3 QML cases, run in Node | H2, E2, M1 |
| `qml/model/OutboxStore.qml` (`setStuckMeta` persists cause) | 5 QML cases, CI only | E3 |
| `qml/model/Gateway.qml` (`stuckRows` cause) | 5 QML cases, CI only | H2, N3, M1 |
| `qml/model/DataModel.qml` (completion failure text, one toast) | 10 QML cases, CI only | N1, N2, K2 |
| `qml/Main.qml` (toast on `orderCompletionReverted`) | none (needs the full app) | N1, E1, E2 |
| `qml/pages/StuckWritesSheet.qml` (cause line) | none (needs the full app) | H2, N3, E4, M1, M2 |
| `qml/logic/Logic.qml` (signal) | none (declaration only) | N1 |

### Regression: how you would notice it came back
- A completion row shows a code that looks like a stock batch id instead of the customer: the order label fix was lost (H2, E2).
- One failed completion gives two toasts, or none: the announce-once rule was lost (N1, K1).
- The cause line is blank or shows "undefined": the cause is not persisted or not mapped (H2, E3).
- After Retry the old cause is still shown when the answer changed: the "latest answer wins" rule was lost (N3).
- A stuck row survives after the write finally succeeded: the cause cleanup was lost (H3, M2).

### Not testable on a device (stated, not hidden)
- The **"Rejected by the server"** row, its wording "The server refused to save this. Usually a permission change, invalid data, or a record deleted elsewhere", the **Retry** and **Discard** buttons on a rejected row, and the text "This order's completion was discarded..." need a server 500 `write-rejected`. Recipe A gives a 403 instead, and no verified recipe forces a `write-rejected`. These are covered by unit and functional cases only (U09, F06, F12), and no e2e exists for the same reason.
- Open decision for Taher (not part of this PR): with Recipe A the person sees "The server returned an error (HTTP 403)", which does not say that their access was changed. A clearer sentence for `no-tenant-context` would need a change in `FailureCause.js` plus tests.


## Implementation status (2026-10-13)
**Built:** S1 `qml/helper/FailureCause.js`, S2 stuck path (`StuckWrites`, `OutboxStore.setStuckMeta`, `Gateway.stuckRows`, `StuckWritesSheet`, `DescribeItem`), S3 `DataModel` + `Logic.orderCompletionReverted` + `Main.qml` toast. Client-only, no server change, no deploy.
**Actually written (49 automated, +F13 from the PR #139 sweep):** unit `tests/tst_FailureCause.qml` 16 (U01..U16 re-numbered as in the file) / `tst_StuckWrites.qml` +10 (F01-F04d) / `tst_DescribeItem.qml` +3 (F08-F08c, replaces planned U13-U15, `orderLabel` lives in `DescribeItem`) / `tst_OutboxStore.qml` +5 (F05-F05e) / `tst_Gateway.qml` +5 (F06-F07) / `tst_DataModel_completeOrderAtomic.qml` +10 (F09, F09b, F10, F10b, F10c, F10d, F11 monkey, F12, F12b, F13).
**Genuinely RUN in the sandbox:** the three pure-JS files (`tst_FailureCause`, `tst_StuckWrites`, `tst_DescribeItem`) through a throw-away Node shim that evaluates the helper `.js` files and the test bodies: 142 cases green (113 before this change: 29 new, 0 regressed); 6 mutations all caught (drop the `lastError` write, drop prune, hydrate trusting input, ignore the order op, echo unsafe codes, loosen the status gate). `.github/scripts` skills-index tests 21/21. NOT run: `tst_OutboxStore`, `tst_Gateway`, `tst_DataModel_completeOrderAtomic` additions, the sheet row, the `Main.qml` toast (CI / device only).
**Not written:** e2e E01/E02. No verified recipe forces a server `write-rejected` or a record deleted between plan and send in the emulator; a blind e2e would risk a red CI for the wrong reason. Open item, same as the #90 sweep's "no recipe to force write-rejected".
**Reachable branch (corrected in the PR #139 sweep, 2026-10-14):** the first version of this plan called `_completeAttempt`'s `callback === null` announce unreachable. It is reachable: a queued completion is rejected, the product is deleted on this device before the re-plan runs, and the clamped re-plan fails with `<name>: not found in inventory` (CompletionPlan checks existence before the clamp). Covered by F13 in `tst_DataModel_completeOrderAtomic.qml` (CI only). F10d still pins the explicit-null contract.
**Known behaviour left as is:** the exhausted-re-plan branch still sets the order to `out of stock` whatever the cause (Skill 118 rule 6); the plan's "order stays pending" holds for Discard and for a queued completion reverted by the server, not for that branch.
**Device steps added (unticked):** section 5 above, plus: after a parked completion, the sheet row shows the customer name (not `B...` batch id) and the cause line; relaunch keeps the cause line.
**CI round 1 (2026-10-13):** Functions 626, Rules 45, E2E 93 green; QML 2025/2026, the one failure was `tst_FailureCause::compile` (a variable named `long`, reserved in QML's JS parser; Skill 116 rule 7). Fixed in the next commit.

