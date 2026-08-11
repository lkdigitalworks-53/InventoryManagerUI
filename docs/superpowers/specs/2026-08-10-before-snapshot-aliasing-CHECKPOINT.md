# Session Checkpoint — `applyAdjustment` before/after snapshot aliasing bug

**Started:** 2026-08-10
**Branch:** `fix/async-write-sequencing-review-fixes` (existing, unmerged — Taher's explicit choice,
so the fix lands on the same branch he's about to test on-device, rather than opening a new PR
boundary for a one-line root-cause fix)
**Status:** Fix implemented, test written (unrun — no qmltestrunner in sandbox), docs updated.
Committed and pushed pending Taher's go-ahead in this session.

## Trigger

Taher's own manual testing of this branch (blocked by this bug, which is why this checkpoint
exists): add order → complete it → open it → adjust price → save. Got a spurious "This order was
updated elsewhere — your change didn't save" toast, with nobody else touching the order. Reported
`applyAdjustment` section appearing in the `before` object passed to `recordMutation`, causing a
failed comparison against the current DB snapshot.

## Step log

1. Cloned `InventoryManagerUI` fresh, checked out `fix/async-write-sequencing-review-fixes`
   (confirmed not merged into `main`, no upstream changes since — re-verified at the start of the
   implementation turn too, HEAD `070edad` both times).

2. **Root cause investigation** (`superpowers:systematic-debugging`). Traced `applyAdjustment`
   (`qml/model/OrdersStore.qml:600`): `before = Object.assign({}, o)` (shallow copy) followed by
   `o.adjustments.push(adjustmentRecord)` (in-place mutation). Since `Object.assign` only copies
   top-level properties, `before.adjustments` and `o.adjustments` were the same array reference —
   the push leaked the new adjustment into `before`. Traced that `before` forward to
   `Gateway.recordMutation` → `OutboxStore` → `functions/lib/gatewayLogic.js:154`'s
   `_deepEqual(current, params.before)` CAS check inside `applyMutation`'s transaction — confirmed
   this is exactly what rejects the write (409, `txn.set` never runs, nothing persists — not just
   the adjustment, the WHOLE mutation including the new price). Also traced the client-side recovery
   path (`OrdersStore._onMutationConflicted`) to confirm the toast Taher saw is the expected,
   working reaction to a — in this case false — conflict.

3. Built an isolated Node reproduction (not part of the repo, throwaway) mirroring the exact
   buggy logic to confirm the hypothesis mechanically before proposing a fix. Confirmed: buggy
   version leaves `before.adjustments.length === 1` (should be 0, pre-mutation); a corrected
   version leaves it at 0.

4. **Full-codebase sweep** for the same pattern, per Taher's ask ("review whole project code").
   Read all 25 `Object.assign` call sites across `qml/model/*.qml`, `qml/pages/NewOrderDialog.qml`.
   Grepped specifically for nested-field `.push()`/`.splice()` (`X.Y.push(`) project-wide — exactly
   one hit, the bug above. Everything else either only reassigns primitive fields after a shallow
   copy (safe), or already builds a new object/array and replaces the array slot rather than
   mutating in place (`StockBatchStore`, `OutboxStore`, `Gateway.qml`, `AuthService.qml`,
   `NewOrderDialog.qml` — established, correct convention). Also confirmed the codebase's data
   shapes are JSON-round-trip-safe (no `Date`/Timestamp/function fields ever persisted; `new Date()`
   only appears in transient calculations), in case a blanket deep-clone approach was chosen instead.

