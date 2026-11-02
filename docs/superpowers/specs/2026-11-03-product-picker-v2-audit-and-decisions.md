# Product picker v2: audit of the July design, constraints on main, and open decisions

**Date:** 2026-11-03
**Status:** DRAFT. Decisions D1 to D4 are open (Taher to answer); D5 and D6 carry a default that Taher can veto. No code has been written, by design: nothing is built until the design is approved.
**Branch:** `docs/2026-11-03-product-picker-v2-design` (docs only)
**Replaces:** `docs/superpowers/specs/2026-07-15-product-picker-search-design.md`, which exists only on the stale branch `origin/feature/product-picker-search` (see section 2). That branch is left untouched.

## 1. What was asked

The product picker in New Order and Edit Order should be detailed, searchable, and let the person edit the number of items, so the experience is seamless. Robustness of the product is favoured over everything else. The work must be split into pieces that each finish in one chat turn, with tests of every kind and a test plan for every change.

## 2. The existing design

It lives only on `origin/feature/product-picker-search`: two docs-only commits (`6e1dd77`, `9cd788a`) holding a design spec and a checkpoint dated 2026-07-15, last rebased onto a `main` that is now 423 commits ahead. It was never implemented: `ProductSearch` and `ProductSearchSheet` do not exist anywhere on `main`. (Whether a PR was ever opened for it was not checked.)

What it decided with Taher on 2026-07-15: a nested "Select product" sheet opened from a trigger field that replaces the `AppComboBox`; reuse `BottomSheet` and `SearchField`; substring match on name, SKU and product ID; out-of-stock rows stay visible and tapping one shows a toast; tapping an in-stock row adds one unit and closes the sheet; a pure helper `ProductSearch.js`; a component `ProductSearchSheet.qml` with an `availableStockFor` callback and a `productChosen` signal; selection by product ID instead of `currentIndex`.

## 3. Audit: is it still relevant, correct and up to date?

| # | Claim or choice in the July design | Verdict | Evidence on `main` |
|---|---|---|---|
| 1 | Nested sheet that reuses `BottomSheet` and `SearchField` | Right direction, incomplete | `BottomSheet` puts its body in a `QQC.ScrollView` and is a fixed 92% of the overlay. A `ListView` inside it fights the outer scroll, which is why `OrderDetailDialog` draws its line cards with a `Repeater`. The July design does not mention this. See D5. |
| 2 | Search convention copied from `InventoryPage._filteredProducts()` (name, SKU, category) and "add productId" | Stale premise, still right idea | `InventoryPage.qml` line 407: it already matches product ID, name, SKU and category. |
| 3 | "Nothing currently filters the picker's list" (section 1) | Wrong now | Both dialogs skip any product with a batch-id mint outstanding: `NewOrderDialog._rebuildPickerNames` (line 100) and `OrderDetailDialog._rebuildCatalog` (line 182). Added after July by E2E roadmap item 1, Decision 1. |
| 4 | Delete `productNames`, `_rebuildPickerNames()` and iterate `InventoryStore.products` directly (section 5) | Would cause a regression | That deletion removes the pending-mint guard. Selling against a product whose ledger rows are not written yet is the drift that `topUpOldest` was fixed for (see the comment at `NewOrderDialog.qml` lines 89 to 94). |
| 5 | Positional `currentIndex` selection is a latent bug | Narrow case already fixed, the ID-based end state is still right | `NewOrderDialog._pickerProducts` (line 40) and `OrderDetailDialog.catalog` keep the arrays aligned today. ID-based selection removes the need for them. |
| 6 | Out-of-stock rows tappable with a toast | Superseded | Reasonable for a one-tap picker. With quantity steppers the right behaviour is a disabled stepper with a stated reason (D2). |
| 7 | Row tap adds one unit and closes the sheet | Conflicts with the new ask | Editable item counts and multi-item sales need the sheet to stay open. One tap per product means reopening the sheet for every product. |
| 8 | No mention of a queued restock | Missing | `specs/2026-10-16-restock-atomic-operation-design.md` line 85 (Q-A2): a product with a queued restock is hidden from the order picker until the restock applies. R4 will add it. This is a third reason a row can be unavailable. |
| 9 | No mention of unsynced edits | Missing | `DataModel.qml` around line 651: completion refuses a line whose product has any queued unsynced edit, parked ones included. Today the user adds the product and meets the refusal at approval. |
| 10 | No mention of the operation size cap | Missing | `MAX_OPS = 200` (`functions/lib/operationLogic.js:34`, `qml/helper/CompletionPlan.js:15`). The cap counts changes, not lines: each line costs at least a stock change and a batch change, more when it spans several batches, plus the order and its sale records. An order over the cap is refused at approval with `operation-too-large`. A picker that accepts unlimited lines lets the user build an order that cannot be completed. |
| 11 | Sheet builds its list when it opens | Needs a refresh rule | Skill 78: a dialog that copies store data once goes stale. Stock can change while the sheet is open (sync, another sale). The rows must re-read on the store's revision signal. |
| 12 | No product photos | Missing | `InventoryPage.qml` lines 235 to 239 show the first photo through `StorageService.photoDownloadUrl(productId, photoIds[0], true)`. A "detailed" picker is expected to match. |
| 13 | Testing: "no qmltestrunner", "manual on-device plan only" | Stale | CI runs `qmltestrunner` on every push (`checks.yml` line 31), over 2,600 QML tests at the last recorded run. Skill 83 says to move logic out of Felgo components into pure `.js` helpers so it can be tested headless. The standard test-plan format (Skill 49) was not followed. |

