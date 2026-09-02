# CHECKPOINT — price_adjust tax-delta fix implemented, tested (unrun), docs updated, not yet pushed

**Session date:** 2026-09-02
**Branch:** `fix/2026-09-02-price-adjust-tax-delta` (off `main`)
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-02-pr-ci-status-comment-CHECKPOINT.md`
(unrelated prior session, different branch `feature/pr-ci-status-comment` — untouched this session).

## What this session is

Taher reported a bug via `/superpowers:systematic-debugging`: product cp 50 / sp 60 / tax 5%,
1-unit order completed (tax 3, total 63). Add a 5% discount, no qty change — expected tax 2.85 /
total 59.85 (Taher's own worked math), app showed tax still 3. Return the item afterward —
expected the order to net to exactly 0, app left a 0.15 phantom residual.

## Root cause (traced statically — no Qt toolchain in this sandbox, per standing rule)

`OrdersStore.applyAdjustment` sources a *completed* order's tax/total from
`TransactionStore.totalsForOrder(orderId)`, not a live recompute (deliberate — a completed order's
line objects can't represent mixed-vintage tax). `totalsForOrder` only summed tax from `sale`/
`return` events. `TransactionStore.recordPriceAdjust` — called by BOTH the discount-rate-edit
scanner and the price-only-modify block in `DataModel._tryAdjustOrder` — wrote `price_adjust`
events carrying revenue only, explicitly no tax field ("revenue-only" by prior design). A discount
or price edit on a *taxable* completed-order line changes net without ever touching the immutable
original sale event's stamped tax, so the order's authoritative tax stayed frozen forever. A later
full return correctly reverses tax at the live post-edit rate (that half was never wrong) — which
is exactly what turned silent staleness into a visible residual.

Two call sites, one root cause (found by tracing the function, not grepping "discount" — the
price-modify site had the identical gap, not something Taher reported but same defect class).
Full narrative: `SKILLS.md` Skill 57.

## What's implemented, this session

**`qml/model/TransactionStore.qml`:**
- `recordPriceAdjust(order, line, survivingQty, perUnitDelta, reason, note, taxRate)` — new
  optional `taxRate` param, computes `taxDelta = revenueDelta * (taxRate/100)` internally, writes
  it to the event's new `tax` field, **returns** `{revenueDelta, taxDelta}` (previously returned
  nothing).
- `totalsForOrder` — now sums `price_adjust.tax` alongside `sale`/`return` tax.
- Comments corrected (old header asserted "price_adjust has NO tax field" as fact — now false).

**`qml/model/DataModel.qml`:**
- Discount-rate-edit scanner (`_finishAdjustmentSync`) — passes the line's current `taxable`/
  `taxPercent` as `taxRate`, folds `-(revenueDelta + taxDelta)` into `refundAmount` (was just
  `discDelta`).
- Price-only-modify block — same pattern, using `d.taxable`/`d.taxPercent` (already available from
  `OrderAdjust.diffLines`, no new lookup needed).

**Tests written, hand-traced against the implementation, NOT run (no Qt toolchain — always rely on
CI per standing rule):**
- `tests/tst_TransactionStore_priceAdjustTax.qml` — new, 11 cases (function-level: tax-delta math,
  sign flips, zero/negative-rate guards, backward compat, plus the flagship `totalsForOrder`
  reconciliation tests using Taher's exact numbers, including the full-return-nets-to-zero case and
  a multi-edit accumulation case).
- `tests/tst_DataModel_discountEditTax.qml` — new, 3 cases (end-to-end via the REAL
  `DataModel._tryAdjustOrder` orchestration, not hand-derived formulas — closest automated
  equivalent to Taher's actual repro steps).
- `tests/tst_AdjustDiscountRepro.qml` — extended, 1 new case. The existing test in this file
  already covered this exact discount-scanner code path's NET side, but only ever with
  `taxable: false` — exactly why the tax-side gap slipped through a prior session that had already
  fixed the net-side version of this bug class. Closes that specific hole.

**Docs updated:**
- `SKILLS.md` Skill 57 — full root-cause narrative, the two-call-sites finding, the explicit
  scope-boundary decision (see below), the test-writing note about `tst_AdjustDiscountRepro.qml`'s
  fixture gap.
- `AGENTS.md` Current Feature Status table — new row, references Skill 57.
- `README.md` Testing section — new dated "Update 2026-09-02" paragraph, same convention as the
  existing 2026-08-29/08-30/09-01 entries.
- `docs/superpowers/test-plans/2026-09-02-price-adjust-tax-delta-test-plan.md` — full standard
  format (Skill 49): Unit / Functional-E2E / Regression / Firestore-rules(N/A) sections, then an
  On-Device Test Plan (Happy Path / Negative / Edge Cases / Affected Areas / Regression Tests).
  Index row added to `docs/superpowers/test-plans/README.md`.

## Explicit scope decision — flagged, not silently fixed or silently ignored

`qml/helper/RealisedMath.js` (`_accumulatePriceAdjust`, feeding the Analysis/Reports "Tax" column)
has the *same* defect class — never reads `price_adjust.tax` for any event kind, before or after
this fix. Its Node port (`functions/lib/realisedMath.js`) has the identical gap. This is a
pre-existing, separate latent inconsistency with its own reconciliation invariants
(`byDimension` vs `totals`, supplier-filter behavior) — deliberately NOT bundled into this branch
(per "no bundled refactoring," and to keep this fix's blast radius matched to what Taher actually
reported). **Needs a decision from Taher**: fix as a follow-up branch, or leave as a known gap for
now.

## What still needs Taher

- **CI run is the first real proof.** Every test above was written and hand-traced against the
  implementation, not executed — no Qt/qmltestrunner toolchain in this sandbox. Watch the
  `qml-tests` job on the PR this branch opens.
- **The RealisedMath.js scope decision above** — no urgency stated, but genuinely undecided.
- Everything already carried forward from the archived pr-ci-status-comment checkpoint (coverage
  reporting decision) is untouched, unrelated to this branch.

## How to resume if interrupted

Branch `fix/2026-09-02-price-adjust-tax-delta` — as of this checkpoint, all changes above are
made in the local sandbox working tree but **not yet committed or pushed**. If picking this back
up: `git status`/`git diff` to see exactly what's staged/unstaged (should match the file list
above), then commit and push per standing protocol (autonomous, PAT, `Taher (via Claude session)
<tsowner@lkdigitalworks.com>` per existing repo commit-author convention) if not already done. If
already pushed, check whether Taher opened a PR and whether CI's `qml-tests` job actually passed —
if it didn't, that's the next thing to fix, not a reason to assume the hand-traced math was wrong
without reading the actual failure first.
