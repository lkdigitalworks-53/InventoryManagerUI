# Helix — Mobile UX Redesign Prototype

Clickable, mobile-first redesign of the Business Management app, exploring:

- **Card-based minimalism** with generous spacing & soft shadows
- **Glassmorphism** on page headers, tabbar, and floating controls
- **Fluid color gradients** in KPI cards, status pills, and CTAs
- **Thumb-zone navigation** — primary actions live at the bottom
- **Progressive disclosure** — `<details>` advanced sections, bottom-sheet modals
- **Smart status indicators** — colored chips with semantic palette
- **Modern auth flow** — sign in / sign up / forgot pw / OAuth / passkey-ready
- **Modern sales report** — hero card with animated area chart + bar breakdown
- **Slick, clean type scale** — system font stack with tightened tracking on display

## Open it

```
prototypes/mobile-redesign/index.html
```

Just double-click it, or:

```bash
# from repo root
start prototypes/mobile-redesign/index.html        # Windows
open  prototypes/mobile-redesign/index.html        # macOS
```

No build step. Pure HTML/CSS/JS.

## Top bar controls

- **iOS / Android** — switches the device chrome (notch ↔ pinhole, corner radius)
- **Light / Dark** — toggles the theme (CSS variables)
- **Jump to flow…** — fast-travel to any screen for review

## Flows you can click through

| # | Flow | Path |
|---|---|---|
| 1 | Splash → Sign in → Dashboard | `Get started` → email + password → `Sign in` |
| 2 | Sign up → Workspace setup → Dashboard | `Create account` → choose business type → `Continue` |
| 3 | Forgot password | `Forgot?` → submit email → returns to sign in |
| 4 | New order | Tab `Orders` → FAB `+` (or center FAB) → adjust qty → `Place order` |
| 5 | Order detail | Tap any order row → status pill, items, totals → `Mark complete` |
| 6 | Add product | Tab `Stock` → FAB → expand `Advanced` for SKU/reorder → `Save` |
| 7 | Restock | Tap any product → set qty → `Confirm` |
| 8 | Sales report | Tab `Sales` → switch period (Day/Week/Month/Year) |
| 9 | Invite teammate | Tab `Staff` → FAB → pick role card → `Send invite` |
| 10 | Profile + sign-out | Tap avatar in dashboard header → `Sign out` |
| 11 | Notifications | Bell icon on dashboard → bottom sheet |
| 12 | Filters / Search / Import / Export | Header icons on Orders / Inventory / Sales |

## Files

```
index.html   markup for every screen + sheets, toolbar, tabbar
styles.css   design tokens, glass surfaces, gradients, animations, dark theme
app.js       routing, sheet/scrim, mock data render, form demos, platform toggle
```

## Re-skinning to QML

Each screen, status chip, and sheet maps 1:1 to existing QML components in
`qml/pages/` and `qml/helper/`. The CSS variables in `:root` (and `.theme-dark`)
correspond directly to properties in `qml/helper/CustomeTheme.qml` /
`Constants.qml` — port them first, then translate one screen at a time.
