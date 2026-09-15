# CHECKPOINT — async re-entrancy bug sweep, tracking doc written, ready to push

**Session date:** 2026-09-15
**Branch:** `audit/2026-09-15-async-reentrancy-sweep`, off `main` (fresh pull; PR #70 not yet merged)
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-02-price-adjust-tax-delta-CHECKPOINT.md`
(same stale-CHECKPOINT situation as PR #70's branch hit — `main`'s CHECKPOINT.md was still the
2026-09-02 one, unarchived, since PR #70 hasn't merged yet. Archived a second copy here; whichever
PR merges first makes the other's archive step a no-op, not a conflict.)

## What this session is

Follow-up to PR #70 (order-completion double-submit fix). Taher asked (`/superpowers:requesting-code-review
/ponytail:ponytail-review`, caveman mode) for: (1) a review of PR #70's diff, and (2) a full
workflow/functionality/code-trace sweep of the rest of the app for the SAME bug pattern, with a
severity-ranked tracking document as the deliverable.

## PR #70 review (done directly — no subagent-dispatch tool in this environment)

**Correctness:** holds up, 1025/1025 CI. Two already-flagged gaps, nothing new.
**Ponytail (over-engineering):** `net: 0 lines possible. Lean already. Ship.` — `_completingOrderIds`
as a map (not a scalar) is deliberate (`_approveAllPending` can have two DIFFERENT orders genuinely
in flight under a double-click, a scalar would miss that), and the busy-state wiring mirrors 4
existing dialogs' exact idiom, no new abstraction invented.

## The sweep

Checklist used (now written into the tracking doc for reuse): does the action's `DataModel`
handler call a callback-TAKING Store/Gateway function (real network round trip) vs a callback-less
local-apply helper (synchronous, offline-first, not at risk)? Does the UI wait for a real
completion signal or fire-and-close immediately? Is there a `DataModel`-layer guard independent of
the UI? Is anything wrongly relying on `LockManager` (which re-grants the same `actorUid` by
design, so it never stops same-user re-entrancy)?

Mechanically: grepped every `BottomSheet`-derived dialog (20 total) for `onPrimaryClicked` presence
vs `busy`-usage absence to get a short candidate list, then traced each candidate's signal chain
(dialog signal → `Main.qml` → `logic.*` signal → `DataModel.on*` handler → the Store function it
calls) to separate genuine instances from false positives.

## Findings — full detail in `docs/superpowers/ASYNC-REENTRANCY-BUGS.md`

**Critical:**
- **C-1** `ConfirmReturnSheet` → `DataModel._tryAdjustOrder`: exchanges/quantity-increases on a
  completed order can double-deduct stock and double-record the sale — same root cause as the
  original bug (`_tryAdjustOrder` has zero in-flight guard, and DOES call the callback-taking
  `deductStock` for added-quantity lines), reached through a different dialog. Worse in one way:
  `ConfirmReturnSheet.onClosed` releases the `LockManager` lock immediately on close, before
  `_tryAdjustOrder` has done any real work — actively inviting a second edit rather than merely
  failing to prevent one.
- **C-2** `NewOrderDialog`: double-tapping "Create Order" has no guard at all;
  `OrdersStore.addOrder` depends on `nextOrderId`'s genuine server-coordinated async ID mint (no
  local-apply shortcut). Two overlapping submits mint two different order IDs — duplicate order
  records, no CAS/dedup to catch it. With `autoApproveEnabled` on, BOTH duplicates also get
  auto-completed via `_tryCompleteOrder`, so this single easy-to-trigger double-tap can ALSO
  double-deduct stock — the easiest-to-hit instance found, no unusual timing needed, just a normal
  double-tap on the app's most common action.

**Medium:**
- **M-1** `InviteMemberDialog`: no busy state, no completion feedback of ANY kind (doesn't even
  close itself, no error/success message, no `Connections` back to `AuthService` at all — confirmed
  zero matches for any of those in the file). Real network call
  (`AuthService.inviteMemberToCurrentTenant`). Data-correctness risk depends on server-side invite
  idempotency, not verified this session (out of scope — no `functions/` invite-handler code
  traced).

**Low:** `OrdersPage._approveAllPending()`'s banner still has no busy UI (already flagged in PR
#70/Skill 60 — cross-referenced, not a new finding, data-safe post-fix).

**Checked, not affected** (recorded for credibility/future reference, not just positive findings):
`EditProductDialog`, `StaffDetailDialog`, all delete flows (synchronous/idempotent, no genuine
async dependency for their own completion) — and confirmed `RestockDialog`/`AddProductDialog`/
`AddStaffDialog`/`ImportPreviewDialog`/`MemberManagementDialog` already use `busy` correctly
(the last one via a bound `AuthService.membersBusy` property rather than manual toggling — also a
valid shape).

**Not yet swept** (flagged, not silently skipped): `SupplierStore`'s own dialog, server-side
idempotency for create-type mutations in general, bulk operations beyond `_approveAllPending`/
import.

**No fixes attempted this session** — audit/tracking only, per the explicit ask. C-1 and C-2 are
flagged as the highest-priority follow-up work, with C-2 likely the more urgent given how trivially
it triggers in ordinary use.

## Docs written/updated this session

- **New:** `docs/superpowers/ASYNC-REENTRANCY-BUGS.md` — the severity-ranked tracker itself.
  Originally drafted at repo root as `KNOWN_ISSUES.md` before discovering
  `docs/superpowers/KNOWN-ISSUES.md` already exists as an established general (non-severity-ranked)
  deferred-issues log — relocated to sit alongside it with a clearly distinct name, rather than
  creating a confusing near-duplicate path.
- `docs/superpowers/KNOWN-ISSUES.md` — added a short cross-reference entry at the top pointing to
  the new tracker, rather than duplicating detail into the flat log.
- `AGENTS.md` — added a "See also" pointer to both tracking docs near the top of the file.
- `SKILLS.md` — appended Skill 60 (this session's numbering; WILL collide with PR #70's own Skill
  60-62 on merge — renumber per this file's own established append-only convention, whichever PR
  merges second).
- `docs/superpowers/specs/2026-09-02-price-adjust-tax-delta-CHECKPOINT.md` — archived (see note at
  top of this file).

## Status / next steps

- [x] Reviewed PR #70 directly (no subagent tool available in this environment).
- [x] Full sweep completed — 20 dialogs checked, 2 DataModel orchestration functions traced in
      depth, findings ranked by severity with full code traces.
- [x] Tracking document written, placed correctly relative to the existing general log.
- [x] Docs cross-referenced (AGENTS.md, KNOWN-ISSUES.md, SKILLS.md).
- [ ] **Next: commit and push**, open a PR (docs-only branch — CI will still run but nothing here
      should break it).
- [ ] Not building/running the app this session.
- [ ] **Follow-up session priority: fix C-1 and C-2** using the same two-layer pattern as PR #70
      (`DataModel`-layer in-flight guard + `busy`-state UI wiring). Not attempted here — this
      session was scoped to finding and documenting, not fixing.