**Verdict.** About two thirds of the July design is reusable as direction: the nested sheet, ID-based selection, a pure search helper, the `availableStockFor` idea. It is not safe to implement as written, because section 5 would delete a live safety guard, and it does not cover the new requirements. v2 supersedes it. The July spec stays as history on its own branch.

## 4. Guards that decide whether a row can be added

Today these guards are scattered across two dialogs and two stores. v2 puts them in one pure, tested predicate (`ProductPickability.js`) so the picker and the dialogs cannot disagree.

1. Available units, with the dialog's own formula: new order is on-hand stock minus units already in the cart; edit of a pending or processing order is on-hand minus units on the order; edit of a completed order is on-hand plus the original quantity minus the current one (`OrderDetailDialog._availableStock`, lines 194 to 214).
2. A batch-id mint is outstanding (`StockBatchStore.hasPendingMint`).
3. A restock is queued (Q-A2, arrives with R4; the input must exist now and default to false).
4. The product has a queued or parked unsynced edit (`OutboxStore.unsyncedByEntity("inventory")`, states `pending` and `parked`).
5. The order would exceed the operation cap (ask `CompletionPlan`, never hard-code a number).
6. The product has a delete in flight (`InventoryStore._pendingDeletes`). To verify in S1 whether `InventoryStore.products` already excludes these.

## 5. Proposed requirements for v2 (to confirm)

- Search: case-insensitive, trimmed, multi-word (every word must match somewhere), over name, product ID, SKU and category. Ranking: exact ID or SKU first, then prefix, then substring.
- Row detail: photo or initial avatar, name, `productId · SKU`, category, selling price, availability pill (N left, Out of stock, Low), "in this order: N" pill when the product is already on the order.
- Filters: category chips (`ChipScroller` exists) and an "In stock only" toggle. No sorting and no barcode scan in v1.
- Quantity: stepper per row, plus tap on the number to type it. Whole units only (to confirm, see section 11). Capped at available with a visible "max" state.
- The draft is keyed by product ID, never by the visible rows, so changing the search text never loses a quantity the person already set.
- A footer shows the running total (items and amount) and the commit button; closing with a non-empty draft asks for confirmation.
- Live refresh while open; an unavailable row shows its reason in words, never colour alone.
- Touch targets at least 48dp with 8dp between them; works at the largest system font size; both themes; keyboard does not cover the footer.

## 6. UI shape (D1)

