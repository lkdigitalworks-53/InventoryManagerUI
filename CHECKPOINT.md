# Session Checkpoint — Desktop UX Design

**Started:** 2026-07-14
**Branch:** `feature/desktop-ux-design`
**Status:** Step 3 complete. Step 4 (propose 2-3 approaches + recommendation) — presented, awaiting Taher's pick.

## Step log

1. Cloned `InventoryManagerUI` fresh via a claude.ai chat session (no subagent-dispatch tool
   available here, same constraint as prior Cloud sessions — inline execution, one task at a time,
   once we reach implementation).
2. Read `AGENTS.md`, root `CHECKPOINT.md` (by-name-chart session), the `docs/superpowers/`
   directory listing, and `KNOWN-ISSUES.md` before touching anything.
3. Archived the by-name-chart session's root `CHECKPOINT.md` to
   `docs/superpowers/specs/2026-07-11-analysis-by-name-chart-CHECKPOINT.md`, matching the
   convention already used for the 2026-07-10 tax/size-field and 2026-07-11 P0-gateway
   checkpoints. Status preserved as-is (complete locally, awaiting Taher's diff review + a push
   PAT) — NOT resolved or touched by this session.
4. Created branch `feature/desktop-ux-design` off `main`.
5. Flagged two things unrelated to desktop scope, found during exploration:
   - `feature/analysis-by-name-chart-all-views` is fully implemented, committed locally, and
     waiting on Taher's review + a push PAT.
   - The by-name-chart checkpoint's step log noted the repo is reachable with no auth despite an
     earlier memory note saying it had been made private — never investigated. Taher called it
     "the public repo" this session, which may settle it, but flagged for explicit confirmation
     given it holds Firebase config and the compliance architecture.
6. Corrected scope understanding: this is a multi-tenant, 4-role RBAC (owner/admin/manager/staff)
   business-management app (branded **Karobar**) with an in-progress India compliance architecture
   (P0–P7: immutable audit ledger, GST/HSN fields, DPDP privacy work — P0 code-complete, not yet
   live). Not a simple single-user stock tracker. This changes the desktop-personas question from
   a guess into something the existing RBAC model should mostly answer.
7. Asked Taher Q1 (superpowers:brainstorming step 3, one question at a time): which of the 4 roles
   should get a desktop experience, framed against the hypothesis that owner/admin are back-office
   (desktop-shaped) and manager/staff are floor-facing (mobile-shaped).
8. Taher answered Q1: **Owner, Admin, Manager** get desktop; **Staff** stays mobile-only.
   Hypothesis partly wrong — Manager is in, not just Owner/Admin. Working theory: Manager likely
   does local back-office work (approvals, staff scheduling, end-of-day reconciliation) in
   addition to floor-facing tasks, unlike Staff.
