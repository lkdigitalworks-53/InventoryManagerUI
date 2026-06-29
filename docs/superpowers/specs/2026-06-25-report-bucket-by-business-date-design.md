# Reports bucket by business date, not ledger write-time

**Date:** 2026-06-25
**Status:** Approved
**Author:** debugging session (systematic-debugging → brainstorming)

## Problem

The Analysis page reports (Purchased, Revenue, Sold, Profit-Realised) ignore the
Day / custom date filter: with no orders placed *today*, every report still shows
all-time numbers.

### Root cause (confirmed against live Firestore — tenant `t_fVkwqcxmuIZ1XIcvc1ASI2QowFj1`)

Completed sales store two dates:

```
orders/ORD-001:        date: "2026-06-24"                 ← business date (the sale day)
transactions (sale):   date: "2026-06-24",
                       timestamp: "2026-06-25T04:14:…Z"    ← write instant (when recorded)
```

Every analytics walker buckets on:

```js
new Date(e.timestamp || e.date)   // prefers the WRITE instant
```

So events bucket by *when the row was written* (today), not *when the sale
happened* (yesterday). With "Day" selected, all events match today because they
were all recorded today — even though the orders are dated June 24. Hence
"no orders today, but reports show all-time numbers."

### Why the earlier fix didn't catch it

The prior session fixed a real but different defect (custom-date UTC-vs-local
parse) and added `tst_DateFilterRepro`. Those fixtures put `timestamp` and `date`
on the **same** day, so the `timestamp || date` preference was never exercised on
a split. Real / imported / back-dated orders have them on **different** days.
The test did not mirror production data. This spec closes that gap.

## Solution

### Core change — one shared helper

Bucket on the business `date`, keeping real hour-of-day only for live (same-day)
events so the hourly Day view retains intra-day shape:

```js
// eventDate(e): the instant an event should bucket at.
//  - day/week/month/year membership always comes from the business `date`
//  - the hourly Day view keeps the real clock time from `timestamp` ONLY when
//    timestamp falls on the same business day; otherwise day-start (00:00 local).
function eventDate(e) {
    var biz = e.date ? new Date(e.date + "T00:00:00") : null   // local midnight
    var ts  = e.timestamp ? new Date(e.timestamp) : null
    if (biz && !isNaN(biz.getTime())) {
        if (ts && !isNaN(ts.getTime())
            && ts.getFullYear() === biz.getFullYear()
            && ts.getMonth()    === biz.getMonth()
            && ts.getDate()     === biz.getDate())
            return ts            // live sale → real hour-of-day
        return biz               // back-dated / imported → the business day
    }
    return ts                    // no date → fall back to write instant
}
```

Accrual semantics: a sale placed today but dated to a past day counts on its past
business date; returns/adjustments carry their own `date` (the day they happen),
so they count on that day.

### Helper placement (no new file)

Add `eventDate` to `qml/helper/OrderMath.js` — already imported by RealisedMath,
TransactionStore, and SalesPage. BreakdownMath gets one new
`.import "OrderMath.js" as OrderMath` line.

### Scope — the bucketing sites

Swap `new Date(e.timestamp || e.date)` → `OrderMath.eventDate(e)` at each:

| File | Sites |
|------|-------|
| `qml/helper/RealisedMath.js` | `_passesScope`, `bucketWalk` |
| `qml/helper/BreakdownMath.js` | `_sold`, `_purchased` |
| `qml/model/TransactionStore.qml` | `between`, `bucketsForFiltered` |
| `qml/pages/SalesPage.qml` | purchase predicate (`_rebuildBreakdown`), `_profitBucketWalk`, `_passesCrossFilters`, `_consumptionBucketWalk` |

The `timestamp || date` **sorting** sites (`TransactionStore:32`, `ActivityLog:53`)
are intentionally left alone — sorting the audit log by write-time is correct.

## Testing

Close the same-day-fixture gap with explicit split cases:

1. `eventDate()` unit test — three branches: live (same-day → returns timestamp),
   back-dated (date ≠ timestamp day → returns local-midnight business date),
   missing `date` (→ falls back to timestamp).
2. Sale `date:"2026-06-24"`, `timestamp:"2026-06-25T…"`, `now = Jun 25`:
   **Day total = 0**; Week / Month / Year include it.
3. Live same-day sale → still lands in its real hour bin on the Day view.

Tests use the existing `qmltestrunner` headless pattern (pure JS, injected `now`).

## Out of scope

- `BreakdownMath._revenue` already buckets on `ord.date` (order-based path) — no change.
- The custom-date local-midnight TZ fix from the prior session stays as-is.
- No change to how events are written (`date` / `timestamp` stamping is correct).