| Option | What it is | For | Against |
|---|---|---|---|
| A | Single-tap-add-and-close (July design) | Simplest, fewest states | Quantity is edited afterwards in the cart; a five-product sale means five sheet openings. Does not meet "number of items editable". |
| B | Sheet that stays open; each row has a quantity stepper; footer shows totals; one "Add to order" commit | Best for counter sales with several items; the draft is cancellable | Largest build; draft state and commit semantics must be exact. |
| C | Search and results inline in the dialog, no nested sheet | No layering | The dialog body is a `ScrollView`; keyboard, nested scroll and the dialog's own fields collide. The highest on-device risk. |

Recommendation: **B**. It is the only option that answers the ask. The cost is real: roughly three times the logic of A, which is why the logic moves into pure helpers that can be proven headless.

## 7. Units

Pure helpers (`.pragma library`, no Felgo, fully testable headless, Skill 83):

- `qml/helper/ProductSearch.js`: tokenize, match, rank.
- `qml/helper/ProductPickability.js`: per-row state `{ pickable, reason, available, maxQty }` from the guards in section 4.
- `qml/helper/PickerDraft.js`: the draft map (set, step, clamp, clear), the commit plan (which lines to add or bump, never remove or reduce), and the line-cap check.
- `qml/helper/PickerRowGeometry.js`: touch-target and spacing math, same reason as `FailedTileGeometry.js`.

QML (Felgo-dependent, painting only): `qml/components/ProductPickerSheet.qml`, `qml/components/ProductPickerRow.qml`, a trigger button, and the wiring in `NewOrderDialog.qml` and `OrderDetailDialog.qml`. `BottomSheet.qml` gains one opt-in property (D5).

## 8. Decisions

**D1. Interaction model.** Options A, B, C in section 6. Recommendation B. OPEN.

**D2. Unavailable products: hide or show disabled with a reason.** Today two accepted decisions hide products from the picker: pending mint (Decision 1) and queued restock (Q-A2). Once search exists, hiding becomes a trap: the person searches for an SKU they know, nothing appears, and they conclude the product was lost. Recommendation: show every product and disable the unavailable ones with a plain reason ("Stock is syncing, try again shortly", "Out of stock", "Has changes still syncing"). This reverses the "hidden" part of two earlier decisions, so it is Taher's call. Cost: one more row state. Safety is unchanged, because a disabled row cannot be added. OPEN.

**D3. Row detail and filters.** Recommended set is in section 5. Options to trim or extend: drop the photo (saves a network image per row on a weak connection, the avatar initial remains), add sorting, add a barcode scan. Barcode needs a barcode field on the product record, camera access and possibly rules changes, so it is a separate arc. Recommendation: the section 5 set, no sort, no scan. OPEN.

**D4. What does a row quantity mean: "add N more" or "set the total"?** "Add N more" starts every row at 0 and only ever adds to the order. The cart stays the only editor of existing lines, and the picker can never delete a line or its discount. "Set the total" shows the quantity already on the order and edits it, which is intuitive but makes the picker a second editor of the same state, and setting 0 deletes a line together with its discount and booked tax. Recommendation: **add N more**. The "in this order: N" pill tells the person what is already there. OPEN.

**D5. How the sheet gets a non-scrolling body.** Recommendation: add an opt-in `scrollBody: true` property to `BottomSheet` (default unchanged, so the other 20 sheets are untouched), and set it to false for the picker so a `ListView` owns its scrolling and the footer stays pinned. The alternative, a separate sheet type, duplicates the sheet chrome. Veto if you disagree. DEFAULT TAKEN.

**D6. Order of delivery.** Pure helpers first (dormant, nothing calls them), then the component (dormant), then the two dialogs one at a time. Each slice merges on its own and changes no behaviour until a dialog is wired. DEFAULT TAKEN.

Also taken by default (veto in the PR): the line-cap check asks `CompletionPlan`; the pending-mint guard is kept and moved into `ProductPickability`; the July branch is not touched.

## 9. Slices (each sized for one chat turn)

