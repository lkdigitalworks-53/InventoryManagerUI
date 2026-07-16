# Desktop UX Design — Karobar

**Date:** 2026-07-14
**Status:** Approved by Taher 2026-07-16, no changes requested — moving to implementation planning
**Branch:** `feature/desktop-ux-design`
**Author:** Claude, in collaborative brainstorm with Taher (see `CHECKPOINT.md` for the full
session trail — this doc is the distilled output, not a replacement for that log)

## 1. Summary

Karobar ships mobile-only today (Android/iOS, Felgo/Qt Quick). It already runs as a Windows
desktop build as a side effect of the local dev loop (`CMakePresets.json` only defines
`felgo-mingw-*` presets), but with zero desktop-aware design — it's a phone screen in a resizable
window. This spec defines a deliberate desktop UI/UX for Owner, Admin, and Manager, built as new
QML on the existing Felgo/Qt Quick codebase, reusing the existing C++ backend, Gateway, RBAC, and
compliance-ledger layer unchanged.

Staff stays mobile-only. Owner/Admin/Manager use **both** mobile and desktop — mobile on the
floor, desktop at a workstation — not one replacing the other, which means cross-device data
consistency is a real requirement, not a nice-to-have. The existing Firestore-backed, offline-first
architecture already satisfies this at the data layer; nothing new is needed there.

## 2. Decisions already made (see CHECKPOINT.md for the full reasoning trail)

