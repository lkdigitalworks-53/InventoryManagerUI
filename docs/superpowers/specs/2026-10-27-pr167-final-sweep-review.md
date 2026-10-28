# Final-sweep review of PR #167 (sign-out guard, S0)

**Date:** 2026-10-27. **Reviewed:** `feat/2026-10-26-signout-guard` @ `8a3904b` (2 commits, 15 files, +998 / -52). **Review branch:** `review/2026-10-27-pr167-final-sweep`, stacked on it.
**Skills:** `requesting-code-review`, `ponytail:ponytail-audit`, `qt-development-skills:qt-qml-review`.
**How it was done, honestly:** one reviewer, one pass. This chat has no subagent tool, so the six parallel qt-qml-review agents were NOT launched; I covered their six areas by reading (listed below). There is no Qt in the sandbox: no `qmllint`, no `qmltestrunner`. CI is the QML oracle.

**What this repo does:** Inventory Manager is a Felgo/Qt phone app for small shops (products, stock, orders) backed by Firebase and Cloud Functions. Writes go into a local queue (the outbox) and a photo queue first, then sync. This PR warns the person before signing out or leaving a workspace throws that queue away.
**Load assumed:** one shop, a few people, a queue of tens of items; a bad day is hundreds.

## Result
**0 must fix. 4 should fix (all four fixed in this review PR). 4 nice-to-have or open questions.** The code is correct on every path I traced. The risk is not in the logic, it is in what protects it from the next change, and in one dependency on another PR.

## Should fix

1. **Title keeps warning after the queue is empty** (`qml/pages/SignOutSheet.qml:L33`, now fixed)
   - **What this is:** The sheet is live. When the last item syncs, the body says "Everything has synced. Nothing will be lost." and the red button becomes plain "Sign out".
   - **Problem:** The title was fixed text: "Sign out with unsynced work?". So the person sees a warning title over a "nothing will be lost" body.
   - **Fix:** The title follows `_guard.count` like the buttons already did. Done: "Sign out?" / "Leave workspace?" when empty. Test-plan row E1 now says so.
   - **If we skip it:** A confusing sheet in exactly the moment the design wanted to be reassuring.

2. **Nothing stops a new caller from skipping the guard** (`qml/Main.qml`, `qml/model/AuthService.qml`; test added)
   - **What this is:** `askLeave` is the one chokepoint. The design says `signOut(` has exactly two call sites. That was checked once, by hand.
   - **Problem:** `Main.qml` and the sheet cannot run under `qmltestrunner`, so no test checks the routing. Next month someone adds `AuthService.signOut()` to a new button and queued work is lost again, silently. Also, if `OutboxStore.revision` is renamed, QML does not fail at load: the member reads as `undefined` and the sheet just stops updating.
   - **Fix:** Added `.github/scripts/__tests__/signOutGuardWiring.test.js` (repo precedent: `ordersPageApproveWiring.test.js`). 43 tests: routing of the 3 entry points, the exact list of `signOut(` callers (also none in `src/` or `main.cpp`), the sheet's Stay-is-primary and double-tap guard, the live watchers, and every store member the sheet and helper read. 31 mutants, one per rule. Fix-revert: 6 red on the original sheet, 43/43 green now. Skill 138.
   - **If we skip it:** The guard erodes the first time someone forgets it, and CI stays green.

3. **The "nothing replays under the next account" promise depends on a PR that is not in this one** (`design D-S0-5`, test plan H4 and monkey row; docs fixed, merge order is yours)
   - **What this is:** The design says the pending batch-id mint queue is not in the sheet and "fixed in the stacked PR".
   - **Problem:** That fix (`fix/2026-10-26-pending-mints-tenant-scope`, `feea99f`) is a separate, unmerged branch, not an ancestor of #167. On `main` today, `StockBatchStore.clear()` only empties `batches`; `_pendingMints` survives sign-out and is not tagged with a tenant. Case: offline restock, mint fails, queued; sign out, sign in to tenant B, go online: a stock batch for A's product id is written into B. The sheet's last line, "Data stored on this device is also cleared.", is not true for that queue, and H4 ("nothing from the old session replays") fails on a device until that PR lands.
   - **Fix:** Merge that PR first (best), or at least before the on-device rows that queue a restock. Design D-S0-5, the test plan prerequisite and the README now say this. I did not touch that branch.
   - **If we skip it:** Cross-tenant data written by a restock queued before a sign-out; and a device test that fails for a reason that is not this PR's bug.

4. **Doc slips that would mislead the next session** (fixed)
   - Skill 136 rule 1 cited "Skill 133" for the pending-mint work. On `main`, Skill 133 is "list the open PRs that edit a shared server file"; on the mint branch the skill is 137. Now cited by title.
   - Test plan said "36 test functions + 4 data functions"; it is 36 with 3 data-driven (33 plain + 5 + 6 + 9 data rows = 53, so the 53 was right). It also said the branch was cut from `b494d52`; the merge-base is `9c010f0`.

## Nice to have / open questions (not changed)

