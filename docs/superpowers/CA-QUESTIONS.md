# Questions for the Chartered Accountant (CGST Rule 56(2) stock register)

Status: **researched and answered by a reviewer, 2026-11-21. Still not sent to a CA.** Every "Answer" line below now holds a *research answer* written by Claude acting as a CA-style reviewer, from primary sources (the text of Rules 56 and 57, sections 35 and 36, the GST Council press release of 8 October 2026, CBIC circulars; see section 9). It is **not professional advice and not a CA's answer**. Items marked "Real CA still needed: Yes" should still go to a real CA. The original draft of 2026-11-18 is in git history. The answers in section 1 are still Taher's own product decisions; the review adds a verdict on each.

How to use this document: each question says why we ask, what the app does today (our default), and which piece of work waits for the answer. Questions marked **BLOCKING** stop a feature from being built. Questions marked **VALIDATE** only ask the CA to confirm a default the app already uses; if the CA never answers, the default stays. Please put the CA's answer in the "Answer" line and the date, and keep this file as the record. How to read the research answers: each ends with a **verdict** on our default (KEEP, CHANGE or ADD), a **confidence** (High = verified in the primary text, Medium = reasoned from it, Low = not verified) and whether a **real CA is still needed**. [S1] to [S13] refer to section 9.

Background in two sentences for the CA: Karobar is a mobile inventory and billing app for small vendors. It keeps an append-only stock ledger (one row per stock movement, written by the server in the same transaction as the stock change, never edited or deleted) so that a stock register in the form of CGST Rule 56(2) can be produced.

What the register must show, as we read Rule 56(2): opening balance, receipts, supplies, goods lost, stolen, destroyed, written off, or disposed of by way of gift or free sample, and the closing balance, including raw materials, finished goods, scrap and wastage. Composition dealers (section 10) are excluded from the rule.

## 1. Decisions already taken (by Taher, not by a CA)

| # | Decision | Date | Note | Review verdict (2026-11-21) |
|---|---|---|---|---|
| T1 | A manual stock correction ("adjustment") is allowed and its reason is optional. | 2026-11-13 | Taher first said "not manual"; he accepted the recommendation that it keeps opening + in - out = closing. See CA-8. | **CHANGE** for negative adjustments: a reasonless shortage is the "goods not accounted for" case of section 35(6). Positive adjustments stay optional. See CA-8. |
| T2 | The value of lost or gifted goods is the product's cost price, stamped by the server. No GST detail is kept on purchases yet. | 2026-11-13 | See CA-9 and CA-10. | **Stopgap, label "approx. cost".** ITC reversal needs the purchase price excluding GST and the GST rate, which the app does not hold. See CA-9, CA-10. |
| T3 | A reason is mandatory where the event is sensitive: loss, theft, destroyed, write-off, gift (at least 3 visible characters). Free sample, adjustment, receipt, sale and return keep it optional. | 2026-11-13 | Based on section 17(5)(h). See CA-11. | **KEEP.** Verified: the 8 Oct 2026 Council recommendation is not yet law, so credit on free samples is still blocked. See CA-11. |
| T4 | The app is built for any kind of vendor, not only the first customer. | 2026-11-13 | See CA-15 and CA-16. | **KEEP with a scope statement:** traders and retailers, single place of business. Manufacturers and multi-place vendors are not supported yet. See CA-16, CA-17. |
| T5 | Imported (CSV or marketplace) orders count as `sale` in the register when the order is completed. | 2026-11-18 | New in slice S2d-2. See CA-7. | **KEEP** and add a visible shortfall flag when stock was short. See CA-7. |

## 2. Questions that BLOCK work

### CA-1 BLOCKING: column layout of the printed register
**Ask:** Which ledger events go in which column? We propose:

| Column | Ledger kinds | Direction |
|---|---|---|
| Opening balance | (computed) | n/a |
| Receipts | `receipt` (purchase, restock, opening stock) | in |
| Customer returns | `sales_return` | in |
| Supplies | `sale` | out |
| Lost, stolen, destroyed, written off, gift, free sample | `loss`, `theft`, `destroyed`, `write_off`, `gift`, `free_sample`, each kept visible by type | out |
| Stock correction | `adjustment`, net | in or out |
| Closing balance | (computed) | n/a |

Is this the layout an officer expects? Should customer returns be a separate inward column (as above) or deducted from supplies?
**Why:** The server already returns in and out per kind, so the layout is only presentation. Building the printable register in the wrong layout means rebuilding it.
**Waits:** S4c (printable and exportable register).
**Answer (research, 2026-11-21):** No statutory layout exists. Rule 56(2) prescribes the *content* of the stock account only: opening balance, receipt, supply, goods lost / stolen / destroyed / written off / disposed of by gift or free sample, and the balance of stock including raw materials, finished goods, scrap and wastage [S1]. The proposed columns cover all of that, so the layout is acceptable. Four refinements, none of them legal requirements, all to make the register tie to the returns and survive an officer's questions:
1. Keep customer returns in their own inward column, **and** show a derived line *Net supplies = Supplies - Customer returns*. GSTR-1 supplies are net of credit notes, so the net line is the one that reconciles.
2. Split *Stock correction* into two columns, *gain* and *shortage*. Never show only the net: a shortage is what an officer tests (see CA-8).
3. Add a *Returns to suppliers* column once CA-19 is built, and an *Opening stock entered* line once CA-3 is built.
4. Keep every outward kind visible by type, as proposed (gift and free sample are taxed differently, see CA-11 and CA-12).
**Verdict on our default:** KEEP, with the refinements above. **Confidence:** High on content, Medium on presentation. **Real CA still needed:** No for legality; show the CA one real printout once the page exists.
**Basis:** [S1]. Unblocks S4c (print layout) provisionally.

