# PR #161 final sweep (S2f-4 + S2f-5: default-deny writes) — 2026-10-25

Scope: the PR surface (`firestore.rules`, `test/firestore.rules.test.js`, test plans, docs) and the client
and gateway paths it can break. Reviews run: requesting-code-review (inline, no subagent tool),
ponytail-audit scoped to the PR surface, qt-qml-review (0 QML files in the diff).
Not run: the Firestore emulator (CI only), the Functions suite, a whole-repo audit.

## Verdict
No must-fix in the diff. CI green on the rebased head `a147caf`: 3127 = QML 2104 + Functions 835 + Rules 92 + E2E 96.

## Evidence that the rules change does not break the app
Independent re-audit of every client write path (the PR's own audit was a grep; this one added receiver-agnostic greps):
- Direct client writers: `activity_log` (ActivityLog), `config` (CategoryStore, OrderChannelStore), `counters` (FirebaseService mint), `_migrations` (MigrationService), plus `users`, `tenants`, `members` (AuthService, own rule blocks). All on the allow-list or covered by their own rules.
- No other `.put/.patch/.putMany` caller in `qml/` or `src/`; no native Firebase plugin; no direct-write fallback in Gateway.
- `test/e2e/seed.js`, `E2EHelpers.js` and the e2e suites use the Admin SDK, so rules do not apply to them.

## Findings
| # | Sev | Finding | Status |
|---|---|---|---|
| 1 | Should | Test counts in PR body, plans, CHECKPOINT were wrong (3096/3103/3094/3063). Rules counts `storage.rules.test.js` (7) too. | Fixed in this PR |
| 2 | Should | `FIRESTORE_RULES.md` showed the old fail-open blacklist as "Example Rules" and said "keep in sync"; it had drifted in two PRs. | Fixed: code copy removed, summary table + pointer to `firestore.rules` |
| 3 | Should | Test gaps: only the owner was tested writing the allow-list; "monkey" was a fixed 14-name list; `ROSTER_ROLES` used before its declaration (worked only because tests start async). | Fixed: role-matrix test, seeded monkey (100 ops, fixed seed, guarded to hit an allowed name), constant hoisted |
| 4 | Known | `counters` takes any value from any role (rewind, non-number, delete). | NOT fixed by decision (S2f-6, server-side minting). Pinned by test "PIN S2f-6". |
| 5 | Process | Commit `12e2bf4` edits #160's test plan inside #161. | Counts now correct in both; note for the future: fix a parent PR's docs on the parent |
| 6 | Investigate | Owner can set `ownerId`, then that uid bootstraps as a second owner. Read from rules, not proven. | Documented, `KNOWN-ISSUES.md`, with the probe test and fix options |
| 7 | Investigate | Client cleanup calls `remove("users/..")` and tenant rollback that the rules refuse (403, warn only). Harmless since #159. | Documented, `KNOWN-ISSUES.md` |
| 8 | Product | `config` (categories, order channels) is writable by every role including staff. | Open question for the owner, no change |
| 9 | Lean | `MEMBER_ROLES` and `ROSTER_ROLES` identical; explicit `locks` block redundant with the read carve-out. | Left (about -10 lines); ledger deny blocks kept as defence in depth |

## qt-qml-review
0 QML lines changed, so nothing to report. Linter on the 7 client writer files: 371 hits, all existing style
(288 `var`, 57 `==`, 13 ordering, 8 `property var`, 5 `Qt.createQmlObject`). `qmllint` not available in the sandbox.

## Tests added by this sweep (predicted Rules 95, total 3130, CI to confirm)
1. every role (owner, admin, manager, staff) writes all four client-writable names;
2. PIN S2f-6: `counters` accepts rewind / non-number / delete from staff;
3. seeded monkey: 100 mutated collection names x create/update/delete, only the exact allow-list names succeed, denied writes leave stored data untouched.
Dry-run without the emulator (stubbed runner): 88 registrations, 100 legal names, 5 allowed hits, deterministic.
