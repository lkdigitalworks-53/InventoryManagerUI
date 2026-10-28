# Test plan — cause of a failed / discarded / parked order completion

**Branch:** `docs/2026-10-13-completion-error-cause-design` (PR #139: design, test plan and implementation). **Design:** `docs/superpowers/specs/2026-10-13-completion-error-cause-design.md` (decisions Q-EC-1 A, Q-EC-2 A, Q-EC-3 A taken by Taher 2026-10-13).
**Environment:** dev only, new tenant per PR. **Coverage bar (Taher):** 100% of new/changed code; happy + negative + edge + multi-scenario + monkey. Pure helper cases are Node-runnable in the sandbox (load the helper without its `.pragma` line); QML store/sheet/DataModel cases are CI-only (`tests/`).
**Totals:** **52 automated** = unit 28 + functional 18 + regression 3 + monkey 3 + rules 0 + e2e 0 (counted from the `function test_...` declarations in the six test files), plus the on-device plan (section 6).

## Verification status (what was actually run)
- **Run in the sandbox (2026-10-15):** U14 and U15 plus their neighbours (U11, U12) in Node against `FailureCause.js`, green.
- **Run in the sandbox (PR #139 sweep, 2026-10-14):** the three pure-JS files (`tst_FailureCause`, `tst_StuckWrites`, `tst_DescribeItem`) through a throw-away Node shim: 142 cases green (29 of them new), 6 of 6 mutations caught. Not re-run since.
- **CI only (written, never run in the sandbox):** the additions to `tst_OutboxStore`, `tst_Gateway` (including F06e), `tst_DataModel_completeOrderAtomic`; the sheet row; the `Main.qml` toast. The result is the PR's CI checks.
- **Not written:** e2e. No verified recipe forces a server `write-rejected`, or deletes a record between plan and send, in the emulator; a blind e2e would risk a red CI for the wrong reason. Same gap as the #90 sweep.
- **Not covered by any automated test:** pixels (sheet row layout, toast look). See section 6.
- **Known behaviour left as is:** when the re-plans are exhausted, the order is set to `out of stock` whatever the cause (Skill 118 rule 6; decision D-1 is open). Discard and a queued completion reverted by the server do not do this.

## 1. Unit tests (28 of 52): pure logic, negative and edge inputs
**`tests/tst_FailureCause.qml` (16 of 18)**
| ID | Case |
|---|---|
| U01b | `insufficient-quantity` without a product name has no leading colon |
| U02 | `conflict` -> "Another device changed this at the same time" |
| U03 | `not-found` -> "A record this order needs was deleted on another device" |
| U04 | codes the app should never send are flagged as an app problem and echo the code |
| U04b | `operation-too-large` and `request-id-in-use` each get their own text |
| U05 | unknown code -> generic text, echoes the code only when it is a short safe token |
| U06 | unsafe codes (long, spaces, markup) are never echoed |
| U07 | NEGATIVE: `null`, `undefined`, string, number, array -> generic text, no throw (`forRejection`) |
| U08 | EDGE: a hostile / huge / unicode / empty product name is trimmed and passed through as text only |
| U09 | `write-rejected` says "Usually", never asserts one cause |
| U10 | `write-unavailable` -> temporary; `write-failed` -> unexpected error |
| U11 | `timeout`, plain HTTP status, and no information each map to their own text |
| U12 | the code wins over the status, and is trimmed |
| U13 | NEGATIVE: bad inputs never throw (`forWriteError`) |
| U14 | `no-tenant-context` (HTTP 403) -> "The server no longer accepts your access to this shop. It was most likely removed or suspended. Ask the shop owner or an admin to restore it"; hedged ("may"), the status is not echoed |
| U15 | the code wins over any status, is trimmed; `not-authorized` and a body-less 403 keep the plain "HTTP 403" text; a near-miss code stays unknown |

**`tests/tst_StuckWrites.qml` (9 of 10)**
| ID | Case |
|---|---|
| F01 | `noteFailure` stores the code and status of the latest failure; a later answer replaces it |
| F01b | a timeout is recorded only while online; a missing code is stored as empty |
| F01c | failures that never count as stuck (401, 409, offline timeout) leave no cause |
| F02 | `metaOf` reports the cause, or null for an unknown request |
| F03 | `hydrate` restores a valid cause and ignores a missing or malformed field (old saved items) |
| F03b | a very long code is cut |
| F04 | `prune` forgets the cause with the write; stuck rows carry it |
| F04b | a stuck row without a known cause has null |
| F04c | `metaOf` then `hydrate` round-trips the cause |

**`tests/tst_DescribeItem.qml` (3 of 3)**
| ID | Case |
|---|---|
| F08 | a completion's detail is the customer name, never the first stock batch id |
| F08b | falls back to the order id, then to the first op |
| F08c | malformed ops never throw and never show a batch id as a customer |

## 2. Functional tests (18 of 52): stores, gateway and DataModel (CI only)
| ID | File | Case |
|---|---|---|
| F05 | `tst_OutboxStore.qml` | `setStuckMeta` stores the cause and it survives a relaunch |
| F05b | same | a timeout status is stored |
| F05c | same | a missing or malformed cause is removed, so old items stay byte-identical |
| F05d | same | a later answer replaces the cause; an unchanged one does not save again |
| F05e | same | a very long code is cut; an unknown id returns false |
| F06 | `tst_Gateway.qml` | `stuckRows` cause for a rejected write is the "refused" text |
| F06b | same | cause for a plain 500 names the HTTP status |
| F06c | same | cause for a timeout while online |
| F06e | same | a 403 `no-tenant-context` stuck write shows the access text and is NOT `rejected` (a 403 keeps retrying) |
| F06d | same | the cause is mirrored onto the outbox item and the latest answer wins |
| F07 | same | a write that leaves the outbox leaves no row and no cause |
| F09 | `tst_DataModel_completeOrderAtomic.qml` | exhausted re-plans: the message names the cause of the LAST rejection, no toast |
| F09b | same | an unknown server code is shown as a safe token, not hidden |
| F10 | same | queued, then failed for good: exactly ONE toast signal with the cause |
| F10b | same | without a dispatcher the announcement is a safe no-op |
| F10c | same | a customer-less order is announced by its id |
| F10d | same | a local validation failure announces only for an explicit `null` callback |
| F13 | same | queued, then the product is deleted on this device before the re-plan: one toast with "<name>: not found in inventory" (reachable because `CompletionPlan` checks existence before the clamp) |

## 3. Regression tests (3 of 52 new, plus existing ones that must stay green)
| ID | Case | Why it exists |
|---|---|---|
| U01 | `insufficient-quantity` keeps the established wording and names the product | the stock text moved into `FailureCause`; users must see the same sentence |
| F12 | Discard of a queued completion gives the existing "was discarded" text and NO extra toast | the new toast must not fire for a user's own Discard |
| F12b | a late server conflict that finishes the order gives no toast | the announce-once rule must not fire after success |

Existing tests that must stay green, unchanged: the stock-ran-out message case, the bounded re-plan case, the Discard cases (17-19) in `tst_DataModel_completeOrderAtomic.qml`, and the stuck-sheet strings for a non-completion write.

## 4. Monkey tests (3 of 52)
| ID | Case |
|---|---|
| U16 | seeded, 500 runs: random codes, statuses and shapes never throw and always give a non-empty text |
| F04d | a random cause never breaks the stuck bookkeeping |
| F11 | never more than one toast per finished completion across a random re-plan loop |

## 5. Rules and E2E
Rules: none (no Firestore rules change; the change is client-only, no server change, no deploy). E2E: none written, reason in "Verification status". The device plan below stands in for it.

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
- **Recipe A** (member `inactive`): the server answers a queued completion with HTTP **403** `no-tenant-context`. A 403 is "stuck, still retrying", **not** "Rejected". The cause line is therefore **"The server no longer accepts your access to this shop. It was most likely removed or suspended. Ask the shop owner or an admin to restore it"** (decision D-2, 2026-10-15). The wording "The server refused to save this. Usually a permission change..." belongs to a 500 `write-rejected` and does **not** appear with this recipe.
- **Recipe B** (product deleted): the server answers `not-found`, shown as **"A record this order needs was deleted on another device"**. If the phone has already learned the product is gone, the app stops earlier with **"<product name>: not found in inventory"** instead. Both are correct; you **Record** which one you got.

### Happy path
- [ ] **H1. Online completion, nothing wrong.** Open O1 (`Alice Happy`) and approve it. **Expected:** the order shows completed; no toast; no red caption under the header; Widget A stock is 1 lower than in P5.
- [ ] **H2. Cause visible for a stuck completion (Recipe A).** App open on the Orders list, online. In the console set the manager's `status` to `inactive`. Approve O2 (`Bob Inactive`). **Expected, immediately:** the order shows completed (the write is queued). **Expected, after up to 10 minutes:** the header shows a red underlined line **"1 change(s) not syncing. Still retrying."** Tap it. A sheet titled **"Changes not syncing"** opens with the sentence "These changes are saved on this device. Rejected ones wait until you tap Retry or Discard; the rest keep retrying." The row shows: the customer name **Bob Inactive** (not a code that starts with `B` followed by digits or letters, which would be a stock batch id), the cause line **"The server no longer accepts your access to this shop. It was most likely removed or suspended. Ask the shop owner or an admin to restore it"**, the status line **"Not syncing. Still retrying."**, and a **Retry now** button. There is no "Rejected by the server" text. **Record:** whether a Discard button is visible on this row, and whether the app kept working normally while the member was `inactive`.
- [ ] **H3. Recovery clears the cause.** Set the member's `status` back to `active`. In the sheet tap **Retry now**. **Expected:** toast "Retrying…", then the row disappears, the red caption disappears, O2 stays completed, and Widget A stock is lower by **exactly 1** for O2 (not 2).

### Negative
- [ ] **N1. Product deleted, completion queued offline (Recipe B).** Turn airplane mode ON. Approve O3 (`Cara Deleted`): it shows completed locally. In the console delete `Cause Widget B`. Turn airplane mode OFF. **Expected:** exactly **one** toast that begins **"Order for Cara Deleted was not completed:"** and ends with either "A record this order needs was deleted on another device" or "Cause Widget B: not found in inventory". It does not repeat. O3 no longer shows as completed. **Record:** which ending you got, and O3's status afterwards (the code can leave it `out of stock`, whatever the cause: known, decision D-1 pending, so this is not a failure).
- [ ] **N2. Product deleted, completion online (Recipe B).** Online, open O4 (`Dan Online Deleted`) on its detail screen. In the console delete `Cause Widget C`. Tap approve. **Expected:** a message appears once containing either "Cause Widget C: not found in inventory" or "Could not complete this order: A record this order needs was deleted on another device". O4 is not completed. The approve button works again afterwards (tap it once more: you get the message again, the screen is not frozen). **Record:** where the message appeared (toast, dialog or inline).
- [ ] **N3. Retry while the cause still exists.** Redo H2 until the row is in the sheet, leave the member `inactive`, and tap **Retry now**. **Expected:** toast "Retrying…"; the row stays; the cause line still reads "The server no longer accepts your access to this shop. It was most likely removed or suspended. Ask the shop owner or an admin to restore it" (not blank, not "undefined", not "HTTP 403"); the header caption stays.
- [ ] **N4. Offline is not a server cause.** Airplane mode ON, approve an order from the pending list (use O5 only if you do not need it for E1; otherwise re-create one). **Expected:** the order completes locally; the header shows "App is offline, no operation allowed."; if you open the sheet (after going online and back to this state) it says "Nothing is stuck right now." No row with a cause line appears for an offline wait.

### Edge cases
- [ ] **E1. Very long customer name (80 characters + emoji).** Approve O5 under Recipe A. **Expected:** the sheet row shows the name without overlapping the cause line (it wraps or elides); the header line is unaffected. Then under Recipe B (re-create O5 and Widget A first) the toast text is readable and does not crash. **Record:** whether the toast truncates the name.
- [ ] **E2. Customer left blank.** Approve O6 under Recipe A. **Expected:** the sheet row detail shows the order id (not a stock batch id, not empty). Under Recipe B the toast reads "Order for <order id> was not completed: ...".
- [ ] **E3. Cause survives an app relaunch.** With the H2 row in the sheet and the member still `inactive`, force-stop the app from Android settings, then reopen it online. **Expected:** the red caption returns (it may take one retry cycle); in the sheet the row still shows **Bob Inactive** and the cause **"The server no longer accepts your access to this shop. It was most likely removed or suspended. Ask the shop owner or an admin to restore it"** without needing five new failures. **Record:** how long until the caption came back.
- [ ] **E4. Large font and rotation.** Set the Android font size to the largest, rotate the phone, open the sheet with one stuck row. **Expected:** customer name, cause line and status line wrap without overlapping each other or the buttons.
- [ ] **E5. Known gap I-001 (record only).** Airplane mode ON, approve one order whose product you then delete (Recipe B), force-stop the app, reopen it online. **Record:** is there any message, and what is the order's status? Today a completion queued before a restart has no open entry in memory, so no toast and no cause is expected. This is a known, out-of-scope gap, not a failure of this change.

### Multi-scenario
- [ ] **M1. Two different stuck writes at once (Recipe A).** Member `inactive`. Approve one order, then also edit the name of `Cause Widget A` (any other write). Wait for both to be stuck. **Expected:** the sheet lists two rows, each with its own title/detail; the completion row shows the customer name; both rows show a cause line (every write endpoint answers `no-tenant-context` for an inactive member, so both should read the access text; **Record** it if the edit row shows something else); tapping **Retry now** on one row does not change the other row's text.
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
- A stuck write under Recipe A shows "The server returned an error (HTTP 403)" instead of the access text: the `no-tenant-context` mapping was lost (H2, N3).
- A completion row shows a code that looks like a stock batch id instead of the customer: the order label fix was lost (H2, E2).
- One failed completion gives two toasts, or none: the announce-once rule was lost (N1, K1).
- The cause line is blank or shows "undefined": the cause is not persisted or not mapped (H2, E3).
- After Retry the old cause is still shown when the answer changed: the "latest answer wins" rule was lost (N3).
- A stuck row survives after the write finally succeeded: the cause cleanup was lost (H3, M2).

### Not testable on a device (stated, not hidden)
- The **"Rejected by the server"** row, its wording "The server refused to save this. Usually a permission change, invalid data, or a record deleted elsewhere", the **Retry** and **Discard** buttons on a rejected row, and the text "This order's completion was discarded..." need a server 500 `write-rejected`. Recipe A gives a 403 instead, and no verified recipe forces a `write-rejected`. These are covered by unit and functional cases only (U09, F06, F12), and no e2e exists for the same reason.
