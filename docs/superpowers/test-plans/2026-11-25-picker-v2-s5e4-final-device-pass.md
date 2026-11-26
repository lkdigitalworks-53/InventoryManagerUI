# Picker v2, S5e-4: the final device pass (20 checks) and the completed-order edit measurement (KNOWN-ISSUES 29)

**Honesty note.** Written 2026-11-25 without a phone. NOTHING in this file has been run. It is the curated pass the picker roadmap names as its last row (`S5e-4`). The long plan (`2026-11-03-product-picker-v2-test-plan.md`) has 214 numbered device checks and the repo holds NO written device result for any of them; this file is the 20 that give the most information per minute, with the old check numbers in brackets so the long text stays the reference. When a result disagrees with the long plan, the phone wins and the long plan gets a line.

**Status 2026-11-26.** The owner reports that all picker slices were tested on a device. No result line below and no KNOWN-ISSUES 29 number has been written into the repo (KNOWN-ISSUES 164), so every `Result:` stays empty on purpose: a summary like "all passed" is not recorded as 20 results. Send F8 (seconds), F9 (what a dropped connection left) and any FAIL, and the lines get filled from your words.

**The checks that matter most at this stage (PR #221 review, ranked by what a failure costs):**
1. **F9** dropped connection while saving a completed order's edit: can leave stock and order disagreeing. Money and stock integrity. Highest.
2. **F8** the measured size of that edit: the number KNOWN-ISSUES 29 waits for.
3. **F3** completed order keeps its booked tax and held units: wrong tax or double-counted stock.
4. **F5** stock falls under an open sheet: overselling.
5. **F4** and **F7**: rows that cannot be picked (no price, unsynced edit, out of stock) and the 60-line limit: a wrong or missing price on an order.
6. **F14** dark phone: NOT made optional by "no second theme planned". It tests whether the phone's own dark mode repaints unpinned controls (KNOWN-ISSUES 142).
7. **F17** login screen and every page: the only code change of PR #221 is the deletion, and this is its regression check (cheap, 5 minutes).
8. **F19** monkey (rapid taps, back key, rotation): crashes and stuck states.
Also from #219 (merged, NO3b): the price field refusals and "Place order blocked on an unread refusal" (its test plan, checks 1 to 25).

**What 20 means.** Every merged slice S1 to S5g changed something a phone can show and a source scan cannot: the sheet, the stock rule, Back, 48 dp targets, TalkBack names, the wrapped toast, font scale, the dark theme, the photo sheet. Six checks cover the order flow (F1 to F6), three the size limits and KNOWN-ISSUES 29 (F7 to F9), seven accessibility, font and theme (F10 to F16), four the safety nets (F17 to F20). About 75 minutes.

**How to run it.**
1. Build this branch or `main` (your call; this slice changes no behaviour except that two unused files are gone).
2. One fresh user and tenant (your usual rule). Seed below, once.
3. Run F1 to F20 in order (cheap and risky first). After each check write ONE line under it: `Result: PASS`, `Result: FAIL, <what you saw>` or `Result: UNSURE, <why>`.
4. On a FAIL: screenshot, the order or product id, the step number. Stop that check, go on, send me the list.
5. Do not edit the numbers in the KNOWN-ISSUES 29 table afterwards. They are the measurement.

## Seed (once, about 15 minutes)
| # | What | Used by |
|---|---|---|
| S-1 | 60 products, stock at least 2 each, selling price set. Use the app's Import (a sheet of 60 rows). Three categories. One name of about 30 characters, one product in kg, one with no unit, one name with a quote or bracket in it. | F1, F4, F7, F8, F9, F19, F20 |
| S-2 | Product OUT (stock 0), product NOPRICE (stock 5, no selling price: Firestore console, delete `sellingPrice` and `price`), product LOW (stock 1). | F4 |
| S-3 | Product TAX (stock 10, tax 5%). Make an order with 2 of TAX and complete it. THEN change TAX's tax to 18%. | F3 |
| S-4 | One pending order with 3 lines (A, B, LOW). | F2, F5, F6 |
| S-5 | A product with an unsynced edit: turn on airplane mode, edit a product's price, leave airplane mode OFF until F4 says so. | F4 |
| S-6 | A way to throttle the network (a slow mobile connection, or airplane mode and back), and a stopwatch. | F8, F9 |
| S-7 | Android system font size reachable (1.0x, 1.3x, 2.0x), dark and light system theme reachable, TalkBack reachable. | F10 to F16, F18 |

## A. The order flow (old checks in brackets)

**F1. New Order, the whole happy path [54, 55, 56, 63].** Open New Order. One full-width "Add products" button (no combo). Tap it; the sheet opens with search, chips, "In stock only" and the list. Tap `+` on three products, type `7` in one quantity box, tap "Add to order". Expect the sheet closes, the lines and quantities match what you picked, the total matches the sheet's footer. Open the sheet again: the three products say "In this order: N". Tap "Add products" for one of them again: its quantity goes UP, its price and discount stay. Place the order: busy overlay, success, dialog closes.
Result:

**F2. Edit Order, pending: sheet and `+` stepper agree [68, 69, 104].** Open the pending order (S-4). Pick two NEW products and one more of A; Add to order. New rows show the product price and current tax. For A with stock 5 and 2 held: the sheet allows 3 more, and the `+` on the A row stops at 5 in total. Save: saves, no message.
Result:

**F3. Edit Order, completed: booked tax and held units [71, 72, 93].** Open the completed order from S-3. Note the Tax row. Tap the red X on the TAX line, open the sheet, add 2 of TAX, Add to order. Expect the line back at 5% (booked), not 18%, and the Tax row equal to the one you noted. A product that was never on the order comes in at its CURRENT tax. Try to add more of TAX than on-hand plus the units the order held: the sheet stops at that number and a toast says what was not added.
Result:

**F4. Rows that cannot be picked [13/58, 97, 57/75].** In New Order open the sheet. OUT is shown greyed with "Out of stock"; `In stock only` removes it. NOPRICE is greyed with "No selling price" and cannot be raised (it stays listed with the toggle on). The product from S-5 (unsynced edit) is NOT listed and the footer says "N products hidden while they sync". Now leave airplane mode OFF and wait: it appears without reopening the sheet. Same two rows in Edit Order on S-4.
Result:

**F5. Stock falls under an open sheet [59, 77].** Open the sheet, set 5 of LOW (stock 1 clamps to 1, note it). On a second device, or with a sale on this device from another dialog if you have one, take a drafted product's stock down. Tap Add. Expect no more than is left on the order and a short toast, never a quantity above stock. On the completed order the limit counts the units the order held.
Result:

**F6. Discard question and the Back key [11, 61, 122, 123, 126].** Sheet open, nothing ticked: Back closes the sheet only, the dialog stays; Back again closes the dialog. Sheet open, two products ticked: Back asks "Discard 2 items?" and everything stays; "Keep picking" keeps the draft; Back, then Discard closes the sheet and leaves the order unchanged. Two fast Backs: ONE question, still showing. Tap outside with a draft: the same question, not a close. Do it in New Order and in Edit Order.
Result:

## B. Size limits and the completed-order edit (KNOWN-ISSUES 29)

**F7. The 60-line limit [20].** New Order, add 60 DIFFERENT products from S-1 (two rounds are fine). The 61st new product is greyed with the order-full reason; products already on the order stay usable; the order places. If the sheet lets a 61st line in, that is a FAIL.
Result:

**F8. Completed order, the size of the edit: MEASURE [82, 134, 135].** This check produces the number KNOWN-ISSUES 29 asks for. Do the rows in this order, on the normal network first, then on the slow one. One new completed order per row (make it in New Order, complete it, wait until it shows Completed).
| Row | Lines on the order | New lines added in Edit Order | Network | Seconds from "Save changes" to done (stopwatch, to the toast or the closed dialog) | Finished? (yes / no / error text) | Stock of 2 added products after (as expected? yes/no) |
|---|---|---|---|---|---|---|
| 1 | 1 | 10 | normal | | | |
| 2 | 20 | 20 | normal | | | |
| 3 | 20 | 40 | normal | | | |
| 4 | 20 | 40 | slow | | | |
| 5 | 1 | 59 | slow | | | |
Also note: did the confirm-return sheet appear at once, and did the app stay usable (scroll, tap) while it worked?
Result:

**F9. Completed order, the connection drops in the middle: PARTIAL STATE [new].** Row 5 again (a fresh completed order with 1 line, add 59 new lines). Tap "Save changes", count two seconds, switch airplane mode ON. Wait 60 seconds, then airplane mode OFF and wait 2 minutes. Write down: (a) what the order shows (old lines, new lines, a mix); (b) the stock of three of the added products against what it should be; (c) whether a toast or a red message said anything. The chain is a per-line sequence with compensations and no transaction, so a half-applied edit is the risk to look for. If (a) or (b) is a mix, that is a bug (stock and order disagree) and it is the strongest argument for moving `_tryAdjustOrder` onto an atomic operation soon.
Result:

## C. Accessibility, font and theme

**F10. TalkBack, rows and chips [141, 142, 143].** TalkBack on, sheet open. A product row reads name, ID, price per unit, "N left", then "In this order: ..." if it is, "N selected" once you picked some, "Maximum reached" at the ceiling. A disabled row says its reason ONCE. Each category chip is ONE stop ("<category>, radio button, selected"); double tap filters once. Write down if a row is read twice (its name, then each child).
Result:

**F11. TalkBack, order fields and steppers [130, 190, 191].** New Order with two products: the price box says "Price of Soap", the discount box "Discount of Soap, flat amount" (and ", percent" after the toggle). The stepper buttons say "Decrease quantity of Soap", "Increase quantity of Soap"; Edit Order adds "Remove Soap". Each acts once on a double tap. Never the word "undefined".
Result:

**F12. Font 1.3x [197, 199].** System font 1.3x. New Order, Edit Order and the product sheet (search, chips, "In stock only", rows, steppers, footer). Nothing cut off or overlapping; price and discount boxes grew in height, digits not cut. Write down the worst row.
Result:

**F13. Font 2.0x [198, 199].** Same at 2.0x. "In stock only" stays on ONE line with its switch visible; "Manage channels" stays on one line and tappable; touch targets still at least 48 dp. Write down the row that looks worst (feeds KNOWN-ISSUES 145).
Result:

**F14. Dark phone [194, 195, 200, 201].** System theme dark. (a) Search pill: type "tea": dark letters on the white pill, hint readable. (b) New Order: type a price and a discount: digits dark on the white box; while a save runs the digits go grey, not invisible. (c) The "In stock only" switch: on and off look different. (d) Login screen: type an email and a password, look at the empty boxes: letters AND hints readable? (e) Restock: typed quantity readable? Write yes or no for each of a to e.
Result:

**F15. The photo sheet [203, 204, 205, 209, 210, 211].** Add Product, tap the photo area. At 1.0x: two rows "Take photo", "Choose from gallery", same look as before. At 1.3x and 2.0x: text bigger, both lines inside each row, rows taller, sheet fits and every row taps. At 2.0x portrait, first open after killing the app: no one-frame jump, no gap above the title. At 2.0x on your narrowest phone, "Choose from gallery" wraps inside its row. Turn the phone sideways at 1.3x on Edit Product with a photo: drag up, reach and tap "Remove photo"; a drag that starts on a row must not fire it.
Result:

**F16. A long toast over a sheet [151, 155, 156].** Trigger the conflict toast (open one product on two sessions, save on A, then on B: about 95 characters). Expect the whole sentence in 2 to 4 centred lines inside one rounded pill, nothing cut at the screen edges. Over Restock or Add Product: the pill is above the sheet and a tap on a footer button under it still works. Write down whether the pill hides a button label.
Result:

## D. Safety nets

**F17. The login screen and every page, after the Auth cleanup [207, 213, 214].** Sign out. The login screen shows its Sign in button, its secondary buttons and the forgot-password link as before (S5g deleted two UNUSED buttons; the login screen uses PrimaryButton and GhostButton). Sign in. Open every page once: Dashboard, Orders, Inventory, Sales, Analysis, Staff, Profile, Stock register, New Order, Edit Order. No page missing. If you can read `adb logcat`: no "is not a type" line for `AuthPrimaryButton`, `AuthSecondaryButton`, `CardKPI`, `StatusBadge`, `OrderRow`, `SegmentedNav` or `PlaceholderPage`.
Result:

**F18. Light theme, normal font, nothing moved [202, 208, 212].** Light theme, 1.0x. Add Product, Edit Product, New Order, Edit Order, the photo sheet, the search pill look as before the picker work; no digit changed colour; the search hint is a little darker than it was (S5e-3c, on purpose).
Result:

**F19. Monkey, 60 seconds each [30 to 32, 113, 132, 139].** (a) Hammer `+` and `-` on one row 20 seconds; the count stays between 0 and the maximum and the footer equals the sum. (b) Open and close the sheet 30 times fast on a pending and on a completed order, adding and removing lines in between: no stuck dim layer, no second sheet, totals equal the lines. (c) Tap "Add to order" twice fast: ONE change. (d) Rotate twice and press Home and back with a draft: the sheet and draft as left, or a clean close. No crash anywhere.
Result:

**F20. A big shop and a big cart [46, 134, 135, 136].** With the 60 products: type "prod" fast in the search: the list moves about a moment after the last key, not per key; say if it feels slow. Build a 20-line order, open the sheet and tap `+` ten times on a row: say if it feels slow. On a COMPLETED 20-line order the same (the heaviest case). If you have the 2000-product seed, repeat there.
Result:

## What to do with the results (decided before they exist)
- **Any FAIL in F1 to F9:** stop adding slices. Send the list; the fix comes first.
- **F8 and F9 decide KNOWN-ISSUES 29** (plan 2026-11-25, D4): no stopgap cap is coded before these numbers exist. Rows 1 to 5 all finish in 10 seconds or less on the slow network AND F9 leaves order and stock in agreement: write that number into KNOWN-ISSUES 29 and close it as "measured, no cap needed at 60". A row slower than 10 seconds: the largest row under 10 is the proposed cap for a completed edit (Q-S5G-2). F9 shows a mix: do not cap, pull `_tryAdjustOrder` forward in the atomic-operations arc (Q-NO3-1), because a cap does not fix a half-applied edit.
- **F10 to F16:** each FAIL becomes a KNOWN-ISSUES line with the check number; fix in the order of how many users it touches.
- **After the pass:** copy the 20 result lines into the Verification block of the long plan (row S5e-4) and tick the earlier rows you covered. The picker roadmap is then closed.