### CA-2 BLOCKING: period and form of the register
**Ask:** (a) Which periods must be producible: month, quarter, financial year, any date range? (b) Is one register per product enough, or must it be grouped by HSN code or by goods category? (c) Is a PDF or a spreadsheet export acceptable, and does it need a signature or a certification line?
**Why:** The app computes a per-product register for any date range using fixed IST midnights. Grouping or a different form changes what S4c builds.
**Waits:** S4b-2 (register page) layout, S4c.
**Answer (research, 2026-11-21):** (a) No period is prescribed. What the law needs is an account that can be produced on demand (Rule 56(18), Rule 57(2)) [S1][S2]. Month and quarter match GSTR-3B and the quarterly option, the financial year matches the annual return, and a custom range is what an audit asks for, so keep all four. (b) Per product is the right working unit. Rule 56(2) is not organised by HSN code or category. HSN grouping is useful because the annual-return summaries are HSN based, so offer HSN as a column and filter, not as the structure; it needs the pending tax-identity work (P2) to hold the HSN. (c) No form is prescribed, so a PDF for printing and a spreadsheet for data are both fine. One point to add: electronic records must be authenticated by a digital signature (Rule 56(15)), and on demand must be produced "duly authenticated" in hard copy or any electronically readable format (Rule 57(2)) [S1][S2]. Put a line *Authenticated by (name, designation), date* on the printout and a header with legal name, GSTIN, address of the place of business (Rule 56(5)(c)), period, time generated and page n of N.
**Verdict on our default:** KEEP (a) and (b); ADD the authentication line and header to (c). **Confidence:** High on (a) and (b), Medium on (c). **Real CA still needed:** Yes, one narrow point: is a signed printout accepted in practice instead of a digital signature certificate on every export?
**Basis:** [S1][S2]. Unblocks S4b-2 layout and S4c provisionally.

### CA-9 BLOCKING (for valuing losses): is the cost tax-inclusive or tax-exclusive?
**Ask:** To reverse input tax credit on lost, stolen, destroyed or gifted goods, which value do you need: the purchase price excluding GST, or including it? Does the register need the GST rate and the tax amount per row, or only the taxable value?
**Why:** Purchases in the app carry no GST detail today, so the product "cost price" may or may not include tax. We stamp that figure on loss rows. If the CA needs tax-exclusive value and rate, the product and purchase screens need a tax field first.
**Waits:** S2e-2 (pickers that record loss and gift) and the value column of the register.
**Answer (research, 2026-11-21):** Section 17(5)(h) blocks input tax credit on goods lost, stolen, destroyed, written off or disposed of by gift or free sample, so credit already taken on those goods must be reversed. The amount reversed is the credit *actually availed* on the purchase, a tax amount per tax head (CGST, SGST, IGST, cess), declared in GSTR-3B Table 4(B)(1) [S10]. Therefore the base is the purchase price **excluding GST**, and the GST rate (or the tax amount) of the purchase invoice is needed. If the vendor bought without credit (unregistered supplier, composition supplier, or credit not claimed) the reversal is nil. For stock valuation the same split applies: cost excludes GST when the credit is claimed and includes it when it is not. Rule 56(2) itself needs no value, rate or tax amount per row; those are for the reversal.
So a single "cost price" of unknown tax status cannot produce the reversal figure. It is fine as an *approximate cost* label; it must not be presented as "ITC to reverse". Partial damage (value reduced, not zero) is litigated: reversal "to the extent of the loss in value" has been upheld in a recent ruling [S13]; this is the one part to put to a CA.
**Verdict on our default (T2):** CHANGE, later. Keep the cost stamp as a stopgap labelled "approx. cost"; add a purchase GST rate and an "ITC claimed" flag on the purchase batch before any ITC figure is shown. **Confidence:** High on the law, Medium on partial-loss cases. **Real CA still needed:** Only for partial loss and expiry cases.
**Basis:** [S10][S13]. Blocks S2e-2 only for the ITC figure, not for recording the events.