5. **The summary is rebuilt on every outbox change even while the sheet is closed** (`SignOutSheet.qml:L28-L31`)
   - **Problem:** The `_guard` binding depends on `OutboxStore.revision`, so it runs `SignOutGuard.build` over the WHOLE queue on each enqueue and ack, before slicing to 5 rows. Measured in Node: 2.4 ms per 1000 items, 18 ms per 5000 (the phone's engine is slower, maybe several times). Negligible at tens of items; a long offline day with hundreds is still fine.
   - **Fix:** Compute only while the sheet is visible. I did NOT apply it: it cannot be tested here, and a wrong guard on `visible` would flash "Everything has synced" for one frame at open, which is the worst message to show. Revisit if queues over 1000 become realistic.

6. **Photo `retrying` is "Waiting", outbox `stuck` is "Needs attention"** (`SignOutGuard.js:L35-L40`, D-S0-3)
   - **Problem:** D-S0-3 says a write that keeps failing but is still retrying is "not syncing", so it is `attention`. A photo that keeps retrying says "Waiting" forever. Not a bug: one failed upload also says `retrying`, and an outbox item is only `stuck` after 5 server failures. But the two are not treated alike.
   - **Question for Taher (Q-R1):** should a photo with many attempts count as `attention` after the same threshold? My lean: yes, but only if you see people hit it. The photo item already carries `attempts`, so a threshold needs no new field; the cost is one more rule and one more test row.

7. **Items queued during the Leave-workspace round-trip are discarded without a warning** (`AuthService.leaveCurrentTenant`, `qml/Main.qml` Leave handler). Confidence 65, not verified.
   - **Problem:** `askLeave` counts at the tap. `leaveCurrentTenant` then does network reads and writes (seconds on a bad network) before `signOut()` clears the queue. An edit made in that window is not in what the person was warned about.
   - **How to verify:** test-plan row E10. If it bites, the smallest fix is a busy state on the Profile page while the leave runs, not a second sheet.

8. **Red text is below WCAG AA contrast** (`Constants.danger` `#ef4444`, used by the sheet's red button label and the "Needs attention" tag)
   - **Problem:** `#ef4444` on white is 3.76:1; AA needs 4.5:1 for text this size (14 px bold, 11 px bold). The state is also in words, so it is not colour-only (the design's rule is met), but it is hard to read for low vision. The token is app-wide.
   - **Fix:** Change the token in its own PR (for example `#b91c1c`, 6.47:1) and look at every use. Not this PR.

## What I checked and found correct
- **Every symbol exists:** `OutboxStore.revision / inFlightCount / isInFlight / items`, `PhotoQueue.revision / items`, `InventoryStore.getById`, the `Constants` tokens, `GhostButton.textColor`. `_inFlightKeys` is replaced, never mutated in place, so `inFlightCount` really notifies.
- **Item fields match the stores:** `opType` and `ops` (OutboxStore L305-306), `terminal` / `stuck` / `failures` (`StuckWrites.isParkedItem`), the four photo states.
- **Routing:** `signOut(` has two call sites in `qml/`, none in `src/` or `main.cpp` (the design had not checked C++). The TenantSetupPage path routes through `askLeave` with no title: nothing queued means it signs out at once, as before. Leave workspace is hidden for owners (`ProfilePage.qml` L255).
- **Double tap:** the destructive button's handler nulls `_proceed` before calling it, and `onClosed` drops it, so a second tap during the exit animation does nothing.
- **Back / tap outside / X mean Stay:** `closePolicy` is Escape + PressOutside; `signOutSheet` is first in `_handleBack`.
- **Build:** `CMakeLists.txt` globs `qml/*.qml` and `qml/*.js` with `CONFIGURE_DEPENDS`; `qmltestrunner -input tests` discovers the new test. No registration was missed.
- **Helper never throws:** 20 000 seeded runs of JSON-shaped junk (null, nested nulls, `__proto__`, `constructor` as op type, NaN failure counts, throwing and non-string lookups, odd `maxRows` and `opts`): 0 throws, count / rows / more invariants held. This matters: a guard that threw would stop the person from signing out at all.
- **qt-qml-review areas, by reading:** bindings (no loop; `_guard` reads three watchers plus the helper; no outer-id access in delegates so `pragma ComponentBehavior: Bound` is not needed), layout (no anchors-in-layout mixing; delegate height from `rowLayout.implicitHeight`), loaders (none), delegates (`required property` present, no `index`), states (none), performance (item 5). Lint on changed lines only: 82 hits, all of kinds every file in the repo has (`var`, property order, `property var`); one false positive (BND-2 on `leaving`, which has no binding).
- **Repo checks run here:** script tests 109/109 before my change; `skills-index.js --check` current at 138 skills.

**Verdict:** Healthy. Merge #167 after this review PR, and merge the pending-mints PR before it or before the on-device restock rows.
**Lean:** -0 lines, -0 dependencies. The three watcher properties in the sheet are not redundant: they cover in-place changes.
**Not checked:** the QML run itself, `qmllint`, the sheet and `Main.qml` on a device (plan rows apply), C++ beyond a grep for `signOut`, the Firebase side (this PR has none), `README` / `AGENTS` beyond the lines this PR touched, whether Felgo's `Popup.visible` flips synchronously in `open()` (matters only for item 5).
