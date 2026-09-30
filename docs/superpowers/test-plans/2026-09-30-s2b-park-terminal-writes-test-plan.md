# Test plan — park rejected writes (part B, S2b)

**Branch:** `feat/2026-09-30-s2b-park-terminal-writes` (off `main`). **Design:** `../specs/2026-09-30-s2b-park-terminal-writes-design.md`.
**Status:** written with the code, before CI. **Nothing was built or run.** No Qt toolchain in the sandbox; CI is the QML signal.

## What S2b changes
A write that is stuck AND whose latest server answer was `write-rejected` is **parked**: the drain never sends it, it holds its record's keys so later writes for that record wait, and only Retry releases it. Parked is derived (`stuck && terminal`), not stored. Discard is S3.

## What was actually executed in the session (Node, not Qt)
`qml/helper/StuckWrites.js` in a Node `vm`: park rule A, clear + re-park, transient after release, garbage inputs, `isParkedItem` vs `hydrate` agreement over 5000 random items, parked-subset-of-stuck monkey over 20000 steps: **37450 assertions passed** (throwaway harness, not committed). **Not executed:** `tst_OutboxStore.qml`, `tst_Gateway.qml` (need Qt), everything on device.

## 1. Unit (headless, `tests/`)

| File | New | Covers |
|---|---|---|
| `tst_StuckWrites.qml` | 17 | `isParkedItem` (needs stuck+terminal, stuck repaired from failures like `hydrate`, garbage input); `isParked` (parks on the tip, outage never parks, rejected AFTER the tip parks = rule A, rejected below threshold does not, unknown id); `clearTerminal` (unparks, keeps stuck and count, harmless on anything); release + rejected again re-parks after one attempt, release + outage goes back to retrying; parked count equals `terminalCount`; metaOf -> hydrate round trip; prune; monkeys: persisted rule agrees with `hydrate`, parked is always a subset of stuck |
| `tst_OutboxStore.qml` | 25 (+2 updated) | `dueItems` (parked never due even when its time has come, stuck-not-rejected still due, rejected below threshold not parked, failures>=5 + terminal without `stuck` parked, old items not parked, unrelated items still go, later delta / batch / operation-member for the same record wait, earlier write not held, 25 items one parked); `nextDueInMs` (parked ignored, blocked sibling ignored, others still seen); `wakeStuck` skips parked; `retryNow` (releases, keeps stuck + failures, due again, re-parks on a new rejection, siblings follow once it is sent, no change for a non-rejected item); coalesced edit stays parked; still pending for its entity; survives `_load()`; unparked stuck item woken after relaunch; `clear`; monkey over 400 random ops against an independent model of `dueItems` and the timer |
| `tst_Gateway.qml` | 19 (+1 updated) | rejected stuck write not handed to the drain and the timer stops; outage stuck write keeps retrying; rejected after the tip parks without a second toast; toast says "paused" vs "keeps retrying"; `retryStuck` on parked (due once, terminal cleared, stuck kept, row label); rejected again re-parks without a toast; outage after retry returns to auto-retry; landing clears everything; one retry leaves other parked writes parked; relaunch keeps parked and does not wake it; relaunch wakes outage-stuck but not parked; rejected below threshold retries; offline / 401 / 409 never park; edit merges and stays parked; leaving the outbox and sign-out clear it; double retry harmless; monkey: dialog `rejected` flag, persisted items and drain always agree |

## 2. Functional / rules / e2e
- **Functional:** the cases above use the real singletons and real `OutboxStore` persistence (`Settings`).
- **Rules:** `firestore.rules` / `storage.rules` untouched; no rules tests.
- **Server / Node:** server untouched; no `functions/` tests.
- **e2e (emulator):** none; no new server path. Reject -> park -> discard e2e belongs to S3.

## 3. On-device checklist (only coverage for header, dialog and copy)
Setup: **dev/test** environment, **new tenant**. A rejection needs the server answer `write-rejected`; the known setups (suspended member -> 403, wrong `functionUrl` -> 404) give a NON-rejected stuck write, so use them for the "keeps retrying" cases. For a real rejection use a write the Cloud Function refuses as invalid (ask Claude for a current recipe before testing; none is verified yet). Online throughout.

**Happy path**
- [ ] Rejected write reaches 5 failures: toast says it is paused; header reads "rejected by the server. Tap to retry."; dialog row says "Paused until you tap Retry"; button says "Retry".
- [ ] Watch for ~5 minutes: the row never flips to "Sending..." by itself (no auto-retry).
- [ ] Tap Retry: "Sending...", then back to "Rejected... Paused" (re-parked after ONE attempt).
- [ ] Fix the cause (server accepts), tap Retry: row and header line disappear, change lands on the server.

**Negative**
- [ ] Outage-type stuck write (403 / 404 setup): stays "Not syncing. Still retrying.", button "Retry now", keeps retrying on the backoff.
- [ ] Offline: caption is the offline message, not tappable; parked write stays parked when back online (no auto-send).
- [ ] Sign out, sign in as another account: no parked rows.

**Edge**
- [ ] Force-close and reopen while parked: still parked at launch, no toast, not re-sent.
- [ ] Edit the same record while parked: merges into the parked write, still parked, row unchanged until Retry; Retry sends the merged version.
- [ ] Restock / second write for the same product while parked: waits (no send) until Retry.
- [ ] Two parked writes: header says 2; Retry on one leaves the other parked.
- [ ] Stuck (outage) write that later becomes rejected: parks without a second toast.

**Monkey**
- [ ] Tap Retry repeatedly and rapidly on a parked row; rotate the device; toggle airplane mode; force-close mid-retry. No crash, no duplicate or lost write, header count equals dialog rows.

## 4. Regression watch
`tst_OutboxStore` coalescing / in-flight / retryNow / wakeStuck, `tst_Gateway` stuckRows / retryStuck / relaunch cases, and `tst_StuckWrites` counting cases must stay green. Behaviour intentionally changed: rejected stuck writes no longer retry on their own.
