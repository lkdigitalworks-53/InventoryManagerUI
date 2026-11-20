# Questions for the Chartered Accountant (CGST Rule 56(2) stock register)

Status: **draft for Taher's review, 2026-11-18. No question below has been put to a CA yet, so no CA answer exists.** The answers listed in section 1 are Taher's own product decisions, not professional advice. Please review the wording, strike what is not worth the CA's time, then send it.

How to use this document: each question says why we ask, what the app does today (our default), and which piece of work waits for the answer. Questions marked **BLOCKING** stop a feature from being built. Questions marked **VALIDATE** only ask the CA to confirm a default the app already uses; if the CA never answers, the default stays. Please put the CA's answer in the "Answer" line and the date, and keep this file as the record.

Background in two sentences for the CA: Karobar is a mobile inventory and billing app for small vendors. It keeps an append-only stock ledger (one row per stock movement, written by the server in the same transaction as the stock change, never edited or deleted) so that a stock register in the form of CGST Rule 56(2) can be produced.

What the register must show, as we read Rule 56(2): opening balance, receipts, supplies, goods lost, stolen, destroyed, written off, or disposed of by way of gift or free sample, and the closing balance, including raw materials, finished goods, scrap and wastage. Composition dealers (section 10) are excluded from the rule.

## 1. Decisions already taken (by Taher, not by a CA)

| # | Decision | Date | Note |
|---|---|---|---|
| T1 | A manual stock correction ("adjustment") is allowed and its reason is optional. | 2026-11-13 | Taher first said "not manual"; he accepted the recommendation that it keeps opening + in - out = closing. See CA-8. |
| T2 | The value of lost or gifted goods is the product's cost price, stamped by the server. No GST detail is kept on purchases yet. | 2026-11-13 | See CA-9 and CA-10. |
| T3 | A reason is mandatory where the event is sensitive: loss, theft, destroyed, write-off, gift (at least 3 visible characters). Free sample, adjustment, receipt, sale and return keep it optional. | 2026-11-13 | Based on section 17(5)(h). See CA-11. |
| T4 | The app is built for any kind of vendor, not only the first customer. | 2026-11-13 | See CA-15 and CA-16. |
| T5 | Imported (CSV or marketplace) orders count as `sale` in the register when the order is completed. | 2026-11-18 | New in slice S2d-2. See CA-7. |

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
**Answer:** _(blank)_

### CA-2 BLOCKING: period and form of the register
**Ask:** (a) Which periods must be producible: month, quarter, financial year, any date range? (b) Is one register per product enough, or must it be grouped by HSN code or by goods category? (c) Is a PDF or a spreadsheet export acceptable, and does it need a signature or a certification line?
**Why:** The app computes a per-product register for any date range using fixed IST midnights. Grouping or a different form changes what S4c builds.
**Waits:** S4b-2 (register page) layout, S4c.
**Answer:** _(blank)_

### CA-9 BLOCKING (for valuing losses): is the cost tax-inclusive or tax-exclusive?
**Ask:** To reverse input tax credit on lost, stolen, destroyed or gifted goods, which value do you need: the purchase price excluding GST, or including it? Does the register need the GST rate and the tax amount per row, or only the taxable value?
**Why:** Purchases in the app carry no GST detail today, so the product "cost price" may or may not include tax. We stamp that figure on loss rows. If the CA needs tax-exclusive value and rate, the product and purchase screens need a tax field first.
**Waits:** S2e-2 (pickers that record loss and gift) and the value column of the register.
**Answer:** _(blank)_

### CA-10 BLOCKING (for valuing losses): which cost method?
**Ask:** For valuing goods lost or gifted, is it acceptable to use the product's current cost price, or must it be the actual purchase cost of the batch (FIFO), or a weighted average?
**Why:** Today the value is the product's current cost, which is approximate when the same product was bought at different prices. The FIFO batch cost is available in the app but not wired to the ledger.
**Waits:** S2e-2, S3 (`batchRef`: linking each sale to the batch it consumed).
**Answer:** _(blank)_

## 3. Questions that VALIDATE a default

### CA-3 VALIDATE: opening stock of a new product
**Ask:** When a vendor creates a product with starting stock, is it acceptable to show that quantity inside "Receipts", or must it be a separate "Opening balance" entry?
**Why:** The ledger has no `opening` kind, so it is stored as a `receipt` (same as before). The register cannot tell it from a purchase. A separate kind is a small server change, but it must be decided before the register is printed.
**Default:** `receipt`.
**Answer:** _(blank)_

### CA-4 VALIDATE: damaged customer returns
**Ask:** A customer returns goods and they are damaged. Do we record (1) a return in and then a destroyed or written-off row out, or (2) nothing?
**Why:** Today nothing is recorded for the damaged part (design item K10), so the register shows stock that is not on the shelf.
**Default:** no row.
**Waits:** S2e-2 (return screen choice).
**Answer:** _(blank)_