### CA-10 BLOCKING (for valuing losses): which cost method?
**Ask:** For valuing goods lost or gifted, is it acceptable to use the product's current cost price, or must it be the actual purchase cost of the batch (FIFO), or a weighted average?
**Why:** Today the value is the product's current cost, which is approximate when the same product was bought at different prices. The FIFO batch cost is available in the app but not wired to the ledger.
**Waits:** S2e-2, S3 (`batchRef`: linking each sale to the batch it consumed).
**Answer (research, 2026-11-21):** GST law prescribes no costing method for the register; Rule 56(2) is quantity led [S1]. For the reversal, what matters is the tax on the invoice(s) the lost units came from. So the batch the units came from (FIFO or specific identification) is closest to "actual"; weighted average is the usual accounting fallback when units cannot be traced to an invoice (accounting standards allow FIFO or weighted average, not LIFO; from my knowledge, not re-verified this session). The product's current cost price is only an estimate: it moves whenever the vendor re-prices.
**Verdict on our default:** CHANGE, later. Stamp the value from the FIFO batch(es) the units belong to, in the same server transaction, and fall back to the product cost when no batch exists. This needs the batch to carry the purchase GST rate (CA-9). **Confidence:** Medium. **Real CA still needed:** Yes if the CA prefers weighted average; whichever is chosen must be used consistently and written down.
**Basis:** [S1]; accounting-standard point from my knowledge. Unblocks S2e-2 with the product-cost stopgap.

## 3. Questions that VALIDATE a default

### CA-3 VALIDATE: opening stock of a new product
**Ask:** When a vendor creates a product with starting stock, is it acceptable to show that quantity inside "Receipts", or must it be a separate "Opening balance" entry?
**Why:** The ledger has no `opening` kind, so it is stored as a `receipt` (same as before). The register cannot tell it from a purchase. A separate kind is a small server change, but it must be decided before the register is printed.
**Default:** `receipt`.
**Answer (research, 2026-11-21):** Rule 56(2) lists *opening balance* and *receipt* as separate particulars [S1]. Stock a vendor already had when they started using the app is not a purchase of the period. If it is booked as a receipt, the Receipts column exceeds the purchases in the purchase register and inward returns, and the first period shows a difference an officer will ask about. This is a reconciliation argument, not a statutory one.
**Verdict on our default:** CHANGE. Add a ledger kind `opening` (stock in). Product creation asks one question: "Stock you already had" (opening) or "Just bought" (receipt). In the register, `opening` dated before the period start sits inside the Opening balance; inside the period it is a separate line *Opening stock entered*. Cost today is low: the app is still in dev state, so there is no existing data to migrate. **Confidence:** Medium. **Real CA still needed:** Yes, a quick confirmation. Note this reverses the earlier design decision Q2 ("initial stock is a receipt").
**Basis:** [S1]; reconciliation reasoning.

### CA-4 VALIDATE: damaged customer returns
**Ask:** A customer returns goods and they are damaged. Do we record (1) a return in and then a destroyed or written-off row out, or (2) nothing?
**Why:** Today nothing is recorded for the damaged part (design item K10). Stock is not raised for a damaged return, so the register does not show stock that is not on the shelf (the first draft said it did; corrected in the 2026-11-21 review), but supplies stay gross and the written-off units never appear.
**Default:** no row.
**Waits:** S2e-2 (return screen choice).
**Answer (research, 2026-11-21):** Record (1): a return in, then a write-off out, with a reason. Correction to the question's own "Why": the code does **not** credit stock for a damaged return (DataModel.qml, `restock = condition !== "damaged"`; stock "already reflects the sale"), so the register does not show stock that is not on the shelf. The real gaps are different: (a) Supplies stay gross although the customer got a refund or credit note, so the register no longer ties to GSTR-1 net supplies; (b) the damaged units never appear in the *written off* column, so there is no evidence for the credit reversal that section 17(5)(h) may require on written-off goods.
Right record: `sales_return` +N, then `write_off` (or `destroyed`) -N, valued at cost, reason filled by the app ("Returned damaged - order X"). Closing stock is unchanged, supplies net correctly, and the loss is visible.
**Verdict on our default (no row):** CHANGE. **Confidence:** High on the register logic, Medium on the credit effect on damaged returns. **Real CA still needed:** Yes, for whether credit must be reversed on a damaged return.
**Basis:** code check (DataModel.qml lines 1366 and 1575); [S4] for the loss-versus-unaccounted logic. This is slice S2e-2 (return screen).

### CA-5 VALIDATE: reopened order and rolled-back exchange
**Ask:** When a completed order is reopened, the sale is reversed. Should that appear as a customer return (stock in, supplies reduced) or as a stock correction? The same question for an exchange that failed halfway and was rolled back.
**Why:** We record both as `sales_return`, which keeps supplies correct. If the CA wants them under stock correction, one string changes in each path.
**Default:** `sales_return`.
**Answer (research, 2026-11-21):** Keep `sales_return`. Reversing a completed order cancels the sale: supplies fall, goods come back (or never left), and returns net against supplies the same way a credit note does in GSTR-1. A sale followed by a return nets to nil, which is what the register should show for a rolled-back exchange. Refinement: keep the reason text explicit ("Order reopened", "Exchange rolled back") and show the *Net supplies* line (CA-1). A reopening after the month's GSTR-1 is filed needs a credit note, not just a cancelled invoice (section 34; from my knowledge, not re-verified this session).
**Verdict on our default:** KEEP. **Confidence:** Medium-High. **Real CA still needed:** No (low priority).
**Basis:** [S1]; reasoning.