| Slice | Branch (date prefix at the time) | Content | Behaviour change |
|---|---|---|---|
| S0 | `docs/2026-11-03-product-picker-v2-design` | This brief, checkpoint, Skill 151. Then the approved design and the test plan in the standard format (Skill 49). | None |
| S1 | `feat/…-picker-s1-pure-helpers` | `ProductSearch.js`, `ProductPickability.js`, `PickerDraft.js` with Node parity runs, QML tests, seeded monkey, hand mutants | None (dormant, pinned by a caller grep, as R3 did) |
| S2 | `feat/…-picker-s2-sheet-component` | `BottomSheet` `scrollBody` opt-in, `PickerRowGeometry.js`, `ProductPickerSheet.qml`, `ProductPickerRow.qml`, wiring tests | None (not instantiated) |
| S3 | `feat/…-picker-s3-new-order` | Wire `NewOrderDialog`; delete `productNames`, `_pickerProducts`, `_rebuildPickerNames`, the combo and the add button | New Order picker |
| S4 | `feat/…-picker-s4-edit-order` | Wire `OrderDetailDialog` (completed-order formula, booked-tax rule kept, `catalog` kept for legacy-order seeding) | Edit Order picker |
| S5 | `feat/…-picker-s5-sweep` | Accessibility, themes, font scale, big-catalog performance, regression sweep, on-device plan finalised, docs | Polish |

## 10. Test strategy

Every slice ships with a test plan in the standard format and these layers, as far as the layer applies:

- **Unit:** each pure helper at 100% line and branch coverage, with hand-written mutants killed in a Node shim (the method used for `SheetFooter.js` and `RestockPlan.js`). Edge cases include: empty and whitespace queries, regex characters, Devanagari and other non-ASCII text, very long queries, duplicate names, shared SKUs, missing or non-string fields, numeric IDs, stock that is negative, fractional or NaN, quantity typed as "007", huge, negative or non-numeric, and a query that changes while a draft exists.
- **Functional:** `ProductPickability` against the real `StockBatchStore` and `OutboxStore` states; the draft commit applied to the real cart logic of each dialog.
- **Rules:** no Firestore rules change is planned, so no new rules tests. A guard test asserts `firestore.rules` is untouched by the picker slices.
- **E2E:** one emulator test that builds an order from a `PickerDraft` commit and completes it through the real gateway path.
- **Regression:** `tst_NewOrderDialogSubmitGuard`, the completed-order tax tests, the pending-mint and top-up tests, and the parked and unsynced completion guards must stay green. A new test pins that a pending-mint product is never pickable.
- **Monkey:** seeded random sequences over search, draft and guards; on device, rapid taps on the stepper, rotation, backgrounding with the sheet open, going offline mid-search, and killing the app with a draft.
- **Honest coverage statement:** 100% applies to the pure helpers. The Felgo-dependent QML cannot be loaded by `qmltestrunner` (Skill 83), so the sheet, row and dialog wiring are covered by wiring tests over the pure helpers plus the on-device plan, not by line coverage. The plan will say this per slice instead of claiming 100% for code that cannot be measured.

## 11. Risks, pushback and assumptions

- **"100% of the code" is not reachable for the view layer.** Section 10 says what is covered instead. This is the main place the stated testing goal cannot be met literally.
- **D2 reverses two earlier decisions.** If Taher wants to keep hiding, the cost is the "where did my product go" confusion once search exists.
- **Thumbnails and weak networks.** Each row would request an image. The avatar falls back to the initial offline. Dropping the photo is an option under D3.
- **Whole units only.** Products carry a `unit` (default "pcs"). The order flow today uses whole numbers. If any product is sold by weight or length, say so now, because it changes the stepper, the cap and the ledger.
- **Free-plan budget.** The slices are small on purpose. If a slice runs long, the branch is pushed and the checkpoint says exactly where to resume.
- **Commit identity.** The R3 checkpoint recorded `taher.lkdw@gmail.com` as the current commit identity; this session's project instructions say `lkdwtaher@gmail.com`. This branch follows the project instructions. Say which is right.

## 12. Not checked

Whether a PR exists for the July branch; real catalog sizes (which decide whether list reuse is needed); keyboard behaviour over a nested `BottomSheet` on a device (the July checkpoint called it plausible, never verified); the Qt version available to Felgo for `ListView.reuseItems`; whether `InventoryStore.products` already excludes products with a delete in flight. Each is a first step of S1 or S2, not an assumption.