9. Asked Q2: for Owner/Admin/Manager, does desktop REPLACE their mobile use, or do they use BOTH
   (same person, mobile on the floor + desktop at a workstation, depending on context)? This
   resequences the plan below — delivery-target question now becomes Q3, not Q2, since
   replace-vs-coexist changes what "delivery target" even needs to solve for (e.g. cross-device
   sync/consistency matters a lot more if it's coexist).
10. Taher answered Q2: **Both** — same people, mobile on the floor + desktop at a workstation.
    Coexist confirmed, not replace. Cross-device consistency is a real requirement, not a nice-to-have.
11. Checked `CMakeLists.txt` / `CMakePresets.json` before proposing delivery approaches. Major
    finding: **the app already builds and runs as a Windows desktop app today.**
    `CMakePresets.json` only defines `felgo-mingw-*` (Windows/MinGW) presets — no Android preset
    lives there, implying local dev already happens via Windows desktop builds for fast iteration,
    Android/iOS shipped separately. `CMakeLists.txt` has a comment confirming Windows *and* Linux
    binary naming is "verified working." Grepped for existing `Qt.platform.os`/desktop branches
    (`qml/Main.qml`, `GlassHeader.qml`, etc.) — all narrow OS-integration fixes (file-picker filter
    format, safe-area insets, export/share behavior), nothing about navigation, density, or layout.
    Confirms: desktop *build* is a solved problem; desktop *design* is the actual gap, exactly
    matching Taher's original ask.
12. Presented step 4 (superpowers:brainstorming): 3 approaches with trade-offs —
    (A) extend the existing Felgo/QML app with desktop-aware screens, same C++/Gateway/RBAC backend
    (B) Qt Widgets native desktop UI, same backend, new UI codebase
    (C) separate web admin dashboard (Firebase Hosting already scaffolded)
    Recommended A, given (A)'s build path is already proven and (C) risks reimplementing
    compliance-critical logic in a second stack. Awaiting Taher's choice.

## Files touched this session (not committed)
- `CHECKPOINT.md` (this file, new)
- `docs/superpowers/specs/2026-07-11-analysis-by-name-chart-CHECKPOINT.md` (moved from root,
  content unchanged)

## Open decisions
- Commit cadence for this session's housekeeping (archive + this file) — asked previously
  (checkpoint-doc commits vs. app-code commits), not yet answered. Holding uncommitted until
  Taher weighs in, consistent with not assuming.
- Repo visibility (see step 5) — flagged, not yet confirmed.

13. Sketched the desktop shell as a visual (HTML mockup via Visualizer): persistent left sidebar,
    top bar with search/identity, master-detail pattern demonstrated on Orders (list left, detail
    right, no page navigation — the core desktop upgrade over mobile's tap-to-open). Nav grouped
    into "everyone" (Dashboard/Orders/Inventory/Analysis) vs. "Owner, admin only"
    (Staff/Activity/Settings) as a stated hypothesis, flagged clearly as a guess.
14. Taher corrected the hypothesis: Manager sees Staff, Activity, AND Settings too — no nav-level
    role split among the 3 desktop roles after all. Sidebar simplifies to one flat 7-item list.
    Shell/master-detail direction itself not objected to — treating as approved (Step 5, section 1
    of superpowers:brainstorming done). Open sub-question for later, not now: whether Manager's
    *permissions* within Staff/Activity differ from Owner/Admin even though nav *visibility*
    doesn't — deferred to when that specific section gets designed.
15. Moving to section 2: the Analysis/Sales page (`qml/pages/SalesPage.qml`, 116K — largest file
    in the app). Checking its current structure before proposing a desktop redesign.

16. `SalesPage.qml` findings: one page, segmented-pill switcher between the 6 modes
    (Value/Current/Sold/Purchased/Revenue/Profit), a hero metric card with trend chart for
    whichever mode is active, breakdown section below that adapts to mode — one mode visible at a
    time. Profit mode has its own Realised/Potential sub-toggle. A real `canViewFinancials`
    permission gate already exists in code, restricting non-financial roles to Current/Sold only —
    whether Manager currently has that flag is unconfirmed but doesn't block the design either way.
17. Proposed two directions for desktop Analysis, with trade-offs: (A) overview strip of all 6
    metric cards at once + click-to-drill-down, vs. (B) same one-at-a-time pill model, just bigger.
    Leaning A as the more genuinely desktop-native answer; flagged B as the safer/lower-risk
    "bigger phone" option. Awaiting Taher's pick before visualizing.

18. Taher: move to spec now (not full mockups for remaining screens), plus keep mobile's color/
    theme/feel on desktop, plus use qt-ui-design/design-system/Figma/Canva skills where they fit.
19. Found the real design tokens (`qml/helper/Constants.qml`, referenced by `CustomeTheme.qml`)
    before writing anything further. Corrected an honest gap: both visual sketches shown earlier
    this session used generic placeholder colors/icons from the sketching tool itself, not
    Karobar's real palette. Real tokens: brand1-5 (`#6366f1`→`#14b8a6`), 16px default radius up to
    999 (pill), KPI/hero cards use real gradients (`gradPrimary`/`gradHero`/`grad1-4`), icons are
    mostly full-color SVGs via `colorIconSet`, not monochrome. Flagged a genuine design tension:
    that soft/rounded/gradient/colorful mobile language vs. desktop density — resolved in the spec
    by keeping decoration on hero/KPI/CTA elements, flattening dense surfaces (tables, lists).
20. Read `qt-development-skills:qt-ui-design` and `design:design-system` skills before writing the
    spec. Named two previously-unconfirmed defaults per the former's context-check (resolution
    range ~1280-1920px responsive; English-only/LTR/keyboard+mouse) rather than turning them into
    more questions. No literal "ui ux pro max" skill exists — read as "full treatment," applied
    the two above instead. No existing Figma file found referenced anywhere in the repo — Figma
    deferred to next phase (build real tokens as variables, construct high-fidelity screens there)
    rather than folded into this text spec.
21. Wrote `docs/superpowers/specs/2026-07-14-desktop-ux-design.md` (step 6 of
    superpowers:brainstorming): summary, decisions-confirmed table, named assumptions, visual
    language (with the tension + resolution from step 19), IA, two documented interaction patterns
    (master-detail; metric overview strip + drill-down) using the design-system skill's extend
    format, pattern-level treatment of Inventory/Staff/Dashboard/Activity/Settings, an
    accessibility checklist, and next steps. NOT committed yet (still no PAT, still no answer on
    commit cadence). Awaiting Taher's review (step 8).

## Next steps
- Awaiting Taher's answer to Q2 (replace-vs-coexist for Owner/Admin/Manager)
- Q3 next (one at a time): desktop delivery target — Qt Quick (shared QML, Felgo) vs. Qt
  Widgets (native desktop controls) vs. something else — informed by the existing `win/`/`macx/`
  app-icon scaffolding (prepared, unused), the fact mobile is already Felgo/QML, and whatever Q2
  reveals about sync/consistency needs
- Continue steps 3–9 of `superpowers:brainstorming` from there
- `qt-development-skills:qt-ui-design` gets pulled in once we're actually laying out screens, not
  before (Taher noted the Qt/QML + UI/UX skills are installed and ready)
