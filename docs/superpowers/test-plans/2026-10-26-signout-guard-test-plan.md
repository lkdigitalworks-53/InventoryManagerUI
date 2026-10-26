# Test plan — sign-out guard (S0): warn before sign-out / leave-workspace discards unsynced work

**Branch:** `feat/2026-10-26-signout-guard` (off `main` @ `b494d52`). **Design:** `specs/2026-10-26-signout-guard-design.md`.
**Covers:** `qml/helper/SignOutGuard.js` (new, pure), `qml/pages/SignOutSheet.qml` (new view), `qml/Main.qml` (`askLeave`, three entry points, Back list), `qml/components/BottomSheet.qml` (`secondaryColor`).
**Why:** `Main.qml onSignedOut` runs `Gateway.clear()` and `PhotoQueue.clear()`; the old confirms never said that queued writes and photos would be thrown away.
**No server change, no deploy.**

## What was actually executed in the session (honest)
- **Node, not Qt.** `qmltestrunner` does not run in the sandbox. The pure-JS bodies of `tests/tst_SignOutGuard.qml` were run under a throw-away Node shim (the shim itself was first checked against `tst_DescribeItem.qml`: 43/43, so it reproduces QtTest for pure helpers). Result: **53/53** expanded cases.
- **Mutation check:** 16 hand-made mutants of `SignOutGuard.js` (state rules, strictness of `inFlight` and `leaving`, caps, every consequence line, the singular summary, `more`, the lookup try/catch, the `maxRows` bound, the blank-name fallback, counting photos): **16/16 killed**.
- **Not run:** the QML run itself (CI is the signal), `SignOutSheet`, `Main.qml` wiring (Felgo, no `App` context under `qmltestrunner`: on-device only).
- Brace/paren/bracket balance on every touched file: clean (`Main.qml` reads the same as on `main`). `qt_qml_lint.py` on the two QML files: only findings of the kinds that every file in the repo already has (property order, `var`, `property var` for arrays), plus one intentional imperative assignment (`leaving` in `ask()`).

## 1. Unit tests (`tests/tst_SignOutGuard.qml`, 36 test functions + 4 data functions = 53 cases)
| Area | Cases |
|---|---|
| Nothing pending | empty -> count 0, no consequences, "Everything has synced"; five non-array/missing inputs (and null / string opts) |
| One outbox item | waiting edit (row text, state, consequences exactly `[signOut, change, local]`); plural summary; in-flight -> Sending + the may-have-saved line; stuck -> Needs attention; parked; parked by failure count alone; `terminal` without `stuck` stays Waiting; attention beats sending; only a strict `true` from `inFlight` counts; `inFlight` receives each `requestId` in order |
| Other outbox shapes | order completion (title, detail, kind, line); unknown operation type is a plain change; batch ("2 products changed") and delta ("Stock change") rows |
| Photos | 6 queue states -> row states; name from the lookup else id; no lookup; throwing / non-string / blank lookup; no product id skips the lookup; uploading adds the Sending line |
| Mixed and caps | all kinds -> every line once in a fixed order; outbox rows before photo rows; cap 5 with `more`; exactly 5; outbox + photos share the cap; `maxRows` 2 / 6 / 2.9 / 0 / -3 / NaN / Infinity / "3" / null |
| Wording | leave variant changes only the first line; `leaving` must be exactly `true`; local-data line always last |
| Hostile input | malformed items counted and shown generically; throwing `inFlight`; inputs not mutated; result does not alias the input; repeatable |
| Monkey | seeded (20261026), 300 random mixes of junk, edits, completions, photos, random `maxRows` / `leaving` / lookups: count, row count, `more`, empty-iff-no-consequences, Sending line iff `hasSending`, valid states, local line last |
Happy path: one-item, mixed, completion, photos. Negative: junk input, throwing lookups. Edge: caps, ties between states, blank names. Multi-scenario: 6 photo states x rows, 9 `maxRows` values. Monkey: the last case.

## 2. Regression tests (automated)
Existing suites that must stay green: `tst_DescribeItem` (the helper reuses it), `tst_StuckWrites` (`isParkedItem`), `tst_PhotoQueue`, `tst_Gateway`. No existing test references the old `confirmDlg` sign-out wording (grep of `tests/`, `test/`, `functions/test/`: none).

## 3. E2E
None. The change is view + pure helper; nothing reaches the server.

## 4. Counts
Expected CI total = main's last observed total + 53 (QML). Read the exact number from the CI comment on the PR; do not trust this line (Skill 131 rule 3).

---

