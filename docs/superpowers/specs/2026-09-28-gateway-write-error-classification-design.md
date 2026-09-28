# Gateway write-error classification (roadmap item 1, part C) — design + plan

**Date:** 2026-09-28. **Branch:** `fix/2026-09-28-gateway-write-error-classification`.
**Decision trail:** options doc `2026-09-28-gateway-stuck-write-retry-discard-options.md` (Q1: C first, client never
drops). Signal channel chosen by Taher 2026-09-28: **option B** (status stays 500, distinct `error` strings).

## Problem

Every Firestore write exception is answered `500 write-failed`, so the client cannot tell a write that can never
succeed from an outage. PR #75 only counts failures. Part B (park + Retry/Discard) needs a trustworthy signal before
it may offer a destructive button.

## Why not distinct 4xx/503 statuses (the original sketch)

`Gateway._classifyDeltaResponse` and `_sendOperation` treat ANY 4xx with an `ok:false` body as a definitive server
decision: the write is removed from the outbox and its callback fires. A 4xx for a poison write would make the client
drop it, contradicting "client never drops in this PR". `_classifyBatchMutationFailure` already avoids trusting
status alone (it allowlists `body.error`). Same approach here.

## Design

**Server** — `functions/lib/writeError.js`, pure `classifyWriteError(e)`, status stays 500:

| Firestore code (numeric / string) | `error` |
|---|---|
| 3 invalid-argument, 5 not-found, 6 already-exists, 7 permission-denied, 9 failed-precondition | `write-rejected` |
| 4 deadline-exceeded, 8 resource-exhausted, 10 aborted, 13 internal, 14 unavailable | `write-unavailable` |
| anything else (cancelled, unknown, data-loss, unauthenticated, plain Error, non-object, `"7"` string) | `write-failed` (unchanged) |

Wired at all five `write-failed` sites in `functions/index.js`: `recordMutation`, `recordDelta`, `recordOperation`,
`recordMutationsBatch`, `provisionMember` (the last is not an outbox write; changed for one consistent contract, the
client ignores it).

**Client** — `StuckWrites.js` keeps `terminal[requestId]` = the server's LATEST answer was `write-rejected`
(set/cleared on every counted failure; 401/409/offline never touch it; a hang clears it). `terminalCount(state)`
counts stuck writes with the flag. `Gateway._noteFailure(item, status, body)` reads the code via `errorCodeOf` and
publishes `stuckTerminalCount`; `Main.qml` republishes `syncStuckTerminalCount`; `GlassHeader` shows
"N change(s) rejected by the server. Still retrying." when it is above 0, else the existing "not syncing" text.
Retry, backoff, threshold (5) and dropping are untouched.

## Deliberate limits (ponytail)

- `write-unavailable` is emitted for logs and part B, but the client treats it like unknown: the existing
  "not syncing" caption already says the right thing. No new transient label.
- Mixed case (some rejected, some not): the caption shows the rejected count only. Ceiling: the other stuck writes
  are not named until part B's dialog lists them.
- The `terminal` flag is in memory only, like `stuckCount`. Persisting it belongs to part B (Q3).
- Admin SDK ignores security rules, so `permission-denied` will rarely come from these endpoints; it is mapped for
  completeness. Realistic rejected causes: invalid-argument (bad value, oversize doc), failed-precondition.
- Old clients (built before this) see the same 500 + a different error string and behave exactly as before.

## Plan (all done in this PR)

1. `writeError.js` + `test/writeError.test.js` (8 tests). 2. Five catch sites + 10 handler tests. 3. `StuckWrites.js`
(`REJECTED`, `errorCodeOf`, `terminalCount`, `noteFailure` 5th arg, `prune`) + 14 tests incl. a reference-model monkey.
4. `Gateway.qml` + `Main.qml` + `GlassHeader.qml` + 10 Gateway tests. 5. Test plan, SKILLS 74, KNOWN-ISSUES, roadmap,
README, AGENTS.
