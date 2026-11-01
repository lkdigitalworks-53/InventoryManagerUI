# Test plan — Cloud Functions runtime Node 20 -> 24 (`firebase.json`, `functions/package.json`, `checks.yml`)

Branch `fix/2026-11-01-functions-node-24-runtime`. Config-only change: no application code, no QML.

**Verification status.** RUN in the sandbox on a real Node 24 (v24.22.2): functions suite 937/937 (also green before the change), script suite 470/470 including the 8 new cases. CI-only, not run here: QML (Qt 6.8, independent of Node), Firestore + Storage rules, E2E on the emulator, all now on Node 24. Not run: the real deploy (needs Taher's approval tap on `main`).

## 1. Unit tests
`.github/scripts/__tests__/runtimeVersion.test.js` (RV, 8 cases, run 8/8):
- RV rule: `firebase.json` runtime is `nodejs<major>` and `engines.node` is that same bare major.
- RV rule: every `node-version` in `checks.yml` (at least 6) equals the runtime major.
- RV rule: the runtime is newer than the last decommissioned Node (20).
- RV every rule has a mutant; RV parsers return NaN or an empty list on a malformed file and never pass a rule.

## 2. Regression tests
Each rule has a mutant that must fail it (3 of 3 caught, each checked non-vacuous): runtime `nodejs22` vs engines 24; one CI job on `'22'`; everything back on Node 20 (the exact incident, "Runtime Node.js 20 was decommissioned on 2026-10-30").
Existing functions suite on Node 24: 937/937 (the same count as on Node 22 and before the change).

## 3. E2E
No new e2e. The existing `e2e-tests`, `functions-tests` and `firestore-rules-tests` CI jobs now run on Node 24 and must stay green (CI is the oracle). Predicted counts are not written down: read them from the PR comment.

## On-device test plan
Only meaningful after the first successful deploy from `main` (merge, tap approve on the `firebase-deploy` Environment).

### Prerequisites
| Item | Value |
|---|---|
| Build | Current app build, no new build needed |
| Account and role | Owner on a dev tenant |
| Console access | Google Cloud console for `inventorymanager-48392` (Cloud Run functions, Logs Explorer) |
| Seed data | A tenant with at least one product, one supplier, one pending order |
| Reset | None between scenarios; scenarios only add rows |
| Wait | Deploy job takes a few minutes; the sweeper runs every 10 minutes |

### Happy path
1. Console -> Cloud Run functions -> any of the 12 functions: runtime shows Node.js 24. Expected: all deployed functions show Node.js 24, none Node.js 20.
2. App: sign in, open Products. Expected: the list loads (gateway reads work).
3. Create an order and approve it. Expected: it completes, stock drops by the ordered quantity (`recordOperation`).
4. Restock a product. Expected: a new batch id appears (server `mint` op).
5. Add a product photo, then delete it. Expected: upload and delete both succeed.
6. Open Sales Analysis. Expected: figures load (`computeAnalysis`).

### Negative
1. Sign out, then call a function URL with no token (curl). Expected: 401 or 403, not a 500.
2. Re-run the failed deploy before the IAM roles exist (only if a role is revoked on purpose). Expected: the old permission error, nothing deployed. **Record** the text; not part of the normal flow.

### Edge cases
1. First call after idle (cold start). Expected: slower once, then normal. **Record** the delay; there is no baseline from Node 20.
2. Logs Explorer, filter `cleanupPendingMarkers`, wait 10 minutes. Expected: the scheduled sweeper ran on Node 24 without errors.
3. Airplane mode, add a product, back online. Expected: the queued write drains.

### Monkey
Tap Place order and Approve 10 times quickly on one order, then rotate the phone. Expected: one order, one stock deduction, no crash.

### Affected areas
| File | Automated coverage | Where to look on a device |
|---|---|---|
| `firebase.json` | `runtimeVersion.test.js`, deploy itself | Console runtime column |
| `functions/package.json` | `runtimeVersion.test.js`, `npm ci` in CI | none |
| `.github/workflows/checks.yml` | `deployWorkflowWiring.test.js`, `runtimeVersion.test.js`, the run itself | Actions tab |
| All `functions/` code | 937 cases on Node 24 | steps 2-6 |

### Regression (how you would notice it coming back)
- Deploy fails with "Runtime Node.js N was decommissioned": runtime pin is behind Google's table again.
- Functions stop answering in the app with no deploy in between: a runtime was retired and the function disabled.
