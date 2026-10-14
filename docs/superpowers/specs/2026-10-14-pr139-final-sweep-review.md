# PR #139 final sweep (2026-10-14)

Scope: PR #139 tip `34d356f` (design + implementation of "show WHY an order completion failed", #140 merged in), 24 files, +814/-55. Method: `superpowers:requesting-code-review` (template `code-reviewer.md`, run inline: no subagent tool in chat), `qt-development-skills:qt-qml-review` (Phase 1 linter run, `qmllint` absent, six agent missions run inline), `ponytail:ponytail-audit` (scoped to the PR's files). Review fixes: stacked PR on branch `review/2026-10-14-pr139-final-sweep`.

## 1. Code review (requesting-code-review format)

### Strengths
- Cause text lives in one pure helper, never throws, always returns non-empty `text`, echoes a server code only when it is a short plain token (`FailureCause.js:_safeCode`). Probed in Node: hostile or garbled codes fall back to the generic text.
- Wording never over-claims: a 500 `write-rejected` says "Usually", because the server keeps only the error class.
- `lastError` is validated on read (`StuckWrites.cleanLastError`), pruned with the item, and old saved items load without it.
- Rejections that reach `_noteFailure` are only 5xx / timeout (4xx from our own code is terminal and handled by `_classifyDeltaResponse`), so the stuck sheet's `forWriteError` and the DataModel's `forRejection` never compete for the same answer. Checked against `operationLogic.js` statuses (400/404/409) and `isStuckStatus`.
- One toast per finished completion, none while a re-plan is still out, none when the caller is still waiting. The Discard path stays silent on purpose.
- Tests are real behaviour (real Gateway + OutboxStore, seeded monkey counting signals).

### Issues
#### Critical (must fix): none.
#### Important (should fix)
1. **Order is flagged `out of stock` whatever the cause** (`DataModel.qml` `_onCompletionRejected` exhausted branch, `markOutOfStock = true`). A `conflict` or `not-found` now shows the right cause text ("Another device changed this...") next to the wrong status. Documented as "left as is" (Skill 118 rule 6), so it is a **decision**, not a slip. Needs Taher (see section 4).
2. **A doc claim was wrong and the branch had no test** (test plan "Unreachable branch"). Reachable via `Widget: not found in inventory` (CompletionPlan checks existence before the clamp). FIXED: test F13, plan corrected, Skill 119.
3. **Duplicate validator** (`OutboxStore.setStuckMeta` re-implemented `StuckWrites.cleanLastError`; Skill 118 rule 3 says one validator). FIXED, behaviour identical (7 probe cases in Node incl. 100-char code, NaN, "timeout", non-string code).
4. **Duplicate wording** (`DataModel` typed "stock ran out before this order could complete" again next to `FailureCause`). FIXED: calls `FailureCause.forRejection`, text byte-identical, existing assertions unchanged.
#### Minor
5. `callback === null` (answered) vs `undefined` (no callback) is a fragile contract. All four production callers pass a callback, so latent only; pinned by F10d and Skill 118 rule 2. Left.
6. Cause strings are not `qsTr` (helper is `.pragma library`). The repo ships no `.ts` files, so no loss today. Left.
7. Toast = `qsTr("Order for %1 was not completed:") + " " + cause`: fine in English, will need a full-sentence key when translations arrive. Left.

