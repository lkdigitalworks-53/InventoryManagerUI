# Test plan — a write that keeps failing server-side must not fail silently

**Branch:** `fix/2026-09-19-gateway-send-terminal-failure` off `main` (PR #75).

**What it does:** when a queued write has failed 5 times with a server-side status (about 3 minutes with
the current backoff), the app shows one toast ("Some changes aren't syncing. The app keeps retrying.") and
keeps a persistent caption line in every `GlassHeader` ("N change(s) not syncing. Still retrying.") until the
write leaves the outbox. Retry, backoff and dropping are unchanged.

**Source:** `docs/superpowers/DELETE-FEATURE-ROADMAP.md` item 1 (HIGH), `docs/superpowers/KNOWN-ISSUES.md`
"`Gateway._send` terminal-failure black hole". Design: `docs/superpowers/specs/2026-09-19-gateway-stuck-write-indicator-design.md`.

**Root cause:** `_send`, `_sendBatch` and `_sendDelta` send every failure that is not a recognised terminal
case to `OutboxStore.markFailed()`, which retries forever with no signal to any caller, while the stores have
already applied the change locally. The server turns every write exception into `500 write-failed`, so the
client cannot tell a poison write from a blip; an attempt count is the only client-side signal.

**Not covered by this plan / out of scope (decided with Taher, not silently dropped):** local state still
diverges from the server while a write is stuck and there is no in-app Retry / Discard (option B); the server
still returns `500` for every write exception (option C); the counter restarts with the app.

---

## 1. Unit test coverage

`tests/tst_StuckWrites.qml`, 21 cases (19 unit + 2 monkey), pure JS against `qml/helper/StuckWrites.js`:

- `isStuckStatus` (4): server-side statuses count; 0 / 1xx-3xx / 401 / 409 do not; missing or non-numeric
  status does not; boundary is exactly 400.
- `noteFailure` (8): threshold pinned at 5; below threshold never tips; the threshold failure tips exactly
  once; the status may change between failures; offline / 401 / 409 neither count nor reset; non-counting
  statuses leave no bookkeeping; items count independently; states are independent objects.
- `prune` (7): keeps stuck items still queued; drops items that left the outbox; forgets partial counts; an
  empty outbox resets everything; idempotent; a no-op on a fresh state; an id can go stuck again after pruning.

`tests/tst_Gateway.qml`, 7 of the 10 new cases (the rest are below), driving `_noteFailure` / `_pruneStuck` /
`clear()` with real `OutboxStore` items: starts at zero; below threshold does not flag or toast; a second stuck
write raises the count but not a second toast; offline / auth / conflict statuses never flag; the count drops
when a write leaves the outbox (through `_reschedule()`, the real trigger); only the writes that left are
dropped; the toast fires again after the count returned to zero.

**Monkey tests (3):** `tst_StuckWrites.qml` (2): 25 seeds x 400 random failure / prune steps checked against an
independently written reference model at every step, and "pruning an empty outbox always resets to zero"
(25 seeds x 200 random failures). `tst_Gateway.qml` (1): 10 seeds x 150 random queue / fail / send / clear
steps against the real `OutboxStore`, `stuckCount` compared with a reference count at every step.

## 2. Functional / end-to-end test coverage

None added. The XHR handlers that call `_noteFailure` cannot be driven under `qmltestrunner` (no mock HTTP
layer, see the scope note in `tests/tst_Gateway.qml`), and forcing a real persistent 4xx / 5xx against the
emulator would take 3 real minutes per case through the production backoff. The three call sites are covered
only by the on-device plan below.

## 3. Regression test coverage

Tests that exist because of the defect, so a wrong fix would fail them:

- `test_the_fifth_server_failure_flags_the_write_and_toasts_once` (Gateway) and
  `test_the_threshold_failure_tips_exactly_once` + `test_threshold_is_five` (helper): the write can no longer
  fail silently forever, and the user is told exactly once.
- `test_offline_auth_and_conflict_failures_never_flag_a_write` (Gateway) and
  `test_offline_auth_and_conflict_failures_neither_count_nor_reset` (helper): offline use must never look like
  a sync problem.
- `test_clear_resets_the_indicator_and_the_failure_counts` (Gateway): a sign-out must not leak a stale count
  to the next account.
- `test_an_id_can_go_stuck_again_after_it_was_pruned` and `test_prune_forgets_partial_failure_counts` (helper):
  a re-enqueued id starts from zero.

## 4. Firestore rules test coverage

Not applicable: no rules, function or schema change.

## What was genuinely run

- **Helper, executed for real in this session:** the 21 test bodies of `tst_StuckWrites.qml` were run in Node
  against `StuckWrites.js` (test wrapper stripped, `compare` / `verify` shimmed): 21 passed, 0 failed. Eight
  deliberate mutations of the helper were each caught (tipping on `n > THRESHOLD`, counting 409, counting 401,
  `THRESHOLD = 4`, `prune` keeping stale failures, `prune` keeping stale stuck ids, boundary at 399, counting
  status 0). This proves the algorithm and the test logic; it does not prove QML syntax or the singleton
  wiring.
- **QML under `qmltestrunner`:** no Qt toolchain in the sandbox (standing instruction). Result: pending, filled in once CI has run on the branch after `main` was merged in (the PR was unmergeable, so CI did not trigger, until then).
- **Not runnable anywhere automated:** the three sender call sites and `GlassHeader`'s caption expression.

---

## On-Device Test Plan

**Prerequisite status:** the automated coverage above covers the counting rules and the `Gateway` bookkeeping.
This section is the only coverage for the sender call sites, the toast in a real app, and the header line.

**How to make a write fail persistently (dev environment):** remove the signed-in test user's tenant membership
in the Firebase emulator so the Cloud Function answers `403` (expected `no-tenant-context`; confirm in the
`[Gateway] recordMutation failed` log line, which prints raw and effective status). Restoring the membership
lets the next retry succeed. The first toast appears after the 5th failed attempt, about 3 minutes after the
first failure.

### Happy Path

1. Healthy backend, online: edit a product, save an order. **No toast and no caption line appears** (no false
   positives).
2. Make writes fail with 403 as above, then edit a product. After about 3 minutes **one toast appears**, and
   every page with a `GlassHeader` shows "1 change not syncing. Still retrying." in the danger colour.
3. Restore the membership. Within one backoff step the write succeeds and **the caption line disappears**; the
   page subtitle is back.

### Negative Cases

4. Airplane mode for 10 minutes with several pending edits: only the existing "App is offline, no operation
   allowed." caption shows; no toast, no stuck line.
5. Force an expired token (401): the write recovers after the token refresh and the stuck line never appears.
6. Edit the same record on two devices to cause a CAS conflict: only the existing conflict toast shows; no
   stuck line.
7. Sign out while a write is stuck, then sign in as a different account: no stuck line and no leftover count.

### Edge Cases

8. Two different records stuck at once: caption reads "2 changes not syncing. Still retrying." and only one
   toast was shown in total.
9. Kill and relaunch the app while stuck: the line is gone at launch and returns about 3 minutes later if the
   write still fails (known limitation, counter is in memory).
10. Delete a product while writes fail: the line appears; the row stays gone locally (existing, documented
    divergence).
11. Offline while stuck: the offline caption wins; back online the stuck line returns if the write is still
    queued.
12. Narrow the window / large font: the caption elides without overlapping the title or the avatar.
13. A stuck CSV-import batch and a stuck order completion (`recordDelta`) each raise the line (all three
    senders are hooked).
14. Write down which pages have no `GlassHeader` (and therefore never show the line).

### Affected Areas

| File | Automated coverage | Where to look on-device |
|---|---|---|
| `qml/helper/StuckWrites.js` | `tst_StuckWrites.qml` (21, run in Node; CI for QML) | n/a (pure) |
| `qml/model/Gateway.qml` `_noteFailure`, `_pruneStuck`, `clear()` | `tst_Gateway.qml` (10 new) | cases 2, 3, 7, 8 |
| `qml/model/Gateway.qml` three sender call sites | none (XHR handlers) | cases 2, 13 |
| `qml/Main.qml` `syncStuckCount` | none (Felgo `App`) | cases 2, 3 |
| `qml/components/GlassHeader.qml` caption | none (Felgo `dp()` / `sp()`, `app` root) | cases 2, 4, 11, 12, 14 |

### Regression Tests (manual counterpart)

15. The offline caption still shows when the device is offline, and still wins over the stuck line.
16. Pages with a subtitle show it again once nothing is stuck.
17. CAS-conflict toasts and permanent bulk-import failure rollback behave exactly as before (this change does
    not touch them).
18. A write that fails a few times and then succeeds (for example a 5xx for one minute) shows no toast and no
    line.