### CA-6 VALIDATE: when does a sale leave stock?
**Ask:** Is stock considered supplied when the bill or order is completed (our rule), or at dispatch or delivery?
**Why:** The ledger row is written when the order is completed. Orders that stay open for days would be counted on a different date than a dispatch-based register.
**Default:** at completion.
**Answer (research, 2026-11-21):** Keep "at completion", with an operating rule the app should state in its help text: complete the order when the goods are handed over or dispatched. The law requires the invoice before or at the time of removal of goods (section 31(1)(a); from my knowledge, not re-verified this session), so a bill raised at hand-over or dispatch and a stock-out at completion agree. The two diverge only when a vendor completes late (register lags the physical removal) or bills early (register shows goods gone that are still in the shop). Goods sent on approval or for job work are a separate case (CA-18).
**Verdict on our default:** KEEP, plus a one-line hint in the Complete flow. **Confidence:** Medium. **Real CA still needed:** No.
**Basis:** reasoning; section 31 from my knowledge.

### CA-7 VALIDATE: imported orders
**Ask:** Orders imported from a file or a marketplace and then completed: do they count as supplies on the completion date, like any other order?
**Why:** Until slice S2d-2 these were recorded as stock corrections, understating supplies. S2d-2 now records them as `sale`. The quantity that actually left stock can be smaller than the order when stock was short; the register records what actually left, not the order quantity.
**Default:** `sale`, actual quantity.
**Answer (research, 2026-11-21):** T5 is right: a completed imported order is a supply, recorded as `sale`. The caveat the question already notes is the important one. When stock is short the code deducts only what exists, so the invoice says N units and the register says fewer. That is a mismatch between supplies per the invoice (what GSTR-1 shows) and supplies per the register, and it also means goods were sold that the books never received (an unrecorded purchase). Negative or short stock is a classic audit flag.
**Verdict on our default:** KEEP `sale` at the actual quantity, **ADD** a visible shortfall: a flag on the completed order ("short by X units, stock was not enough") and a register exception line, so the vendor fixes the missing receipt instead of the gap staying silent. **Confidence:** Medium. **Real CA still needed:** Yes: must register supplies equal the invoiced quantity even if stock would go negative?
**Basis:** [S1]; reasoning; the clamp behaviour is in the S2d-2 design.

