# On-Device Test Plan — Revenue / Profit / Tax / Discount Reconciliation

**Branch:** spec/analysis-revenue-reconciliation  **Date:** 2026-06-19
**Purpose:** Manually verify on a real device that every analysis surface now uses ONE net-revenue
definition and that revenue/profit/tax/discount reconcile across screen, breakdowns, and exports —
plus the return/exchange/modify/restock/tax-edit scenarios.

---

## The single invariant you are testing

For the **same period and the same filters**, all of these must be EQUAL:

```
On-screen Revenue hero (NET)
  == Revenue export "Net Revenue" in the Totals block
  == Total row of each Revenue export period section (that covers the orders)
  == Σ (By-category Net column)
  == Σ (By-supplier Net column)        [when every sale has FIFO supplier lineage]
```

And for Profit:
```
Profit hero  ==  Net Revenue − COGS  ==  Σ(profit by any dimension)  ==  Totals-block Profit
```

Revenue is **net = subtotal − discount, tax EXCLUDED**. Tax is reported separately, never inside revenue.

> **Display rounding note:** the on-screen hero formats currency with **no decimals** (₹39.60 shows as
> "₹40"). The **exported .xlsx writes raw numbers** (39.60). Keep the seed below all-integer so this
> never bites you; only the percent-discount case (Part 5) introduces a decimal and the plan flags it.

---

## Part 0 — Setup (clean slate + seed)

1. **Wipe** the Firestore data for your test tenant (your usual reset) and relaunch the app so all
   stores resync empty. Confirm the Analysis page shows the "No sales data yet" empty state.
2. **Suppliers** (Inventory → manage suppliers, or via first restock): create **Acme** and **Beta**.
3. **Products** (Inventory → add product). Set **Cost**, **Selling**, **Tax**:

   | Product | Cost | Selling | Taxable | Tax % | Initial stock | Supplier |
   |---------|------|---------|---------|-------|---------------|----------|
   | Widget  | 60   | 100     | Yes     | 10    | 10            | Acme     |
   | Gadget  | 30   | 50      | No      | —     | 10            | Acme     |
   | Gizmo   | 40   | 80      | Yes     | 5     | 10            | Acme     |
   | Sprocket| 50   | 100     | **No**  | —     | 10            | Acme     |

4. Make sure orders get **completed** (Analysis "Revenue/Profit" count completed orders only). If
   auto-approve is off, create each order then Approve/Complete it from the Orders page.
5. All orders are dated **today**, so use the **Day** or **Week** period on the Analysis page and they
   all fall in-bucket.

---

## Part 1 — Baseline reconciliation (discount + tax captured)

Covers original asks: *discounts, tax capture, "revenue doesn't match profit report."*

Create and complete three orders:

| Order | Lines | Discount | Gross | Discount | **Net** | **Tax** | Total (incl. tax) | COGS | **Profit** |
|-------|-------|----------|-------|----------|---------|---------|-------------------|------|------------|
| A | 2× Widget @100 | none | 200 | 0 | 200 | 20 | 220 | 120 | 80 |
| B | 2× Widget @100 + 1× Gadget @50 | flat ₹50 | 250 | 50 | 200 | 16 | 216 | 150 | 50 |
| C | 1× Gizmo @80 | none | 80 | 0 | 80 | 4 | 84 | 40 | 40 |
| **Σ** | | | **530** | **50** | **480** | **40** | **520** | **310** | **170** |