### Assessment
**Ready to merge? With fixes** (items 2-4 done in the review PR; item 1 is Taher's call and does not block merge if he accepts the documented behaviour).

## 2. QML review (qt-qml-review format)

**Scope:** files `qml/Main.qml`, `qml/logic/Logic.qml`, `qml/model/{DataModel,Gateway,OutboxStore}.qml`, `qml/pages/StuckWritesSheet.qml` + JS helpers. **Files reviewed:** 9 prod + 6 tests. **qmllint:** not available (no Qt in sandbox, by rule).

**Phase 1 lint:** 561 raw hits on the touched files, 9 on lines this PR added: 8 x `JS-1` (`var`, the repo-wide convention: 752 hits in the files alone) and 1 x `ORD-1` at `StuckWritesSheet.qml:105` (same pattern as 6 neighbouring rows on `main`). **0 actionable lint findings.**

**Deep analysis (six missions, inline):**
| Mission | Result |
|---|---|
| Bindings & properties | `cause` is a plain value in the `rows()` array, no new binding, no loop. Sheet reads `row.modelData.cause.length`: safe, `stuckRows()` always sets `cause` and the sheet is its only consumer. |
| Layout & anchoring | New `Text` uses `Layout.fillWidth` + `WordWrap` inside the existing ColumnLayout, `visible` bound to `cause.length > 0 && !inFlight`; no sizing feedback. |
| Loading & lifecycle | `Connections { target: logic }` handler `onOrderCompletionReverted` sits in the existing block with `onOrderCompletionFailed`. `dispatcher` null-guarded. No createObject. |
| ListView & delegates | No new delegate property or model role. |
| States & structure | No states/transitions touched. Modern `function onX()` handler syntax used. |
| Performance & quality | `stuckRows()` re-runs `forWriteError` per row per re-evaluation (cheap string switch, rows are few). `Text` default format is `AutoText`, so a cause containing `<` could be parsed as rich text: causes are fixed strings plus a safe token or a product name; the product name is the only free text, and it goes to a Toast (plain) and the order/sheet detail (existing behaviour). |

**Investigation targets (human verification needed)**
- **I-001 (conf 65)** `DataModel.qml:600` `_openCompletions` is in memory by design. After an app restart, a completion queued before the restart and rejected later has no open entry, so no toast and no cause. Pre-existing and outside this PR's decisions (Q-EC-3 persists the cause for the stuck sheet only). *How to verify:* device: complete an order offline, force-stop the app, reopen online with the product deleted elsewhere, watch for any message and the order status.
- **I-002 (conf 60)** `StuckWritesSheet.qml:105` `Text` format. *How to verify:* a product named `<b>x</b>` in a stuck completion row: does the detail line render bold? (Cause line is safe either way.)

**Summary:** Lint 0 / Deep 0 / Investigate 2 / Total 2.

## 3. Audit (ponytail-audit format)

**What this repo does:** Karobar, a Qt/QML inventory + orders app on Firebase, writes go through a queue (outbox) and Cloud Functions. Load assumed: one shop, a handful of devices, a few hundred writes a day. Audited: only the 24 files of this PR and the code they call.

### Must fix
None.

### Should fix
1. **Order says "out of stock" for a reason that is not stock** (`qml/model/DataModel.qml:L798-803`, `_completeAttempt` L699-700)
   - **What this is:** When an order cannot be completed after 3 retries, the app marks the order `out of stock` and now also tells the person why.
   - **Problem:** The why can be "Another device changed this" or "A record was deleted". The status still says `out of stock`, so the screen contradicts itself, and the order is treated as an out-of-stock order elsewhere (filters, retry flow).
   - **Fix:** Mark `out of stock` only when the cause kind is `stock`; leave the order `pending` otherwise. A few lines, plus 2 test updates (`test_replan_bound_is_exactly_maxReplans` asserts `out of stock` after a `conflict`). NOT applied: it changes the status machine, so it is Taher's decision.
   - **If we skip it:** Wrong status on a rare path; the toast and message are right, so staff are not misled about the cause.
2. **Branch without a test: queued completion whose product vanished** (`DataModel.qml:L697-700`) FIXED, test F13.
3. **Same save/load check written twice** (`OutboxStore.qml:L524-528` vs `StuckWrites.js:cleanLastError`) FIXED.
4. **Same sentence typed twice** (`DataModel.qml:L796` vs `FailureCause.js:L30`) FIXED.

### Nice to have
5. `forWriteError` + `forRejection` each repeat the `kind/text` object shape. Not worth a helper.

**Verdict:** Healthy. Merge after CI is green on the review PR; decide item 1.
**Lean:** -5 lines (net after fixes: -2 prod lines, +1 test), -0 dependencies.
**Not checked:** QML runtime behaviour (no Qt in the sandbox: `tst_Gateway`, `tst_OutboxStore`, `tst_DataModel_completeOrderAtomic`, the sheet and the Toast are CI/device only); Cloud Functions beyond the status mapping; the 21 doc-only files beyond the numbers and claims cited.

## 4. Decision for Taher (grill)
**D-1: status of an order whose completion failed for a non-stock cause.**
- **A keep `out of stock` (today).** No code change, no risk to filters. Cost: wrong label next to a right message; staff may restock needlessly.
- **B (recommended) `pending` unless the cause kind is `stock`.** Honest status, order is retryable at once. Cost: a persistent cause (product deleted) now fails again on every Retry instead of looking terminal; you lose the "needs attention" colour unless something else shows it. Also touches 2 existing tests.
- **C new status (`failed`).** Cleanest data. Cost: new status through every filter, badge, report, rules and export: far too big for this PR.
Why B over A: the whole PR exists so the person is told the truth; a label that contradicts the message undoes that. Why not C yet: no evidence the case is frequent.