5. Presented findings to Taher with three options (A: one-line targeted fix via `.concat()` instead
   of `.push()`; B: broader defensive `_deepClone()` helper across all mutator functions even the
   ones confirmed safe; C: document the convention in AGENTS.md/SKILLS.md) and an explicit
   recommendation (A+C, not B — the sweep found exactly one real instance, and
   `systematic-debugging`'s "no bundled refactoring" principle argues against rewriting 6+ working
   files to guard against a bug that isn't actually present elsewhere).

6. Taher chose **A+C**, and to commit/push directly on this branch (wants to test it end-to-end,
   was blocked by this exact bug). Proceeded.

7. **Implemented the fix** (`qml/model/OrdersStore.qml`): replaced
   `o.adjustments.push(adjustmentRecord)` with
   `o.adjustments = (Array.isArray(o.adjustments) ? o.adjustments : []).concat([adjustmentRecord])`.
   Re-verified against the same repro scenario using the exact fix code (not just the generic
   JSON-clone version) — all 5 assertions pass, including that the original input object's
   `adjustments` array is left completely untouched (no in-place mutation anywhere in the new code
   path).

8. **Wrote `tests/tst_OrdersStore_applyAdjustment.qml`** (7 test cases), mirroring the structure and
   conventions of `tests/tst_OrdersStore_normalization.qml` and `tests/tst_Gateway.qml`. Exercises
   the REAL `OrdersStore.applyAdjustment` → `Gateway.recordMutation` → `OutboxStore.enqueue` path
   (gateway-mode, no `AuthStore.idToken`, so no real network — same safe pattern `tst_Gateway.qml`
   already established) and asserts directly on `OutboxStore.items[0].before`/`.after`:
   - `before` excludes the new adjustment (the core regression)
   - `after` includes it
   - `before`/`after` `.adjustments` are different array references (the fix's exact invariant)
   - a SECOND adjustment on an order that already has one: `before` shows exactly the one prior
     entry (not zero, not two), `after` shows both in order
   - local order state (products, total, adjustments) updates correctly — fix didn't change
     observable behavior
   - unknown order id is a no-op (no mutation recorded)

   **Not run in this sandbox** — no Qt/qmltestrunner toolchain available, same status as every
   other client-side test written this session. Needs a local `qmltestrunner` pass. Also not picked
   up by CI automatically on this push — `.github/workflows/checks.yml` triggers on `pull_request`
   and `push: [main]` only, not a plain push to a feature branch.

9. Ran the project's `qt-qml-review` deterministic lint script against the changed file and the new
   test file. All findings on the changed region (`OrdersStore.qml:628-648`) and in the new test
   file are pre-existing project-wide conventions (this codebase uses `var` throughout; `TestCase`
   files don't use `id: root`; two `JS-2` "loose equality" flags in the test file are false
   positives — the linter's substring match on `!=` triggers on `!==`, confirmed by direct
   inspection) — verified by running the same linter against the already-merged
   `tst_OrdersStore_normalization.qml` and `tst_Gateway.qml` as a baseline; identical finding
   categories appear there too. No new, actionable findings introduced.

10. **Docs (Option C)**:
    - `SKILLS.md`: added a caveat to Skill 36's "shallow-copy stores are structurally immune"
      claim, cross-referencing this bug so it doesn't read as a blanket safety claim. Appended a
      new **Skill 37** with the full mechanism, the general rule (reassign, never mutate a field a
      snapshot still references), why the narrow fix was chosen over a broad rewrite, and the
      dormant related fragility in `_normalizeOrder`'s adjustment-record sharing (left alone,
      flagged, not fixed — no evidence it's live).
    - `AGENTS.md`: cross-referenced the fix in the Compliance & Audit Agent's CAS/concurrency note;
      added the new test file + updated the suite count (17 → 18) in the Testing & QA Agent section.
    - `README.md`: added a chronological "Update 2026-08-10" entry to "Concurrency & Conflict
      Resolution", matching the existing 2026-08-06/2026-08-08 entries' format.

    **Noticed but NOT touched** (flagging for Taher, out of scope for this fix): `SKILLS.md`'s
    numbering has a pre-existing inconsistency — the block covering `ProfileSettingsMath.js`/
    `saveProfileSettings` (dated 2026-07-31, and referenced as "Skill 36" by `AGENTS.md`'s feature
    table) has no `## Skill N` header at all; it trails at the very end of the file, after the
    section that's actually headed `## Skill 36: Async write sequencing...`. Skill 37 above is
    numbered assuming the async-write-sequencing section is the last **headed** skill — didn't
    renumber or relabel the orphaned block, since that's an unrelated pre-existing doc issue, not
    part of this fix.

11. Committed and pushed to `fix/async-write-sequencing-review-fixes` per Taher's explicit
    instruction (same branch, since he wants to test it end-to-end now that it's unblocked).

## What's NOT done / needs Taher

- **On-device**: run `qmltestrunner -input tests -platform offscreen` (or the Windows/Felgo
  invocation in `AGENTS.md`'s Testing & QA Agent section) and confirm all 7 new cases pass, plus
  the full existing 140+ baseline still passes.
- **The original manual repro**: add order → complete → adjust price → save, on a real device/
  emulator against this branch, to confirm the toast no longer fires and the price actually
  persists this time.
- **Not addressed, flagged only**: the dormant adjustment-record-object sharing in
  `_normalizeOrder`'s `.slice()` (Skill 37, "related fragility" paragraph) and the SKILLS.md
  numbering gap above. Neither blocks this fix; both are one-line pointers for a future session if
  they ever become live.
