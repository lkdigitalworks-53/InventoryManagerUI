# Session Checkpoint — Product picker search (Add Order / Edit Order)

**Started:** 2026-07-15
**Branch:** `feature/product-picker-search`
**Status:** Brainstorming phase — exploring codebase, no design approved yet, no commits made.

## Step log

1. Cloned `InventoryManagerUI` fresh to `/home/claude/repo`. Repo reachable with no auth again
   this session (same discrepancy vs. memory's "private" note, flagged but not investigated —
   consistent with the prior session's note).
2. Archived stale root `CHECKPOINT.md` (from the completed
   `feature/analysis-by-name-chart-all-views` session) to
   `docs/superpowers/specs/2026-07-11-analysis-by-name-chart-all-views-CHECKPOINT.md`.
   Staged (`git mv`), **not yet committed** — will land in the first commit on this branch once
   Taher confirms, per his standing instruction to only commit after explicit confirmation.
3. Created branch `feature/product-picker-search` off `main` (clean, up to date).
4. Read skills: `superpowers:brainstorming`, `qt-development-skills:qt-qml`,
   `qt-development-skills:qt-ui-design`.
5. Explored the two target dialogs and related infra:
   - `qml/pages/NewOrderDialog.qml` (Add Order): picker is `AppComboBox` bound to
     `productNames` — a **plain string array** built by `_rebuildPickerNames()`. Selection is
     resolved via `productCombo.currentIndex` indexing directly into `InventoryStore.products`.
     **Found a pre-existing latent bug**: `_rebuildPickerNames()` hard-skips any product with
     `stock <= 0`, so `productNames` and `InventoryStore.products` are NOT positionally aligned
     whenever any product is out of stock — `addSelectedProduct()` can silently add the wrong
     product today. Not yet flagged to Taher as a standalone fix; surfaced as part of this
     feature's design since it uses the exact same mechanism we need to change.
   - `qml/pages/OrderDetailDialog.qml` (Edit Order): same `AppComboBox` + positional-index
     pattern, but via a separate `catalog`/`catalogNames` pair built together in
     `_rebuildCatalog()` (no 0-stock filter here — inconsistent with Add Order's hard-reject).
     Today this one happens to stay aligned because both arrays are built in the same
     unfiltered loop — but any filtering (i.e. our search feature) breaks that alignment the
     same way.
   - `qml/components/AppComboBox.qml`: shared, heavily-customized `QQC.ComboBox` (custom
     background/contentItem/popup/delegate), used in 11 places app-wide. Plain string model
     today (`text: modelData`).
   - `qml/components/SearchField.qml`: existing reusable rounded search input (magnifier icon +
     TextField + clear button), same visual tokens as AppComboBox. Already used on
     `InventoryPage`, `OrdersPage`, `StaffPage`, `MemberManagementDialog` — all as **page-level
     list filters**, not embedded in a dropdown/popup.
   - `qml/pages/InventoryPage.qml._filteredProducts()`: the established search convention —
     lowercase, trim, substring match against a concatenated haystack of `name + sku + category`.
     Our ask adds `productId` to that haystack (format confirmed human-typable: `PRD-001`, etc.,
     via `InventoryStore.nextProductId()`).
   - No existing precedent in the codebase for a *searchable dropdown/picker* specifically —
     confirmed via search for "picker"/"BottomSheet" components.
   - `qml/components/BottomSheet.qml`: modal `QQC.Dialog` parented to `QQC.Overlay.overlay`,
     92% height, slide-up. Nesting a second sheet on top (via the same Overlay) is architecturally
     plausible — Qt layers Popups/Dialogs by z-order within the same Overlay.
   - Checked `RestockDialog.qml`: takes an already-chosen `productId` via `openFor()`, has no
     product-picking dropdown of its own — out of scope, not touched.
6. Key finding to raise with Taher before proposing options: the positional-index selection
   mechanism in both dialogs must change to id-based resolution regardless of which UI shape is
   chosen — filtering makes position-based indexing unsafe, and Add Order's version is already
   broken today in a narrower case.

## Files touched so far
- `CHECKPOINT.md` → renamed (staged, not committed)
- This checkpoint file (new, untracked — will be added on first commit)

## What's verified vs. not
- Everything above is direct code inspection (`grep`/`view` of the actual source in this repo
  clone) — not yet cross-checked against `AGENTS.md`/`SKILLS.md`'s architectural guardrails
  (per Taher's standing instruction, still need to do this before finalizing a design).

7. Cross-checked `AGENTS.md`/`SKILLS.md` for relevant guardrails: no picker-specific rule blocks
   this design. Found one adjacent, non-blocking convention worth following in the new component:
   `SKILLS.md` documents "Picker dropdowns bind `model:` directly — never reassign `.model`
   imperatively (freezes the binding)" (currently scoped to `OrderChannelStore`/`CategoryStore`
   pickers, not this one, but the same principle should apply to whatever new component we build).
   Confirmed both dialogs (`NewOrderDialog.qml`, `OrderDetailDialog.qml`) fall under the "Pages &
   Dialogs Agent" scope and any new reusable picker component belongs under the "Shared Components
   Agent" scope (`qml/components/`) per `AGENTS.md`.
8. **Taher's decision (out-of-stock handling):** show out-of-stock products normally and
   selectable in both dialogs — i.e. standardize on Edit Order's current (more permissive) rule;
   Add Order's hard-reject-0-stock filter goes away.
9. **Follow-on finding from that decision, flagged back to Taher, answer pending:** Edit Order's
   existing "+" button already silently no-ops when `_availableStock(p.name) <= 0` (`if (avail <=
   0) return` — no feedback at all). Today that's a narrow, rarely-hit edge case. Standardizing
   Add Order onto the same permissive picker rule means this silent-failure tap now reproduces in
   BOTH dialogs instead of one, and search will make 0-stock items easier to actually find and tap
   into. Asked whether to fix the affordance (disable add / show explicit feedback for 0-stock) as
   part of this work, or leave the existing silent no-op as-is and keep this feature scoped to
   search only.

10. **Taher's decision (0-stock affordance):** keep the add action tappable even for 0-stock
    products, but show explicit inline feedback (e.g. "Out of stock") on the attempt instead of
    the current silent no-op. Applies to both dialogs once standardized.

11. Presented 3 UI options (nested search sheet / editable ComboBox / inline embedded list) with
    trade-offs and a recommendation (nested sheet — reuses `BottomSheet`+`SearchField`, isolated
    blast radius, avoids the unverifiable keyboard-over-popup risk of an editable ComboBox).
    **Taher's decision:** nested search sheet (Option 1).
12. **Taher's decision (row-tap behavior):** tapping a row in the search sheet adds it
    immediately (no separate "+" step), sheet closes.
13. Resolved the interaction between decisions 10 and 12: since row-tap now IS the add action,
    the "explicit feedback for 0-stock" (decision 10) has to fire at row-tap time, not later.
    Found the app already has a `Toast` singleton (`qml/components/Toast.qml`, `Toast.show(msg)`)
    used throughout for exactly this kind of transient feedback (`AddProductDialog`,
    `RestockDialog`, `AddStaffDialog`, etc.) — and confirmed neither `NewOrderDialog` nor
    `OrderDetailDialog` currently shows any toast on a normal add today (visible feedback is just
    the cart list updating). So: in-stock row tap → add silently as today (cart list update is
    the feedback, unchanged); 0-stock row tap → `Toast.show("Out of stock")`, do NOT add, sheet
    stays open so they can pick something else.
14. Proposing one additional design element as part of the consolidated design rather than as a
    separate question (YAGNI/isolation call, not a fork needing Taher's input): extract the
    match-predicate into a new pure helper `qml/helper/ProductSearch.js` (`.pragma library`,
    naming matches `BreakdownMath.js`/`OrderMath.js` convention) — `filterProducts(products,
    query)`, substring match against lowercased `name + sku + productId`, same convention as
    `InventoryPage._filteredProducts()` plus the new `productId` field. Reused by
    `ProductSearchSheet.qml`, unit-testable headlessly (QML test + Node `vm` verification, same
    convention as `BreakdownMath.js`) rather than inlining filter logic in the sheet component.

## Consolidated design (presented to Taher this turn for final approval before writing the spec)
- **New files:** `qml/components/ProductSearchSheet.qml` (shared sheet, reused by both dialogs),
  `qml/helper/ProductSearch.js` (pure filter predicate, `.pragma library`).
- **Modified files:** `qml/pages/NewOrderDialog.qml`, `qml/pages/OrderDetailDialog.qml` — replace
  the `AppComboBox` picker with a compact "tap to search" field/button that opens
  `ProductSearchSheet`; remove the 0-stock hard-reject in `NewOrderDialog._rebuildPickerNames()`
  (superseded); selection becomes id-based everywhere (fixes the positional-index landmine from
  step 5).
- **Not touched:** the other 11 `AppComboBox` usages app-wide, `RestockDialog.qml` (no picker of
  its own), all Cloud Functions / Firestore (search is 100% client-side over already-synced
  `InventoryStore.products`, no backend change).
- **Search:** substring match on `name + sku + productId`, live-filtered as you type, case
  insensitive, matches `InventoryPage`'s existing convention plus `productId`.
- **Default state:** opening the sheet with an empty query shows the full catalog (same list you
  see today), so nothing is lost for small catalogs — search narrows it, it doesn't gate it.
- **Out-of-stock:** shown normally and selectable (decision from step 8), same "· N left" /
  "· 0 left" badge convention already used in today's picker labels.
- **Row tap:** adds immediately if in stock (no separate "+" step); if 0-stock, shows
  `Toast.show("Out of stock")` and keeps the sheet open instead of adding (decisions 10, 12-13).
- **Testing:** `ProductSearch.js` gets a QML test (`tests/tst_ProductSearch.qml`) plus Node `vm`
  execution to verify real behavior in-session, matching the project's established verification
  standard for pure helpers.

## Open decisions
- Awaiting Taher's final "does this look right" approval on the consolidated design above. Once
  approved: write the design doc to
  `docs/superpowers/specs/2026-07-15-product-picker-search-design.md`, self-review, get Taher's
  review of the written spec, THEN invoke `writing-plans` for the implementation plan.
- No design doc written yet, no plan written, no code written, no commits made.