## On-device test plan
**Prerequisites:** a NEW tenant (owner), the app online. To queue work on purpose: switch on airplane mode, then edit a product / complete an order / add a photo. For a parked write see the stuck-writes test plan (temporary wrong `functionUrl`, or a suspended member). For a **Sending** row: turn airplane mode on right after tapping save, then open the Profile page and tap Sign out immediately.

### Happy path
| # | Action | Expected |
|---|---|---|
| H1 | Nothing queued. Profile -> Sign out | Same plain "Sign out?" confirm as before; Sign out signs out |
| H2 | Airplane mode, edit a product, Profile -> Sign out | SignOutSheet: "1 change hasn't reached the server.", row "Edited product" + name, tag Waiting, the lines "Signing out discards these...", "Edits, additions and deletions must be entered again.", "Data stored on this device is also cleared." |
| H3 | H2, tap **Stay signed in** | Sheet closes, still signed in, the edit is still queued; reconnect, it syncs |
| H4 | H2, tap **Sign out and discard** | Signed out. Sign back in: the edit is NOT there (discarded, as the sheet said). Nothing from the old session replays |
| H5 | Airplane mode, complete a pending order, Sign out | Row "Order completion" + customer; line "A queued order completion leaves the order Pending..." After discard and sign-in the order is Pending and can be completed again |
| H6 | Airplane mode, add a product photo, Sign out | Row "Product photo" + product name, line "Photos that were not uploaded are lost." |
| H7 | Non-owner member: Profile -> Leave workspace with a queued edit | Sheet titled "Leave with unsynced work?", first line "Leaving signs you out...", buttons "Stay in workspace" / "Leave and discard" |

### Negative
| # | Action | Expected |
|---|---|---|
| N1 | Sheet open, Android Back | Closes = stay signed in; nothing lost |
| N2 | Sheet open, tap outside / the X | Same: stay signed in |
| N3 | Sheet open, tap **Stay**, immediately Sign out again | Sheet opens again with the same rows |
| N4 | Rejected (parked) write queued | Row tag "Needs attention" in red AND in words; the same write is in the "Changes not syncing" sheet |
| N5 | TenantSetupPage Sign out with an empty queue | Signs out at once, as before (no new confirm) |

### Edge cases
| # | Action | Expected |
|---|---|---|
| E1 | Sheet open while online with a Waiting item; the item syncs | Rows disappear, text "Everything has synced. Nothing will be lost.", the red button reads plain "Sign out" (or "Leave workspace") and signs out without loss |
| E2 | 8 queued edits | 5 rows, then "+ 3 more"; the summary says 8 |
| E3 | A Sending row (request in flight when you tapped Sign out) | Tag Sending, extra line "Changes marked Sending may or may not have been saved. Check after you sign in."; after sign-in check the record |
| E4 | Edits + order completion + photo together | All three consequence lines once each, "Data stored on this device..." last |
| E5 | Font size Large, small phone (360 dp wide) | Title, rows and buttons wrap, no overlap; the sheet scrolls; both buttons stay visible |
| E6 | Rotate or lose focus with the sheet open | Sheet survives; Stay still works |
| E7 | Kill the app with items queued, reopen (still signed in) | Items still queued (they survive a kill); Sign out then warns about them |
| E8 | Two items for the same product edited twice offline | Counted once (the outbox coalesces them), row shows the product |
| E9 | Screen reader on | Each row is read as title, detail, state |

### Multi-scenario / monkey (manual)
Queue a random mix (edit, restock, add product, complete order, photo) offline; open and cancel the sheet 10 times quickly; then discard. After sign-in nothing from the old session appears, no toast says a write succeeded, no crash. Repeat with a parked write present.

### Affected areas
| File | Automated coverage | Where to look on device |
|---|---|---|
| `qml/helper/SignOutGuard.js` | 53 cases + 16/16 mutants | H2-H7, E2-E4 |
| `qml/pages/SignOutSheet.qml` | none (Felgo) | all H, N1-N3, E1, E5, E6, E9 |
| `qml/Main.qml` (`askLeave`, 3 entry points, Back list) | none (Felgo) | H1, H3, H4, H7, N1, N5 |
| `qml/components/BottomSheet.qml` (`secondaryColor`, default unchanged) | none | every other BottomSheet footer still has a normal ghost button: Close in "Changes not syncing", Cancel in Add Product, Export |

### Regression watch
- Sign-out with nothing queued behaves exactly as before (H1, N5).
- Android Back still closes other sheets in the same order (the new sheet is first in the list, it is only open when you asked to sign out).
- The ghost buttons in the other sheets did not change colour.
- Leave workspace for an owner is still refused with its own message (the guard does not change that).