### CA-8 VALIDATE: stock corrections
**Ask:** Is a net "stock correction" column with an optional reason acceptable, or must each correction be classified (for example excess or shortage found on physical verification), with a reason always?
**Why:** Taher chose optional. A product edited in the form produces a correction row without a reason, and deleting a product that still has stock writes an unvalued correction (known limit).
**Default:** optional reason, net column.
**Answer (research, 2026-11-21):** This is the most important finding of the review. Section 35(6) says: *subject to section 17(5)(h)*, where a registered person fails to account for goods, the proper officer determines the tax on the goods not accounted for **as if they had been supplied** [S4]. Goods that are lost, stolen, destroyed, written off, gifted or given as free samples are carved out by that "subject to" and only lose their credit. A shortage that is booked as a bare, reasonless `adjustment` is exactly the "not accounted for" case. Courts reach such goods through sections 73 or 74, not section 130, but the exposure is real [S12].
So optional-reason adjustments (T1) are the weakest point of the current design. Recommendation:
1. A **negative** adjustment needs a reason (at least 3 visible characters, as for the five mandatory kinds).
2. The picker nudges a shortage to the proper kind (`loss`, `theft`, `destroyed`, `write_off`) with a value. `adjustment` stays for count corrections found on physical verification and data-entry errors, with the reason "Physical verification, date".
3. A **positive** adjustment (excess found) stays optional but is nudged to "record a purchase instead".
4. The register shows gains and shortages separately, not net (CA-1).
**Verdict on our default (T1):** CHANGE for negative adjustments; KEEP for positive. **Confidence:** High on section 35(6), Medium on the product design. **Real CA still needed:** Yes: should a shortage found on physical verification be booked as "goods lost" (CA's view) or as a correction?
**Basis:** [S4][S12]. Affects S2e-2.

### CA-11 VALIDATE: which events need a reason
**Ask:** We require a reason for loss, theft, destroyed, written off and gift, because input tax credit is blocked on those under section 17(5)(h), and keep it optional for free samples. Is that the right list? We understand the GST Council recommended on 8 October 2026 removing the block for free samples; is that in force now?
**Why:** If free samples are still ITC-blocked, the reason should be mandatory for them too.
**Default:** mandatory for five kinds, optional for free sample.
**Answer (research, 2026-11-21):** The claim in the question is **verified, and it is not in force**. The 57th GST Council met on 8 October 2026. Its press release (para 9) recommends amending section 17(5) to remove the credit restriction on, among others, **free samples** and on **goods destroyed or written off on expiry of shelf life as required by law** [S6]. The same release says recommendations take effect only through circulars, notifications or law amendments. Section 17(5) is in the Act itself, so it needs an Act amendment; as of 21 November 2026 I found none enacted, and two commentary sources dated November 2026 say the same, adding that no relief is proposed for gifts [S7]. Until the Act changes, credit on free samples, gifts and written-off goods stays blocked and no one should claim it in advance.
Two points the draft missed: (i) the expiry relief is narrow, only where destruction is required by law (for example food or drug rules), not every expired item; (ii) no GST provision requires a "reason" as such. The reason is our evidence policy.
**Verdict on our default (T3):** KEEP: reason mandatory for loss, theft, destroyed, write-off and gift; optional for free sample. The trade-off to decide: free-sample credit is still blocked today, so by the policy's own logic the reason could be mandatory; the cost is friction on a high-volume event. A one-tap preset reason ("Sample distribution") would give both. When the amendment is enacted, add a structured sub-reason for expiry write-offs ("expired, destruction required by law") because only those would get relief. **Confidence:** High (primary source). **Real CA still needed:** Only for the effective date once enacted.
**Basis:** [S6][S7].

### CA-12 VALIDATE: gifts
**Ask:** Does a gift row need the recipient as a separate field (employee, related person, customer) and the value limits that decide whether the gift is a taxable supply, or is a free-text reason enough?
**Why:** Gifts to related persons can be supply under Schedule I, and gifts to employees up to Rs 50,000 a year are outside it. A structured recipient field is a screen and schema change.
**Default:** free-text reason.
**Waits:** S2e-2.
**Answer (research, 2026-11-21):** For the *register*, a free-text reason is enough: Rule 56(2) only needs "gift" as a category [S1]. The tax questions sit around it:
- Gifts by an employer to an employee up to Rs 50,000 in a financial year are not a supply (proviso to Schedule I, entry 2). Above that the **whole** value is a supply, not just the excess, because employer and employee are related persons [S11]. Credit on gifts is blocked under section 17(5)(h) either way on the prevailing view.
- Gifts to customers and dealers: no output tax, credit blocked.
- **Free items bundled with a sale are not gifts.** Buy-one-get-one and free-with-purchase offers are a composite or mixed supply and credit is *not* blocked (Circular 92/11/2019-GST) [S9]. If the app lets a vendor record such a free item as `gift`, it would wrongly trigger a reversal. Free items given with a sale belong on the order as lines.
**Verdict on our default:** KEEP free text; ADD (now) helper text on the gift picker covering the two points above; ADD (later) an optional recipient type (employee, customer, dealer, other) so a yearly per-employee total can be shown. **Confidence:** High. **Real CA still needed:** Yes for gifts above Rs 50,000 and gifts to related persons.
**Basis:** [S1][S9][S11]. Affects S2e-2.

### CA-13 VALIDATE: deleting a product that still has stock
**Ask:** If a vendor deletes a product with stock on hand, should the app force a classification (written off, destroyed, other) and a reason, with a value?
**Why:** Today the disappearance is recorded as an unvalued correction. Valuing it is needed for any credit reversal.
**Default:** unvalued correction.
**Answer (research, 2026-11-21):** Yes, force a classification. A product with stock that is deleted makes goods disappear; booked as an unvalued `adjustment` it is the "not accounted for" case of section 35(6) (see CA-8) [S4]. Recommendation: refuse to delete while stock is above zero until the vendor clears it through a classified movement (sold, written off, destroyed, lost, stolen, gifted, returned to supplier) with a reason and the cost value; deleting a product with zero stock stays one tap. This is the simplest robust rule and avoids a second picker inside the delete flow.
**Verdict on our default (unvalued correction):** CHANGE. **Confidence:** High on the principle. **Real CA still needed:** No.
**Basis:** [S4]. Lands in S2e-2.

## 4. Scope questions (may change which vendors the app supports)

### CA-14: records, corrections and retention
**Ask:** (a) How long must the stock register be kept? We believe 72 months from the due date of the annual return; please confirm. (b) Rule 56 says entries are not erased and a wrong entry is struck out under attestation and replaced. The ledger is append-only; a mistake is fixed by a new opposite row with a reason. Does that satisfy the rule? (c) Is an electronic register acceptable if it can be printed on demand?
**Default:** append-only, corrections by a new row.
**Answer (research, 2026-11-21):**
(a) Confirmed. Records must be kept until 72 months from the **due date of furnishing the annual return** for the year of the accounts (section 36) [S3]. Example: the annual return for FY 2026-27 is due 31 December 2027, so keep to 31 December 2033 (an extension of the due date moves it). If an appeal, revision, proceeding or investigation is pending, keep until one year after final disposal or the 72 months, whichever is later. The app never deletes ledger rows (rules block writes, no delete function, no expiry rule, checked). Do not add a tenant-delete or an expiry rule without an export and a retention hold.
(b) Rule 56(8): entries must not be erased or overwritten; an incorrect entry other than a clerical one is scored out under attestation and the correct entry recorded; for electronic records a log of every entry edited or deleted is kept [S1]. Append-only with a correcting opposite row satisfies this in substance. Strengthen it: store on the correcting row a link to the row it corrects (`reversesRowId`; no such field exists today) plus who, when and why, and print a corrections annex.
(c) Yes: an electronic register is allowed (section 35 proviso, Rule 56(15), Rule 57) [S1][S2], with conditions: back-up restorable within a reasonable time; production on demand in hard copy or a readable electronic format, authenticated; and on demand an audit trail with links to source documents, record layout, data dictionary, code explanations and record counts per field [S2]. Product gaps to close: no database back-up or point-in-time recovery setup is recorded in the repo, and there is no exportable data dictionary. The database region is `asia-south1` (Mumbai). A slide in an institute course claims e-records must sit on a server in India; I could not find that in the rule text, so treat it as unconfirmed.
**Verdict on our default:** KEEP, with the additions above. **Confidence:** High on the text, Medium on practice. **Real CA still needed:** Yes, one point: the digital-signature wording (CA-2).
**Basis:** [S1][S2][S3]; code check.

### CA-15: composition dealers
**Ask:** Composition dealers are excluded from Rule 56(2). Should the register stay available to them (optional use) or be hidden?
**Default:** stays available.
**Answer (research, 2026-11-21):** Keep the register available. Rule 56(2) excludes persons paying tax under section 10, but section 35(1)(c) still requires *every* registered person to keep a true and correct account of stock of goods [S5]. A composition vendor therefore needs a stock account, just not in the Rule 56(2) form by rule. Watch item: the 57th Council approved in principle an optional annual-return-quarterly-payment scheme for taxpayers up to Rs 5 crore selling only to unregistered buyers; it is a concept note, not law, and nothing in it changes record keeping yet [S6].
**Verdict on our default:** KEEP. **Confidence:** High. **Real CA still needed:** No.
**Basis:** [S1][S5][S6].

### CA-16: manufacturers and service-only businesses
**Ask:** The rule also names raw materials, finished goods, scrap and wastage. Do we need a product class (raw material, finished goods, scrap) for manufacturers, and should a service-only vendor with no stock see no register?
**Default:** one product class, register shown to everyone.
**Answer (research, 2026-11-21):** Be explicit that the first release is for traders and retailers. Rule 56(2) names raw materials, finished goods, scrap and wastage; Rule 56(12) additionally requires a manufacturer to keep monthly production accounts (raw material used, goods made, waste and by-products); Rule 56(13) requires a service provider to record goods used per service [S1]. Karobar has no production or consumption movement, so manufacturing support is a new design (kinds such as `consumption`, `production`, `scrap`, plus a product class), not a setting. A service-only vendor holds no stock, so show the register only when at least one stock-tracked product exists, otherwise an empty state.
**Verdict on our default:** CHANGE the *claim*, not the code: T4 ("any kind of vendor") should read "any kind of vendor that trades goods; manufacturers are not supported yet", in the README and onboarding. **Confidence:** High on the rule. **Real CA still needed:** No.
**Basis:** [S1].

### CA-17: more than one place of business
**Ask:** If a vendor has more than one place of business (shop and godown), must the register be kept per place?
**Why:** The ledger and the stock figure are per product, not per location. Per-location stock is a large design, so we ask before it becomes urgent.
**Default:** one register per business.
**Answer (research, 2026-11-21):** Yes, for any vendor with more than one place of business in the registration certificate. Section 35(1) first proviso: where more than one place is specified, the accounts of each place are kept at that place [S5]. Rule 56(5)(c) requires the address of each premises where goods are stored with the particulars of the stock stored there, Rule 56(7) requires books at the principal and every additional place, and goods found at an undeclared place without valid documents are treated as supplied by the registered person (Rule 56(6)) [S1]. A godown must therefore be declared as an additional place of business, and its stock accounted for separately.
**Verdict on our default (one register per business):** KEEP only for single-place vendors: state that limit now in the README and onboarding. Per-location stock plus a stock-transfer movement is a large design; schedule it before any multi-place vendor is onboarded. **Confidence:** High. **Real CA still needed:** No.
**Basis:** [S1][S5].

## 5. What each answer unlocks

| Work | Needs | Status after the 2026-11-21 review |
|---|---|---|
| S4c printable register | CA-1, CA-2, CA-3 | Unblocked provisionally: layout in CA-1 with its refinements; add the `opening` kind (CA-3) first |
| S4b-2 register page | CA-2 (layout only) | Unblocked: ship with kinds visible by type, gain and shortage split, net supplies line |
| S2e-2 loss, theft, gift pickers | CA-4, CA-9, CA-10, CA-12, CA-13 | Unblocked for recording events (reasons, damaged-return pair, delete-with-stock rule); the ITC figure waits for the purchase GST fields (CA-9) |
| S3 batch link per sale | CA-10 | Unblocked: FIFO batch is the preferred valuation base |
| Defaults stay or change | CA-3, CA-5 to CA-8, CA-11, CA-14 to CA-17 | Answered; changes are listed in section 8 |

## 6. Suggested way to ask
After the review only the items marked "Real CA still needed: Yes" need a CA: CA-2 (is a signed printout enough instead of a digital signature), CA-3, CA-4 (credit on damaged returns), CA-7, CA-8 (how to book a physical-verification shortage), CA-9 and CA-10 (partial loss, costing method), CA-12 (gifts above Rs 50,000), CA-14 (signature wording), CA-18 and CA-19. Send those as one page. Everything else was checked against the primary text and needs no CA time.

## 7. Questions the first draft missed (added by the review, 2026-11-21)

### CA-18 VALIDATE: goods out but not yet supplied (approval, job work, in transit)
**Ask:** Vendors send goods on approval or sale-or-return, to a job worker, or in transit under a delivery challan. Where do these appear in the stock register while no invoice exists yet?
**Why:** Goods sent on approval must be invoiced within six months of removal or at supply, whichever is earlier (section 31(7)); a job worker holds the principal's goods and they come back within one year (inputs) or three years (capital goods) or are treated as supplied (section 143); a challan moves goods without a sale (Rule 55). All of this is from my knowledge, **not re-verified in this review**. The app has no way to mark goods as "with someone else": they either stay in stock (shelf count differs from the register) or are recorded as a sale too early.
**Default:** record a sale only when the invoice is issued; until then the goods stay in stock.
**Answer (research, 2026-11-21):** The default is safe but incomplete. A later `out_on_challan` movement (stock leaves the shelf, not a supply, comes back or converts to `sale`) would be the clean answer. Low priority for retail, important for job-work and sale-or-return businesses. **Confidence:** Low-Medium. **Real CA still needed:** Yes.

### CA-19 VALIDATE: goods returned to a supplier
**Ask:** When goods are sent back to a supplier (wrong item, defect), is a separate *Returns to suppliers* column acceptable, and does the supplier's credit note reduce our input credit in the same period?
**Why:** There is no ledger kind for it. Today it would be booked as `adjustment` or `loss`, both of which misdescribe it and, for `loss`, would wrongly suggest a credit reversal.
**Default:** none (gap).
**Answer (research, 2026-11-21):** Add a kind `purchase_return` (stock out, optional reason, no credit reversal by itself) with its own register column. **Confidence:** Medium. **Real CA still needed:** Yes, for the credit-note timing. Not blocked by anything; schedule after S2e-2.

## 8. What the review changes in the product (proposals, nothing built; each needs Taher's decision)

| ID | Change | From | Size | Lands in |
|---|---|---|---|---|
| F1 | A negative `adjustment` needs a reason (3 visible characters); the picker nudges a shortage to `loss`, `theft`, `destroyed` or `write_off` with a value | CA-8, T1 | S: server `REASON_REQUIRED` rule, client mirror, parity test | S2e-2 |
| F2 | Delete of a product with stock is refused until the stock is cleared by a classified movement | CA-13 | S | S2e-2 |
| F3 | Damaged return writes two rows in one operation: `sales_return` +N and `write_off` -N with an automatic reason | CA-4 | M | S2e-2 |
| F4 | New kind `opening`; product creation asks "stock you already had" or "just bought" | CA-3 | S server and client, M with the picker | before S4c |
| F5 | Helper text on the gift and free-sample pickers (Rs 50,000 rule, free-with-purchase is not a gift); optional one-tap preset reason for free samples | CA-11, CA-12 | XS | S2e-2 |
| F6 | Register layout: net supplies line, gain and shortage columns, authentication line and header (legal name, GSTIN, address, period, page n of N) | CA-1, CA-2 | S; the header needs the pending tax-identity work (P2) | S4b-2, S4c |
| F7 | Purchase GST rate and "ITC claimed" flag on the batch; value from the FIFO batch; later an "ITC to reverse" helper | CA-9, CA-10 | L | after S3 `batchRef` |
| F8 | Visible shortfall flag on an imported order completed with short stock, plus a register exception line | CA-7 | S | after S2d-2 |
| F9 | `reversesRowId` link on correcting rows and a corrections annex in the print | CA-14(b) | M | later |
| F10 | Database back-up or point-in-time recovery and an exportable data dictionary | CA-14(c), Rule 57 | S ops | before the first production tenant |
| F11 | State the scope in the README and onboarding: traders and retailers, one place of business | CA-16, CA-17, T4 | XS docs | now |
| F12 | Kinds `purchase_return` (CA-19) and `out_on_challan` (CA-18) | CA-18, CA-19 | M | later |
| F13 | Watch: when the section 17(5) amendment is enacted, add a structured "expired, destruction required by law" sub-reason | CA-11 | XS | when the law changes |

Ordering by risk if a vendor is audited: F1, F2, F3 first (unclassified disappearance of goods), then F4 and F6 (the register itself), then F7 (the credit figure).

## 9. Sources

Primary or near-primary text first. A source is cited as [S#] in the answers.

- [S1] Rule 56, CGST Rules 2017, current text (18 sub-rules). Read from a state GST site mirror (Chhattisgarh), which matches the CGST text: https://cggst.com/uploads/document/1754037068-rule-56.pdf . **Do not use CBIC's own page https://cbic-gst.gov.in/accnt-record-rules.html as the numbering reference:** it is an archived draft whose sub-rule numbers are shifted by one.
- [S2] Rule 57 (electronic records): https://cggst.com/wp-content/uploads/2023/07/Rule-57-3.pdf ; the audit-trail and data-dictionary limb is from the same rule as reproduced in ICMAI training slides (https://icmai.in/upload/Taxation/Courses/MAR_0701_2021.pdf).
- [S3] Section 36, CGST Act (retention, 72 months): https://cggst.com/wp-content/uploads/2023/06/Section-36-1.pdf
- [S4] Section 35(6), CGST Act (unaccounted goods, "subject to section 17(5)(h)"): https://future.indiankanoon.org/doc/7452987 and ICMAI slides https://icmai.in/upload/Taxation/Courses/ACGAAP11_PPT_1411_25_2.pdf
- [S5] Section 35(1), first proviso (accounts of each place of business kept at that place) and section 35(1)(c) (stock of goods): https://taxguru.in/?p=743910
- [S6] GST Council, press release on the 57th meeting, 8 October 2026 (PIB release 2320934), para 9 (section 17(5)) and para 17 (optional scheme concept note): https://gstcouncil.gov.in/sites/default/files/2026-10/press_release_0.pdf
- [S7] Commentary, November 2026, that the recommendation is not enacted: https://taxgst.in/gst-gifts-free-samples-customers-itc/ and https://calcguru.in/diwali-gifts-gst-itc-194r-tds-deduction/
- [S8] Circular 172/04/2022-GST (perquisites under an employment contract): https://gstcouncil.gov.in/sites/default/files/2024-06/cir-172-04-2022-cgst.pdf
- [S9] Circular 92/11/2019-GST (sales promotion schemes; buy-one-get-one is not a gift): https://gstcouncil.gov.in/sites/default/files/2024-06/circular-cgst-92.pdf
- [S10] GSTR-3B Table 4: section 17(5) reversals go in 4(B)(1), not 4(D) (CBIC Circular 170/02/2022-GST; read through the Goa State Tax mirror https://statetax.goa.gov.in/PDF/state_notif/Circulars/No.01-2022-23-GST.pdf )
- [S11] Gifts to employees, Schedule I entry 2 and the Rs 50,000 limit, whole value taxable above it: https://www.taxscan.in/gst/gst-on-diwali-gifts-50000-employee-gift-limit-client-gifts-and-itc-rules-explained and https://taxguru.in/?p=1097308
- [S12] Case law: unaccounted or excess stock goes through sections 73 or 74, not section 130: https://taxguru.in/?p=1093126
- [S13] Partial damage and credit reversal "to the extent of the loss in value": https://taxguru.in/?p=1093177 ; time-expired goods ambiguity: https://www.taxmann.com/post/blog/analysis-itc-reversal-for-time-expired-goods-under-the-cgst-act

**Stated from my own knowledge, not re-verified in this review (a CA should confirm):** section 31(1)(a) invoice timing, section 31(7) six-month approval rule, Rule 55 delivery challan, section 143 job work periods, section 34 credit-note time limit, and the accounting-standard point that FIFO and weighted average are allowed but LIFO is not. The Income-tax Act 2025 replaced the 1961 Act from 1 April 2026; the roadmap row P5 still cites section 44AA and Rule 6F of the old Act (low confidence, out of scope here, ask the CA).

## 10. Review log (2026-11-21)

Claims in the first draft that were checked, and the result:

| Claim in the draft | Result |
|---|---|
| Reading of Rule 56(2) and the composition exclusion | Correct [S1]; add section 35(1)(c) for composition dealers (CA-15) |
| Retention: 72 months from the due date of the annual return | Correct [S3] |
| GST Council recommended on 8 Oct 2026 removing the free-sample block | Correct, not in force [S6][S7]; the draft missed the second relief (expiry write-offs required by law) |
| Gifts to employees up to Rs 50,000 a year are outside supply | Correct; above the limit the whole value is a supply [S11] |
| CA-4 "register shows stock that is not on the shelf" | **Wrong**, corrected: stock is not raised for a damaged return; the real gaps are gross supplies and a missing write-off row |
| Counts: 17 questions, 4 blocking | Correct (now 19 questions) |
| Code claims: ledger kinds, five mandatory-reason kinds with 3 visible characters, server-stamped cost on six kinds, ledger write blocked and read limited to owner, admin and manager, fixed IST periods, no `opening` kind | All match the code (`functions/lib/movementLogic.js`, `firestore.rules`, `qml/helper/StockRegisterModel.js`) |

Not done in this review: no code was changed and nothing was built or run. The `qt-qml-review` pass has nothing to review because no QML changed.