### CA-5 VALIDATE: reopened order and rolled-back exchange
**Ask:** When a completed order is reopened, the sale is reversed. Should that appear as a customer return (stock in, supplies reduced) or as a stock correction? The same question for an exchange that failed halfway and was rolled back.
**Why:** We record both as `sales_return`, which keeps supplies correct. If the CA wants them under stock correction, one string changes in each path.
**Default:** `sales_return`.
**Answer:** _(blank)_

### CA-6 VALIDATE: when does a sale leave stock?
**Ask:** Is stock considered supplied when the bill or order is completed (our rule), or at dispatch or delivery?
**Why:** The ledger row is written when the order is completed. Orders that stay open for days would be counted on a different date than a dispatch-based register.
**Default:** at completion.
**Answer:** _(blank)_

### CA-7 VALIDATE: imported orders
**Ask:** Orders imported from a file or a marketplace and then completed: do they count as supplies on the completion date, like any other order?
**Why:** Until slice S2d-2 these were recorded as stock corrections, understating supplies. S2d-2 now records them as `sale`. The quantity that actually left stock can be smaller than the order when stock was short; the register records what actually left, not the order quantity.
**Default:** `sale`, actual quantity.
**Answer:** _(blank)_

### CA-8 VALIDATE: stock corrections
**Ask:** Is a net "stock correction" column with an optional reason acceptable, or must each correction be classified (for example excess or shortage found on physical verification), with a reason always?
**Why:** Taher chose optional. A product edited in the form produces a correction row without a reason, and deleting a product that still has stock writes an unvalued correction (known limit).
**Default:** optional reason, net column.
**Answer:** _(blank)_

### CA-11 VALIDATE: which events need a reason
**Ask:** We require a reason for loss, theft, destroyed, written off and gift, because input tax credit is blocked on those under section 17(5)(h), and keep it optional for free samples. Is that the right list? We understand the GST Council recommended on 8 October 2026 removing the block for free samples; is that in force now?
**Why:** If free samples are still ITC-blocked, the reason should be mandatory for them too.
**Default:** mandatory for five kinds, optional for free sample.
**Answer:** _(blank)_

### CA-12 VALIDATE: gifts
**Ask:** Does a gift row need the recipient as a separate field (employee, related person, customer) and the value limits that decide whether the gift is a taxable supply, or is a free-text reason enough?
**Why:** Gifts to related persons can be supply under Schedule I, and gifts to employees up to Rs 50,000 a year are outside it. A structured recipient field is a screen and schema change.
**Default:** free-text reason.
**Waits:** S2e-2.
**Answer:** _(blank)_

### CA-13 VALIDATE: deleting a product that still has stock
**Ask:** If a vendor deletes a product with stock on hand, should the app force a classification (written off, destroyed, other) and a reason, with a value?
**Why:** Today the disappearance is recorded as an unvalued correction. Valuing it is needed for any credit reversal.
**Default:** unvalued correction.
**Answer:** _(blank)_

## 4. Scope questions (may change which vendors the app supports)

### CA-14: records, corrections and retention
**Ask:** (a) How long must the stock register be kept? We believe 72 months from the due date of the annual return; please confirm. (b) Rule 56 says entries are not erased and a wrong entry is struck out under attestation and replaced. The ledger is append-only; a mistake is fixed by a new opposite row with a reason. Does that satisfy the rule? (c) Is an electronic register acceptable if it can be printed on demand?
**Default:** append-only, corrections by a new row.
**Answer:** _(blank)_

### CA-15: composition dealers
**Ask:** Composition dealers are excluded from Rule 56(2). Should the register stay available to them (optional use) or be hidden?
**Default:** stays available.
**Answer:** _(blank)_

### CA-16: manufacturers and service-only businesses
**Ask:** The rule also names raw materials, finished goods, scrap and wastage. Do we need a product class (raw material, finished goods, scrap) for manufacturers, and should a service-only vendor with no stock see no register?
**Default:** one product class, register shown to everyone.
**Answer:** _(blank)_

### CA-17: more than one place of business
**Ask:** If a vendor has more than one place of business (shop and godown), must the register be kept per place?
**Why:** The ledger and the stock figure are per product, not per location. Per-location stock is a large design, so we ask before it becomes urgent.
**Default:** one register per business.
**Answer:** _(blank)_

## 5. What each answer unlocks

| Work | Needs |
|---|---|
| S4c printable register | CA-1, CA-2, CA-3 |
| S4b-2 register page | CA-2 (layout only; the page can ship before CA-1 with the kinds visible by type) |
| S2e-2 loss, theft, gift pickers | CA-4, CA-9, CA-10, CA-12, CA-13 |
| S3 batch link per sale | CA-10 |
| Defaults stay or change | CA-3, CA-5 to CA-8, CA-11, CA-14 to CA-17 |

## 6. Suggested way to ask
Send sections 2 and 3 first, as one page: they are yes/no or short answers. Sections 4 and 5 can wait until the register page exists and the CA has seen a real printout.
