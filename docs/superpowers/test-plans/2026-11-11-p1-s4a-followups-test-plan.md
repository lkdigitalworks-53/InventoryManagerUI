# Test plan - P1 S4a follow-ups (one PR, four commits)

Branch `feat/2026-11-11-p1-s4a-followups`. Plan: `plans/2026-11-11-p1-s4a-followups-one-pr-plan.md`. Standard format (Skill 49).
Server and rules only: no QML, no UI. CI observed: see CHECKPOINT (read after each push).

## Slice 1 - D-R4: the caller is resolved inside a `try` in every older handler
### 1. Unit / functional (handler, real `index.js`, in-memory Firestore double)
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/index.handlers.membershipAuthority.test.js` | +33 table, +5 | RUN 162/162 | 11 handlers x 3 failing reads (users doc, member doc, every read): JSON 500 with the handler's own code, never `write-rejected`, never `no-tenant-context`, zero writes / locks / files / scans, one `deriveContext failed` log (computeStockRegister logs with console.error, SR-D16). Non-Error throws (string, undefined, null, 42, object). Refusal untouched (403 for all 11). Monkey: 200 seeded runs. Guards: every handler has a code in the table; raw `deriveContext` calls = 2 (helper + computeStockRegister); no `CONTEXT_FAILED` line names a terminal code. |
### 2. Regression
Whole functions suite 1525/1525 (was 1434): F2/F3/S2f-1 matrix, `provisionMemberTarget`, photos, locks, analysis, register all untouched and green. Scripts 1049/1049.
### 3. Mutation (hand, all killed)
Raw `deriveContext` back in `recordDelta` (6 fail); `recordMutation` answers `write-rejected` (6 fail); helper returns `null` (33 fail); helper does not log (30 fail).
### 4. E2E / rules
None: no client, no rules change. State it in the PR.
### 5. Client check (read only, no code)
`StuckWrites.noteFailure` parks a write only on `write-rejected`; any other JSON 5xx body is "may still succeed" and retries exactly like today's bodiless platform 500. `LockManager._classifyAcquireResponse` maps any non-409, non-403-`no-tenant-context` body to reason `error`. So a JSON 500 `write-unavailable` / `lock-failed` is safe.
### On-device
Happy: nothing visible. Negative: cannot be provoked on a phone without breaking Firestore; covered by the double. Affected areas (all ten handlers answer as before): restock, order complete, return, open an order for edit (lock), photo upload, photo delete, analysis, staff add. Regression: the S4a steps 1-5 still pass.
