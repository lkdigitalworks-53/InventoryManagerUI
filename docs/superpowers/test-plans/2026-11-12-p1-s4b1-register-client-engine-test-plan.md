# Test plan: P1 S4b-1, stock register client engine (pure model + service, dormant)

Branch `feat/2026-11-12-p1-s4b1-register-client-engine`. Design: `specs/2026-11-12-p1-s4b-register-client-design.md` (D1..D12). Standard format (Skill 49). **Nothing is visible in the app after this PR** (no page, no entry point: S4b-2). Node tests were RUN in the sandbox; QML tests run only in CI.

## 1. Unit tests

| File | Cases | Run? | Covers |
|---|---|---|---|
| `.github/scripts/__tests__/stockRegisterModel.test.js` | SRM-01..07: one battery of about 350 checks, TZ independence over 5 zones, 3000-instant monkey, 1500-answer monkey, real-server contract, guards, 81 hand mutants | RUN | Presets (month, quarter, FY, last of each) at the IST midnight edge, UTC edge, year edge, leap February, century; chains with no gap or overlap; custom days (leap day, impossible days, reversed, equal-ms reversal, year range); request body is epoch ms; every status classified; echoed-window check (1 ms moved, strings, missing); Indian digit grouping; flat rows with identical keys; quiet-row rule and its exceptions; dropped and skipped counts; detail lines in kind order; role list, kind list and labels equal the server; no local-time getter in the file |
| `.github/scripts/__tests__/stockRegisterService.test.js` | SRS-01..05: one battery (130 checks), 2000-run monkey, wiring, dormancy, 60 hand mutants | RUN | Real function text against a fake XHR: request shape, token header, timeout, status snapshot (QTBUG-49896), every failure kind, answer-exactly-once under timeout/double DONE/cancel/late answers, single flight (`busy`), local refusals (no token, role, bad window) send nothing, workspace/role change drops the answer, `cached` per window/workspace/role, `clear`, 401 uses the silent door |
| `tests/tst_StockRegisterModel.qml` | 13 functions | CI only | Main contract in the real Qt JS engine (shim-run in Node 13/13) |

Suites after the change: script suite 1061/1061 (the first run was 1060: `sessionRecheckWiring` caught a direct `refreshIdToken(true)` call, fixed, Skill 172 rule 9), `functions` 1671/1671 (untouched).

## 2. Functional / rules / e2e
- Functional: the behaviour tests above (real function bodies, fake edges, real model, real server math in SRM-05).
- Rules: unchanged. Server: unchanged.
- E2E (emulator): none. The first QML-to-endpoint case belongs to S4b-2 (S4a KNOWN-ISSUES 9).
- Guards: `SRS-03` URL equals the deployed handler's project and region, client timeout above the server's `timeoutSeconds`, no timer or resume hook in the service; `SRS-04` nothing but tests names the service; the existing import scan (TREE-2) covers the new files.

## 3. Regression
- No existing file's behaviour changed. `qml/model/qmldir` gained one singleton line; `sessionRecheckWiring` (only `AuthService` may call `refreshIdToken(true)`) stays green because the service uses `ensureFreshToken`.
- Existing QML tests must stay green in CI.

## 4. Review sweep of PR #198 (2026-11-16, same PR): what was found, what tests prove it

| # | Finding (concrete case) | Fix | Test (all in `stockRegisterService.test.js`) |
|---|---|---|---|
| 1 | `load()` set `loading = true`, then `open` / `setRequestHeader` / `FirebaseService.environment` / `send` could throw: the service stayed busy for good (every later load answered `busy`, no words) and the caller was never answered | one `try` around them, settle through the latch as `unknown`, return false | SRS-01: throw in open, header, send, env read: answered once as `unknown`, retryable, `loading` / `_xhr` / `_pendingCallback` freed, the next load is sent. Mutants: guard dropped, settle dropped, sent flag true, answered as offline |
| 2 | The status snapshot copied `responseText` on every LOADING chunk even for 2xx: a big register rebuilds the string once per chunk | body copied only for non-2xx; DONE reads the body otherwise | SRS-01: counting fake, 2xx chunks read the body 0 times, DONE once; error body still recovered when the status is lost; lost 2xx with no body is `badAnswer`. Mutants: copies 2xx bodies, drops error bodies, lost body unused |
| 3 | `_fail("window")` said retryable, `classify` says not | `retryable: kind !== "role" && kind !== "window"` | SRS-01: all 8 bad windows are not retryable. Mutant: window retryable |
| 4 | Service header named `functions/test/stockRegisterClient.guard.test.js`, which does not exist | comment names SRS-04 | n/a (comment) |
| 5 | Skill 167 and the docs conflicted with main (picker S4 took 167; main is at 171) | merged main, this PR's skill is 172, main's CHECKPOINT archived | `sessionRecheckWiring` and the other script tests: whole script suite 1061/1061 after the merge |
| 6 | `moved` / `movementCount` are all-time (server `count`), easy to mislabel as "this period" | comment on `buildView`, KNOWN-ISSUES, design carry list | n/a (comment) |

Negative, edge and monkey cover: throw cases are the negative path; the next-load-after-throw check is the edge; SRS-02 (2000 random orders) still passes unchanged. Suites after the sweep: script suite 1061/1061 (ran in the sandbox), service file 60/60 mutants killed. QML twin unchanged: CI only.

## On-device test plan (Taher; build needed; any phone, dev tenant)

Honest scope: **there is no feature to test on a device yet.** The only device-visible risk is a QML compile error in the new singleton.

### Happy path
1. Build and install. The app starts, the login or home screen shows, and the Qt log has no `StockRegisterService` or `StockRegisterModel` line.
2. Use the app for a minute (Orders, Stock, Sales): nothing looks or behaves differently.

### Negative
3. Sign out and in again: no new log lines from the register files.

### Edge cases
4. Start the app offline: it starts as before (the service is never called).

### Affected areas
5. `qml/model/qmldir` has one more singleton: any QML error would appear at start-up in the log (step 1).

### Regression
6. Restock, New Order, Edit Order, refresh row behave as before (spot check one each).

### Optional server check (S4a step 1, still pending on a device)
7. With an owner token, `curl -X POST <computeStockRegister url> -H "Authorization: Bearer <token>" -H "Content-Type: application/json" -d '{"env":"dev","from":<ms>,"to":<ms>}'` with `from` and `to` copied from `StockRegisterModel.presetWindow("month", Date.now())` run in any JS console (IST midnights): answer 200 and `window.fromMs` equal to what you sent.
