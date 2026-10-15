# Test plan — Task 11: "Saved. Syncing…" hint for a queued order completion

**Branch:** `feat/2026-10-14-task11-saved-syncing`, stacked on PR #139's branch (`docs/2026-10-13-completion-error-cause-design` @ cbd3363). **Design:** `specs/2026-10-14-task11-saved-syncing-design.md`; SKILLS Skill 120.
**Covers:** `qml/model/DataModel.qml` (`syncingOrderIds`, `completionsSyncing`, `_refreshSyncing`, `_closeOpen`), `qml/pages/OrderDetailDialog.qml` (caption under Status).
**Not covered:** pixels (caption look and position are device-only); orders-list chip, approve-all banner, NewOrderDialog (not built, design D-1).
**Run status:** node guard `.github/scripts/__tests__/completionsSyncingWiring.test.js` run for real (11/11, 9 mutants caught; script suite 105/105). `tests/tst_DataModel_completionsSyncing.qml` (17 cases) is CI-only (no Qt in the sandbox, standing rule). Nothing built or run on a device.

## 1. Unit tests — `tests/tst_DataModel_completionsSyncing.qml`
| Case | Proves |
|---|---|
| initially nothing syncing | count 0, map empty |
| offline completion | count 1 + only that order in the map; 0 after the server confirms |
| online answer in time | never shown; `completionsSyncingChanged` never fires |
| await window runs out (30 ms) | syncing in between, 0 after the answer |
| discard of a queued completion | 0, order back to `pending` |
| reopen while syncing | 0; the late answer cannot bring the hint back |
| late conflict where the order is already completed | 0 |
| queued rejection then clamped re-plan | still exactly one entry for the order |
| re-plans exhausted | 0 (reverted) |
| local validation failure (qty > stock) | never syncing |
| `_closeOpen` of an unknown key | harmless |

## 2. Regression tests
- `test_regression_completion_flow_unchanged_by_the_funnel`: callback, guard and `_openCompletions` behave as before the `_closeOpen` refactor (the existing `tst_DataModel_completeOrderAtomic.qml`, 30 cases, also still must pass: it is the broader regression net for the 6 replaced `delete` sites).
- Node guard: the only raw `delete _openCompletions[` left is the one inside `_closeOpen` (so no future close site can skip the refresh).

## 3. Functional tests (same QML file)
Two orders tracked independently (2 -> 1 -> 0); each change assigns a NEW object and fires `syncingOrderIdsChanged` / `completionsSyncingChanged` (bindings notify); same order counted once; completing an already-completed order adds nothing.

## 4. Monkey tests
`test_monkey_state_always_matches_the_raw_bookkeeping`: 60 runs x 14 random steps over 3 orders (complete, applied answer, discard, rejection, reopen). After every step the map and count equal a recount from `_openCompletions` done independently, and 0 <= count <= 3. Seeded (`20261014`), reproducible.

## 5. Rules tests / E2E
- Rules: none (no data shape, path or rule changed). E2E (`test/e2e`): none added, on purpose; the new state is in-memory UI state, covered by the DataModel tests above. The dialog caption is covered by the source guard.

## On-device test plan
Setup: owner login, a pending order with stock. Build/run is Taher's call. To hold a completion in "queued" you need the app online but the server slow/blocked, or the connection dropped just after tapping Approve (the app disables the UI offline, so "start offline" is not possible).

### Happy path
1. Healthy connection, approve an order: no "Saved. Syncing…" appears (answer arrives inside 10 s). Reopen the order: no caption.
2. Tap Approve, drop connectivity within 1 s: order shows completed. Open it: caption "Saved. Syncing…" under Status. Reconnect: caption disappears once the server answers; stock down exactly once.

### Negative
1. Same as 2, then force a rejection (no verified recipe; see S3 plan): the order reverts to pending, the PR #139 toast names the cause, caption gone.
2. Same as 2, then reopen the order (set status back to pending) before reconnecting: caption gone at once; on reconnect nothing is re-applied (stock unchanged).
3. Same as 2, then Stuck-writes sheet -> Discard: caption gone, order pending.

### Edge cases
1. Approve all pending with 3 orders, drop connectivity mid-run: only orders that were queued show the caption; confirmed ones do not.
2. Open order A (syncing) then order B (not syncing): caption only on A.
3. Relaunch while queued: no caption after relaunch (design D-2: the order is shown as the server has it); header "not syncing" line still applies if stuck.
4. TalkBack: caption read as "Saved. Syncing with the server".
5. Font scale 200%: caption wraps, does not overlap the combo.

### Affected areas
| File | Automated coverage | If not covered, check on device |
|---|---|---|
| `DataModel._onCompletionResult` / `_settleApplied` / `_onCompletionRejected` / `_reverseCompletedOrder` | `tst_DataModel_completionsSyncing.qml`, `tst_DataModel_completeOrderAtomic.qml` | Completion happy path, rejection toast (PR #139) |
| `OrderDetailDialog.qml` | source guard only | Caption position and look; dialog still saves and closes as before |

### Regression tests (run before merge)
Full CI: QML, Functions, Rules, E2E; `node --test .github/scripts/__tests__/*.test.js`.
