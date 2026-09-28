# Test plan — Gateway write-error classification (roadmap item 1, part C)

**Branch:** `fix/2026-09-28-gateway-write-error-classification` off `main`.
**What it does:** the server now answers a failed write with `write-rejected` (can never succeed),
`write-unavailable` (worth retrying) or `write-failed` (unknown), still HTTP 500. The client labels stuck writes the
server rejected in the header caption. Nothing is dropped or retried differently. Design:
`docs/superpowers/specs/2026-09-28-gateway-write-error-classification-design.md`.
**Not covered / out of scope:** Retry/Discard (part B), persisted flag, mixed-case caption naming, the emulator
never producing a real Firestore error code on demand (see On-Device).

## 1. Unit / functional test coverage

**`functions/test/writeError.test.js` (8, run for real):** wire strings pinned; all 5 terminal codes, numeric and
string; all 5 transient codes, numeric and string; unmapped codes (0, 1, 2, 11, 12, 15, 16, 17, -1 and their string
names) -> `write-failed`; plain `Error` and `ECONNRESET`; null/undefined/primitives/`{}`/`[]`/`{code:null}`/`{code:{}}`;
`"7"` not coerced; disjoint sets plus a 500-step seeded monkey.
**`functions/test/index.handlers*.test.js` (+10, run for real):** for each of the five handlers, a terminal (7) and a
transient (14) error -> `500` with `write-rejected` / `write-unavailable`. The five existing plain-`Error` tests still
assert `write-failed`.
**`tests/tst_StuckWrites.qml` (+14, CI only):** `errorCodeOf` text/object/junk (never throws), `REJECTED` string,
terminal only once stuck, non-terminal codes, latest answer wins both ways, 401/409/offline never touch the flag,
online timeout clears it, per-write tracking, prune drops flags, reused id starts clean, code does not move the
threshold, 25-seed reference-model monkey.
**`tests/tst_Gateway.qml` (+10, CI only):** `stuckTerminalCount` starts 0; rises only when stuck; outage answer leaves
it 0; garbage/missing bodies; timeout path with no body; follows the latest answer; subset of `stuckCount`; drops when
the write leaves the outbox; `clear()` resets; `_noteFailure` never removes the write.

## 2. End-to-end test coverage

None new. The Firebase emulator (Admin SDK) does not raise a chosen Firestore code on demand.

## 3. Regression test coverage

- 5 existing handler tests: unknown error still `write-failed` (old clients unaffected).
- Existing `tst_StuckWrites` / `tst_Gateway` stuck tests call `noteFailure` / `_noteFailure` with the old arity and
  still apply.
- New: status stays 500 for every mapped code (asserted in each handler test), the guard against a 4xx making
  `_classifyDeltaResponse` drop the write.

## 4. Firestore rules test coverage

No rules change.

## What was genuinely run

**Functions:** `cd functions && npm ci && npm test` — 269 pass (251 baseline + 8 + 10). **QML:** not run in the
sandbox (no Qt); `StuckWrites.js` logic smoke-checked in Node only. CI is the QML signal.

## On-Device Test Plan

**Prerequisite:** deploy or emulate the new `functions/`. To force a rejection, TEMPORARILY (never commit) add at the
top of `GatewayLogic.applyMutation` in a local emulator:
`if (args.entityId === "REJECT-ME") throw Object.assign(new Error("t"), { code: 7 });` (`code: 14` for the outage
case). Use a product/order whose id you control, or edit the check to match any id.

### Happy Path
1. With normal functions, edit a product online: saved, no caption, no toast.
2. With the temporary throw (`code: 7`): edit the matching record. After about 3 minutes: one toast "Some changes
   aren't syncing. The app keeps retrying." and the header shows "1 change(s) rejected by the server. Still
   retrying." The write is still queued.
3. With `code: 14`: same toast, header shows "1 change(s) not syncing. Still retrying." (old text).
4. Remove the throw, redeploy: the write goes through on the next retry and the caption clears.

### Negative Cases
5. Plain `throw new Error("x")` (no code): "not syncing" text, never "rejected".
6. Airplane mode: offline caption only, no toast, no "rejected".
7. Sign out and back in with a stuck write: caption gone, no stale "rejected" count.

### Edge Cases
8. One rejected write plus one outage-stuck write: header shows "1 change(s) rejected" (mixed-case ceiling).
9. Switch the throw from `code: 7` to `code: 14` while stuck: caption flips to "not syncing" on the next attempt.
10. Relaunch while stuck: counters restart (in memory only), same behaviour after 5 more failures.
11. Two rejected writes: "2 change(s) rejected by the server."

### Affected Areas
| File | Automated | On-device |
|---|---|---|
| `functions/lib/writeError.js`, `functions/index.js` (5 sites) | yes, run | steps 2-5 |
| `qml/helper/StuckWrites.js` | yes, CI | steps 8-11 |
| `qml/model/Gateway.qml` | `_noteFailure` path only; XHR handlers not testable | steps 2-4 |
| `qml/Main.qml`, `qml/components/GlassHeader.qml` | none (rendering) | steps 2, 3, 8, 11 |

### Regression Tests (manual counterpart)
- Normal edits online still save with no caption (would break if the header condition were wrong).
- A stuck write is never silently lost: after step 2 the write is still in the queue and retrying.