(B's tax: Widget line net = 200 − 50×200/250 = 160 → tax 16; Gadget non-taxable. So order B tax = 16.)

**Steps & expected:**

1. Analysis → **Revenue** view, period **Week**.
   - **Hero = ₹480** (net, NOT 520). ✅ guards: revenue is net, tax excluded.
   - **Subline = "incl. ₹40 tax · ₹50 discount"**. ✅ guards: tax/discount now captured/visible.
2. Revenue → **By category** bars sum to **480**; **By supplier** (Acme) = **480**.
   ✅ guards: breakdowns are net and reconcile to the hero (the old gross-vs-net mismatch).
3. Analysis → **Profit** view, **Realised**, period **Week**.
   - **Hero profit = ₹170**; margin subline present.
   - By-supplier (Acme) profit = 170; By-category profit sums to 170.
   ✅ guards: profit uses net − COGS; original discount reduced profit (B's ₹50 discount is in here).
4. **Dashboard** → Today's revenue KPI = **₹480** (matches Analysis, not 520).
   ✅ guards: dashboard switched from o.total to net.

---

## Part 2 — Export reconciliation (the headline bug)

Covers original asks: *export of analysis reports, revenue ≠ profit report, tax/discount not in exports.*

1. Analysis → **Revenue** view → tap **Export** (top-right) → pick **Excel (.xlsx)** → share/save the file
   and open it in Excel / Google Sheets.
2. In the **Analysis** sheet, verify the **Totals** block (top):

   | Metric | Expected |
   |--------|----------|
   | Gross sales | 530 |
   | Discount | 50 |
   | **Net Revenue** | **480** |
   | Tax Collected | 40 |
   | COGS | 310 |
   | Profit | 170 |
   | Margin % | ~54.8% |

3. Scroll to the period sections (Today hourly / This week daily / This month weekly / This year
   monthly). Because all orders are today, **the Total row of each = 480** (net). ✅ guards: period
   tables are net now (were `o.total` = 520 before — this is the exact screen↔export mismatch you saw).
4. **By category** section: the Net Revenue column Total = **480**, Discount column Total = **50**, Tax
   column Total = **40**. **By supplier** section: same Net total 480. ✅ guards: per-section tax/discount
   columns + reconciliation to the Totals block.
5. **Cross-check the two reports match:** export **Profit** (switch to Profit view → Export). Its Totals
   block **Net Revenue = 480** and **Profit = 170** — identical to the Revenue export's Totals block and
   to the Profit hero. ✅ guards: revenue number is the SAME in the revenue export and the profit report.

> If any period Total shows **520**, or By-category Net ≠ Totals Net, the net-revenue wiring regressed.

---

## Part 3 — Returns (the critical correctness fix)

Covers original asks: *return.* This is the bug where returns were **adding** profit instead of subtracting.

1. Orders → open **Order A** (2× Widget, completed) → reduce Widget qty **2 → 1** → Save.
   In the confirm sheet choose reason **Return**, condition **Restock**.
2. **Refund preview** should read **≈ −₹110** (1 Widget: net 100 + tax 10). ✅ guards: refund includes tax (#8).
3. After saving:
   - **Inventory:** Widget stock increased by **+1** (restock condition returns it to sellable).
   - Analysis → **Revenue** (Week): hero **480 → 380** (−100 net). Subline tax **₹40 → ₹30**.
   - Analysis → **Profit** (Realised, Week): hero **170 → 130** (profit **drops by 40**).
     ✅✅ **KEY CHECK:** profit must **DECREASE**. The pre-fix bug made a return *increase* profit
     (it would have gone to ~₹210). If profit goes UP after a return, the fix regressed.
4. Re-export Profit: Totals **Net 380 / COGS 250 / Profit 130**, and By-supplier / By-category profit
   columns each still sum to **130**. ✅ guards: the return reverses consistently across ALL dimensions
   and the period walk (the cross-section divergence found in final review).
5. **Damaged variant (optional):** repeat on another order line but choose condition **Damaged** — stock
   does **not** come back, but revenue/profit still reverse the same way.

---

## Part 4 — Add tax to a product, then modify an old order (#7)

Covers original ask verbatim: *adding tax in product and then modifying old order by increasing the items.*

1. Create & complete **Order D**: 2× **Sprocket** @100 (Sprocket is non-taxable). Expected: net 200, tax 0,
   profit 100 (cost 50×2).
2. Inventory → open **Sprocket** → edit → **enable tax, 10%** → Save.
3. Orders → open **Order D** → increase Sprocket qty **2 → 3** → Save (reason **Modify**).
4. **Expected:** the added unit pulls stock, and because the line grew, the whole Sprocket line is
   re-taxed at the **current** 10%:
   - Order D now: 3× Sprocket, net **300**, **tax 30**, total **330**, profit **150** (cost 50×3).
   - Analysis Revenue subline tax rises by **₹30**; Profit rises by **₹50** (one more unit @ 100−50).
   ✅ guards: added-after-tax-change units are taxed (was the silent "untaxed added units" bug).

> Design note: we re-tax the **entire line** when its qty grows (simpler, consistent). If you'd
> instead expect only the *added* unit taxed and the original 2 left tax-free, that's a product
> decision — tell me and we revisit.

---

## Part 5 — Exchange, price-edit (modify), percent discount

Covers original asks: *exchange, editing price, modify, percent discount.*

**5a — Price edit on a completed order (modify):**
1. Orders → open **Order C** (1× Gizmo @80) → change unit price **80 → 70** → Save (reason **Modify**).
2. Expected: a price-adjust nets revenue down by **₹10** and profit down by **₹10** (COGS unchanged).
   Revenue hero and Profit hero both drop by 10; the change shows in the realised period walk and
   the by-channel/by-staff profit too. ✅ guards: price_adjust nets into revenue AND profit.

**5b — Exchange (return one product, add another):**
1. Orders → open **Order B** → reduce Gadget **1 → 0** (return) and add **1× Gizmo @80** → Save,
   reason **Exchange**, condition **Restock**.
2. Expected: Gadget revenue/COGS reverse (net −40, cost −30); Gizmo adds (net 80, tax 4, cost 40).
   Net effect on totals is the delta of the two. Gadget stock +1, Gizmo stock −1.
   ✅ guards: exchange = return + add, both legged correctly through FIFO and the ledger.

**5c — Percent discount (decimal check):**
1. Create & complete **Order E**: 1× Gizmo @80, **10% discount**.
2. Expected: net **72**, tax **3.6**, total **75.6**, profit **32**.
   - Hero (rounded display) shows revenue including this as net; tax subline rounds 3.6 → "₹4".
   - **Export** shows raw **3.6** in the Tax column and **8** discount. ✅ guards: percent discount
     allocated pro-rata; decimals preserved in export, only the on-screen display rounds.

---

## Part 6 — Restock from a different supplier; multi-supplier attribution

Covers original asks: *restocking with other suppliers in same products; supplier breakdowns.*

1. Inventory → **Widget** → **Restock** +5 from **Beta** (cost 60). Widget now has Acme + Beta batches.
2. Create & complete **Order F** large enough to drain remaining **Acme** Widgets and dip into **Beta**
   (e.g. if Acme has 3 Widgets left after earlier orders/returns, order **5× Widget** → 3 from Acme,
   2 from Beta).
3. Analysis → **Revenue** view → **By supplier**:
   - Acme and Beta each get their share of that sale's net (3×100=300 to Acme, 2×100=200 to Beta for
     order F's lines), and the **By-supplier Net total still equals the hero**. ✅ guards: FIFO
     per-consumption net attribution; multi-supplier split in a single sale reconciles to the total.
4. Analysis → **Profit** → **By supplier**: each supplier's profit = its units × (100 − 60). Sums to
   the period profit. ✅ guards: COGS attributed per batch/supplier.
5. **Supplier filter:** open the filter sheet → set Supplier = **Beta**. Revenue hero shows only
   Beta-attributed net; toggle back to All and confirm the number grows back. ✅ guards: filtered and
   unfiltered both use net (no gross/`o.total` flip when a filter is on).

---

## Part 7 — Filter scoping of the tax/discount subline

Covers the final-review scope fix.

1. Revenue view, **Week**. Open filter → set **Channel** (or **Staff**) to a specific value that some
   orders have. Hero revenue narrows AND the **"incl. ₹X tax · ₹Y discount" subline narrows with it**
   (tax/discount only for the filtered orders). ✅ guards: subline scoped to the same orders as the hero.
2. Set a **Category** or **Supplier** filter. The tax/discount **subline hides** (order-level tax/discount
   can't be split to one category/supplier). ✅ guards: no misleading whole-order tax under a line filter.
3. **Export under a Staff filter:** export Revenue while a staff member is selected. The Totals block
   Net Revenue must equal the sum of the By-category/By-supplier Net sections **for that staff only**
   (not the whole tenant). ✅ guards: export Totals honor staff/category scope (and a staff-role user
   can't see tenant-wide totals — RBAC).

---

## Part 8 — Regression sanity (unchanged surfaces)

These weren't supposed to change — confirm they still behave:

1. **Value** view: hero = Σ(open batch qty × unit cost); by-supplier/by-category value bars present.
2. **Current** view: stock counts, low/out badges, totals card.
3. **Sold** / **Purchased** views: unit counts (not currency); exports stay unit-based with **no** tax/
   discount columns. ✅ guards: only Revenue/Profit gained money columns.
4. **Product details stock edit:** Inventory → edit a product's **Stock** directly (not via Restock).
   Value/Current update and the batch ledger reconciles (no drift, no crash). ✅ guards: StockReconcile.

---

## Quick pass/fail checklist (record per build)

- [ ] Revenue hero = net (₹480 at baseline), NOT tax-inclusive (520)
- [ ] Subline "incl. ₹40 tax · ₹50 discount" present
- [ ] Dashboard today = Analysis revenue
- [ ] Export Totals block Net = hero = period Totals = Σ category = Σ supplier
- [ ] Revenue export and Profit export show the SAME Net Revenue
- [ ] Tax & Discount columns populated and reconcile in exports
- [ ] **Return DECREASES profit** (not increases) and refund includes tax
- [ ] Add-tax-then-increase-qty taxes the line
- [ ] Price edit nets revenue & profit down
- [ ] Exchange legs both return + add
- [ ] Multi-supplier sale splits and reconciles by supplier
- [ ] Channel/staff filter narrows hero + subline together; category/supplier hides subline
- [ ] Staff-filtered export totals are staff-scoped, not tenant-wide
- [ ] Value/Current/Sold/Purchased unchanged; stock edit reconciles