| Decision | Answer | Confidence |
|---|---|---|
| Who gets desktop | Owner, Admin, Manager (not Staff) | Confirmed by Taher |
| Replace or coexist | Coexist — same people, device by context | Confirmed by Taher |
| Delivery mechanism | Extend existing Felgo/QML app, shared C++ backend (not Qt Widgets, not a separate web app) | Confirmed by Taher |
| Nav-level role split | None — one flat nav for all 3 desktop roles | Confirmed by Taher (corrected my initial guess) |
| Analysis page direction | Overview strip of all 6 metrics + click-to-drill-down (not a bigger version of mobile's one-at-a-time pills) | Confirmed by Taher |
| Visual identity | Reuse `Constants.qml` tokens as-is; do not invent a parallel palette | Confirmed by Taher |

**Not yet confirmed** — nav *visibility* is uniform across Owner/Admin/Manager, but *permissions*
within a section may still differ (e.g. `canViewFinancials` already gates Value/Revenue/Purchased/
Profit in the existing `SalesPage.qml`; whether Manager currently holds that flag is unknown and
doesn't block this spec — it changes runtime behavior, not the design).

## 3. Assumptions I'm naming rather than asking about

Per the `qt-ui-design` skill's context-check: two inputs weren't pinned down in conversation. Named
here as defaults, correct me if wrong rather than silently building on them:

- **Resolution:** designing for a responsive range of roughly 1280–1920px window width (small
  laptop through 1080p desktop monitor), not a fixed size. Below ~1000px, the content area's
  master pane collapses before the sidebar does (see §5).
- **Locale/input:** English UI text, consistent with the `qsTr()` calls already in the mobile
  codebase (so the existing i18n path isn't broken, even if unused today). No RTL. Keyboard + mouse
  primary; USB barcode scanners acting as keyboard input should keep working with no special
  desktop handling needed, same as they likely do today when the app runs as a Windows build.

## 4. Visual language

Reuse `qml/helper/Constants.qml` directly — do not create a second set of desktop tokens.

- **Brand:** brand1 `#6366f1` (indigo) → brand5 `#14b8a6` (teal), semantic warn/danger/success as
  already defined.
- **Radius:** 16px default, up to 999 (pill) — kept as-is for hero cards, KPI cards, primary
  buttons, and badges. **Tightened to `radiusSm` (10px) or flat (0) for dense surfaces** — table
  rows, the master-list pane, filter chips — where 16px rounding and full-bleed gradients would
  fight against scannability. This is the one deliberate departure from "just reuse everything,"
  and it's scoped narrowly: decoration stays on hero/KPI/CTA elements, density surfaces flatten.
- **Gradients:** `gradPrimary`/`gradHero`/`grad1-4` continue to drive KPI-card fills, same as
  mobile's `SalesPage.qml` hero card. The 6-card overview strip in §6.2 should use these, not flat
  accent fills (correcting the placeholder mockup shown earlier in this session, which used a
  generic flat accent — that was a structural sketch only, not a visual-final).
- **Icons:** reuse the existing `iconMap`/`colorIconSet` system in `Constants.qml` rather than a
  new icon set. Desktop-only actions (bulk select, keyboard-shortcut hints, right-click context
  menus) will need a handful of new semantic entries added to `iconMap` — flagged as new work, not
  a new system.
- **Motion:** existing `durFast`/`durMed`/`durSlow` (160/240/420ms) already sit inside the
  `qt-ui-design` skill's own recommended budgets (cards/panels 200–300ms, nothing over 500ms) —
  reuse as-is, no changes needed.
- **Typography:** existing 11/12/13/14/16/18/20/24/32 scale reused as-is.

## 5. Information architecture

Persistent left sidebar, one flat list, all 3 desktop roles see the same 7 items (permissions
*within* a section may still vary by role — not a nav concern):

Dashboard · Orders · Inventory · Analysis · Staff · Activity · Settings

Top bar: brand mark + workspace name, global search, identity chip (name + role). Below ~1000px
window width, the master pane in split-view sections (see §6.1) collapses to icon-only or hides
behind a toggle before the sidebar does — sidebar survival takes priority since it's the primary
wayfinding element (Wayfinding principle, `qt-ui-design` §1).

## 6. Core interaction patterns

Documented once, applied per-section below, using the `design-system` skill's extend format.

### 6.1 Master-detail

**Problem:** Mobile's list → tap → new screen pattern wastes desktop's screen space and adds a
navigation round-trip for every record viewed.

**Existing pattern it replaces:** mobile's page-based navigation (`OrdersPage.qml` →
`OrderDetailDialog.qml` as a full navigation push). Not enough on desktop — throws away available
width.

**Proposed design:** persistent two-pane split within the content area. Left pane: scrollable list
of records (narrow, ~190–200px, name + key metric + timestamp per row, matching the density of a
notification list, not a full card). Right pane: detail for the selected record, same information
already shown in the mobile detail dialog, laid out with more breathing room since there's no
screen-size constraint forcing collapse. Selecting a row updates the detail pane in place — no
page transition, no navigation stack.

**Tokens used:** `radiusSm`/flat for list rows, `brand1`-tinted left-border + tinted background for
the selected row, `cardRadius`/`cardBg` for the detail pane's internal grouped sections.

**Applies to:** Orders (sketched in this session), Inventory, Staff.

**Open question:** at what list length does a flat list stop being usable and need
search/filter-to-narrow instead of scroll? Not resolved here — revisit once real data volumes are
known.

### 6.2 Metric overview strip + drill-down

**Problem:** mobile's segmented-pill switcher shows one of 6 Analysis modes at a time, forcing
users to hunt through pills to compare numbers that desktop has room to show simultaneously.

**Proposed design:** row of 6 compact metric cards (Value/Current/Sold/Purchased/Revenue/Profit),
gradient-filled per `grad1-4`/`gradPrimary` conventions, always visible. Clicking a card expands a
detail region below: trend chart + breakdown (by category/supplier/name — the "by name" dimension
maps to the same feature merged via `feature/analysis-by-name-chart-all-views`). Respects
the existing `canViewFinancials` gate: without it, only Current and Sold render as cards, same
layout, fewer cards — not a different design for that role.

**Applies to:** Analysis (sketched in this session, pending the token correction in §4 above).

## 7. Sections not yet visually sketched — pattern application

Per Taher's direction to move to spec rather than mock up every remaining screen: described here
at pattern level. Full visual treatment happens in the Figma pass (§9), not in this document.

**Inventory** — master-detail (§6.1): product list on the left, detail/edit on the right. Desktop-
specific addition beyond mobile: multi-select + bulk actions (bulk category reassignment, bulk
restock, bulk export) — genuinely new capability mobile's one-row-at-a-time interaction doesn't
support well, and a real answer to "what should desktop add." Import preview
(`ImportPreviewDialog.qml` on mobile) becomes an inline panel rather than a modal, given desktop's
room for a full preview table before committing an import.

**Staff** — master-detail (§6.1): staff list left, detail/permissions right. Same nav visibility
as everyone else per §2, but likely narrower *permissions* within the section (e.g. Manager
probably shouldn't be able to remove an Owner-level account) — deferred to a follow-up pass once
Taher confirms the actual permission boundaries, not guessed at here.

**Dashboard** — not a list-of-records page, so master-detail doesn't apply. Proposed as a summary
composition: a smaller version of the Analysis overview strip (headline numbers only, no
drill-down) plus a recent-activity feed and any low-stock alerts, functioning as a landing page
that answers "what needs my attention" before a user picks a section from the sidebar.

**Activity** — this is the audit/compliance log surface. Given the ledger architecture is
append-only and legally load-bearing (per `AGENTS.md`'s compliance section), this should be a
dense, filterable table — not cards, not a feed — closer to the Orders master-list density than to
Dashboard's summary cards. No detail pane needed beyond an expandable row, since audit entries are
immutable single facts, not records with sub-structure to drill into.

**Settings** — tenant/workspace-level configuration (categories, order channels, per mobile's
`ManageCategoriesDialog.qml`/`ManageOrderChannelsDialog.qml`). Standard desktop settings pattern:
a left-hand list of settings groups, form content on the right — a specialization of master-detail
where the "records" are configuration sections rather than data entities.

## 8. Accessibility and responsiveness checklist

Per the `qt-ui-design` skill's extended audit checklist — applied here prospectively rather than
after the fact:

- [ ] Every interactive element (nav items, list rows, card selection, filter controls) reachable
      and operable by keyboard alone — not yet verified, needs explicit tab-order design once
      screens are built.
- [ ] Color is paired with a second cue everywhere it carries meaning — order status already does
      this on mobile (fill + stroke + text per status, see `Constants.qml`'s
      pending/processing/completed/cancelled color groups) — carry the same pattern to desktop
      rather than color-only badges.
- [ ] Body text stays at the existing `fsBody`/`fsBodyLg` (13/14px) minimum — no smaller, despite
      desktop's temptation to cram more in.
- [ ] Containers can expand 30–40% for longer translated strings, even though English-only is
      assumed today (§3) — don't hard-code widths against current English string lengths.

## 9. Next steps

1. Taher reviews this spec (step 8 of `superpowers:brainstorming`).
2. **Figma pass:** build the real `Constants.qml` tokens as Figma variables (colors, type scale,
   spacing, radius), then construct high-fidelity screens for each section in §6–7 there — this is
   where the visual-correctness gap flagged in §4 gets fully closed, replacing this session's
   structural-only sketches.
3. Spec self-review (step 7) against this doc before implementation planning begins.
4. Hand off to `writing-plans` skill (step 9) once Taher signs off — inline execution, one task per
   commit, same adapted approach prior sessions in this chat environment have used (no
   subagent-dispatch tool available here).
