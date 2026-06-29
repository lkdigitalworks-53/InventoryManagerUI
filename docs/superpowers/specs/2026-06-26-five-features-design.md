# Design — Five Features (New-Order Price, Report Swipe, Advanced-Open, Staff Credentials, Firestore Environments)

**Date:** 2026-06-26
**Status:** Approved for planning

Bundles five independent features requested together. Each is self-contained; they can
be implemented and merged in any order. Feature 5 (environments) is the only substantial
one — the other four are small, reuse-driven changes.

---

## Feature 1 — Price-change field in the New Order dialog

### Problem
`NewOrderDialog.qml` shows each cart line's price as read-only text
(`InventoryStore.formatCurrency(modelData.price) · qty N`, line ~281). The user can only
edit price in the **edit** dialog (`OrderDetailDialog.qml`), not while placing a new order.

### Solution
Port the editable per-line price field that already exists in
`OrderDetailDialog.qml` (lines ~562–603) into the New Order cart-row delegate. That field:
- is a `QQC.TextField` that commits on `editingFinished` / `accepted` (never per-keystroke),
- shows a plain number while focused (`text = String(model.price); selectAll()`) and
  formatted currency on blur,
- writes the committed value back into the line model.

For `NewOrderDialog` the line model is the immutable `selectedProducts` array, so add a
helper mirroring the existing `_setLineDiscount(idx, type, value)` (line ~456):

```qml
function _setLinePrice(idx, value) {
    if (idx < 0 || idx >= selectedProducts.length) return
    var v = parseFloat(value)
    if (isNaN(v) || v < 0) return                 // reject; keep old price
    var arr = selectedProducts.slice()
    arr[idx] = Object.assign({}, arr[idx], { price: v })
    selectedProducts = arr                         // triggers _totalsCache recompute
}
```

The price already flows into the `orderCreated` payload (`prods[].price`, line ~531) and
into `_totals()`/`_totalsCache`, so totals, tax, and the submitted order all pick the edited
price up automatically. **No Logic signal, store, or DataModel change.**

### Placement
Add the price field to the cart-row top row (next to the qty stepper) OR as a small labelled
field in the same row as the existing per-line Discount controls — match whichever reads
cleanest against the existing delegate layout. The qty-line currently renders
`formatCurrency(price) · qty N` as a subtitle; once price is editable, that subtitle keeps
showing the (now live) price so the line total still reads naturally.

### Verification
- Edit a line price → Subtotal / Tax / Total update on blur.
- Place the order → persisted order line carries the edited price (check order detail).
- Empty / negative / non-numeric input is rejected and the field re-syncs to the last good price.

---

## Feature 2 — Swipe left/right between report views

### Problem
On the Analysis page (`SalesPage.qml`) the six view modes (Value, Purchased, Current,
Revenue, Sold, Profit) are only switchable via the `SegmentedPill` (line ~297). The user
wants horizontal swipe to move between adjacent views.

### Direction (locked)
**Swipe-left → previous view; swipe-right → next view.** From Sold (`_MODE_SOLD = 4`):
swipe-left → Revenue (3), swipe-right → Profit (5). No wraparound — clamp at both ends.

### Gating (must mirror the pill)
The pill already restricts which modes a user can see:
- `canViewFinancials === false` (staff): only **Current (2)** and **Sold (4)** — the pill shows
  a 2-item model. Swipe must cycle only within `[Current, Sold]`.
- otherwise: full `[0,1,2,3,4,5]`.

So swipe operates over an **ordered list of *allowed* modes**, not raw `_viewMode±1`:

```qml
function _allowedModes() {
    return canViewFinancials
        ? [_MODE_VALUE,_MODE_PURCHASED,_MODE_CURRENT,_MODE_REVENUE,_MODE_SOLD,_MODE_PROFIT]
        : [_MODE_CURRENT, _MODE_SOLD]
}
function _stepView(dir) {                 // dir = -1 (prev) | +1 (next)
    var modes = _allowedModes()
    var cur = modes.indexOf(_viewMode)
    if (cur < 0) cur = 0
    var next = cur + dir
    if (next < 0 || next >= modes.length) return   // clamp, no wrap
    _viewMode = modes[next]
}
```

### Gesture handling (the careful part)
The report body is an `AppScrollView` (a vertical `Flickable`; see `AppScrollView.qml`).
Per memory `scrollview_touch_freedrag`, touch gestures on Android behave differently from
desktop, and a naïve `MouseArea` will steal vertical scrolling.

Approach: attach a horizontal swipe recognizer that **only acts on a dominantly-horizontal
gesture** and lets everything else fall through to the Flickable:
- Track press X/Y on press; on release compute `dx`, `dy`.
- Fire `_stepView()` only when `|dx| > threshold` (e.g. `dp(60)`) **and** `|dx| > |dy| * 1.5`
  (dominantly horizontal). `dx < 0` (finger moved left) = swipe-left = previous;
  `dx > 0` = swipe-right = next.
- Do not consume vertical drags — vertical scroll must keep working.

Preferred implementation: a `SwipeArea`-style handler or a `MultiPointTouchArea`/`DragHandler`
sized to the content that does not block the Flickable. Exact mechanism chosen during
implementation against what the existing `AppScrollView` allows; **must be device-verified**
(gesture/scroll conflict is the classic touch-only bug).

### Verification
- On a financials user, swipe through all six in order both directions; clamps at Value and Profit.
- On a staff account, swipe only toggles Current↔Sold.
- Vertical scrolling of the report still works (charts, lists scroll normally).
- Verify on an Android device, not just desktop.

---

## Feature 3 — Advanced section open by default (Add Product)

### Problem
`AddProductDialog.qml` — the "Advanced" disclosure (`advToggle.open`, line ~200) defaults to
`false`, hiding SKU, category, stock, reorder, tax, supplier on every open.

### Solution
Two-line change:
1. Default `property bool open: true` on `advToggle`.
2. In `onOpened` (the sheet reset block, line ~31), add `advToggle.open = true` so it re-opens
   every time the sheet is shown — not just on first construction (the toggle persists its
   state across opens otherwise).

Nothing else. The advanced `ColumnLayout` is already bound `visible: advToggle.open`.

### Verification
Open Add Product → advanced fields visible immediately; collapse, close, reopen → expanded again.

---

## Feature 4 — Always-visible staff credential fields

### Problem
`AddStaffDialog.qml` gates the App-role combo + temporary-password field behind a
`createLoginCheck` CheckBox (line ~175; fields `visible: createLoginCheck.checked`, line ~183).
The user wants the checkbox removed and the credential fields always visible, with login
treated as **mandatory**.

### Solution
1. **Remove** the `QQC.CheckBox` (`createLoginCheck`). The App-role `AppComboBox` and the
   `AuthPasswordField` become unconditionally visible (drop the `visible:` binding).
2. **Validation** in `trySubmit()` — password is now **always required** (≥6 chars),
   unconditionally (today it's only checked `if (createLoginCheck.checked)`, line ~230).
3. **Payload** — `createLogin: true` always (replace the `createLoginCheck.checked` reads at
   lines ~249 and ~254).
4. The provisioning flow (arm `Connections` listener BEFORE emitting `staffCreated`,
   per memory `sync_signal_listener_arm_first`) is preserved exactly — it already works for
   the always-create case.

### The Blaze reconciliation (in scope, important)
`Gateway.provisioningAvailable` is hard-coded `false` (pre-Blaze, per memory
`provisioning_blaze_gated`). `Gateway.provisionMember()` short-circuits with
`error: "provisioning-unavailable"`, which `AuthService` maps to a friendly message.

If "mandatory" meant "always hard-attempt provisioning now", **no staff member could be added**
in the current build — `trySubmit` would always end in `authFailed`. The user confirmed the
mandatory-UI interpretation. Resolution:

- The **UI is mandatory** (no checkbox, password required) — this is what ships now.
- **Actual provisioning still respects `provisioningAvailable`.** When it's `false`, the staff
  record is still created and the existing graceful-degrade notice
  ("login access coming once the server is set up") is shown — the add does **not** hard-fail.
- When Blaze + the Cloud Function are deployed and `provisioningAvailable` flips to `true`,
  mandatory provisioning becomes truly enforced with **no further code change**.

This keeps the dialog's existing success/degrade handling (the `Connections` block, lines
~41–55) intact. Confirm-on-build: the degrade path must close the sheet + show the notice
(not leave it stuck — the `_provisioning`/`busy` flags already cover this).

### Verification
- Add Staff dialog shows App-role + password with no checkbox.
- Submitting with a blank/short password is blocked with a validation error.
- With `provisioningAvailable=false`: staff record is created, friendly "coming soon" notice
  shown, sheet closes (no stuck-open, no hard error).

---

## Feature 5 — dev / test / prd environments in Firestore

### Goal
Run the app against isolated Firestore data per environment (`dev`, `test`, `prd`) so testing
never touches production data. Switching is **build-time** via the existing `PRODUCT_STAGE`.

### Strategy — named Firestore databases in the one existing project
Firestore supports multiple **named databases** per project. Keep the single project
(`inventorymanager-48392`, region `asia-southeast1`); add two databases alongside the existing
default:

| Env   | Firestore database | REST path segment                |
|-------|--------------------|----------------------------------|
| `prd` | `(default)`        | `.../databases/(default)/documents` (unchanged) |
| `test`| `test`             | `.../databases/test/documents`   |
| `dev` | `dev`              | `.../databases/dev/documents`    |

**Shared across all envs:** Firebase Auth user pool, Storage bucket, Cloud Functions
(these are not Firestore; a shared login pool across dev/test is convenient). **Only the
Firestore database segment changes.** Existing production data stays in `(default)` untouched.

### Build-time selection via `PRODUCT_STAGE`
`PRODUCT_STAGE` is extended from two values (`test`/`publish`) to three:

| `PRODUCT_STAGE` | env    | database    |
|-----------------|--------|-------------|
| `dev`           | `dev`  | `dev`       |
| `test`          | `test` | `test`      |
| `publish`       | `prd`  | `(default)` |

> ⚠️ Behaviour change: `PRODUCT_STAGE "test"` previously pointed at the **production**
> `(default)` database. After this change it points at the new **`test`** database. This is
> intentional and is the whole point of the feature. Document in README + AGENTS.md.

#### Plumbing (build-time → QML)
1. **`CMakeLists.txt`** — emit `PRODUCT_STAGE` as a compile definition:
   ```cmake
   target_compile_definitions(appBusinessManagement PRIVATE
       PRODUCT_STAGE_DEF="${PRODUCT_STAGE}")
   ```
   (Add to the existing `target_compile_definitions` call at line ~90, or a sibling call.)
2. **`main.cpp`** — expose to QML as a context property, mirroring the 6 existing
   `setContextProperty` registrations:
   ```cpp
   engine.rootContext()->setContextProperty(
       QStringLiteral("APP_STAGE"), QStringLiteral(PRODUCT_STAGE_DEF));
   ```
   Guard with a fallback in case the macro is somehow undefined.

### Single point of change — `FirebaseService.qml`
All env logic lives here. Replace the hard-coded `(default)` (lines ~9–10):

```qml
// env resolved once from the build-time APP_STAGE context property.
readonly property string environment: _resolveEnv()          // "prd" | "test" | "dev"
readonly property string databaseId:  environment === "prd" ? "(default)" : environment
readonly property string databaseUrl: "https://firestore.googleapis.com/v1/projects/"
                                       + projectId + "/databases/" + databaseId + "/documents"

function _resolveEnv() {
    var stage = (typeof APP_STAGE !== "undefined" && APP_STAGE) ? String(APP_STAGE) : ""
    if (stage === "dev")     return "dev"
    if (stage === "test")    return "test"
    if (stage === "publish") return "prd"
    return "prd"   // fail-safe: unknown/unset → production (default db)
}
```

**Fail-safe default = `prd`** (confirmed): a misconfigured/unflagged build talks to the real
production database, never silently to an empty dev db.

Then route the two remaining hard-coded `(default)` references through `databaseId`:
- `_buildCommitWrites` doc-name (line ~220):
  `"projects/" + projectId + "/databases/" + databaseId + "/documents/" + ...`
- The `:commit` URL (line ~279) already builds off `databaseUrl` — OK once `databaseUrl` uses
  `databaseId`.

Every `get/put/patch/remove` derives its URL from `databaseUrl`/`databaseId`, so **all data
access switches automatically** with no per-call change.

### `Constants.firebaseDatabaseUrl`
`Constants.qml:8` has a second hard-coded `(default)` URL, but a grep shows it has **no code
consumers** (only its definition + one unrelated comment). It is legacy/dead. Action: update
its value to a comment noting `FirebaseService.databaseUrl` is the live source of truth (or
delete it if nothing references it) — do **not** leave a misleading prod-only URL that a future
caller might wire up.

### Visual env indicator
Add a small **env badge** in an unobtrusive spot (e.g. under the Profile/Settings header, or
the app header subtitle) reading `DEV` / `TEST`, **hidden when env is `prd`**. So a non-prod
build is unmistakable and a test build is never confused for production. Bind to
`FirebaseService.environment`.

### One-time backend setup (console/CLI — documented, not app code)
1. In the Firebase console / `gcloud`, create two Firestore databases in project
   `inventorymanager-48392`, region `asia-southeast1`: id `dev` and id `test`.
2. Apply the **same security rules** (`FIRESTORE_RULES.md`) to each database.
3. `dev` and `test` start empty — consistent with the `mvp_fresh_data` phase (no migration /
   back-compat code; clean schema). The exact `gcloud firestore databases create
   --database=dev ...` commands go in the spec/README.

### Cloud Functions — documented follow-up (out of scope now)
`Gateway.qml` functions (`recordMutation`, `runCutover`, `provisionMember`) write to
`(default)` server-side and are disabled today (`provisioningAvailable=false`). They are
**not** env-aware yet. This is a **documented follow-up**, not built now (YAGNI): when Blaze +
Functions are deployed, each function must target the **caller's env database** (derive env
from the request or a deployed per-env function). Noted in AGENTS.md §8 (Compliance & Audit
Agent) so it isn't lost.

### Verification
- Build with `PRODUCT_STAGE "dev"` → app reads/writes `dev` db (starts empty; create a product,
  confirm it appears in the `dev` database in the console and NOT in `(default)`).
- Build with `PRODUCT_STAGE "publish"` → app reads/writes `(default)` (existing prod data
  present); env badge hidden.
- Build with `PRODUCT_STAGE "test"` → `test` db; env badge shows `TEST`.
- Confirm Auth login works the same in all three (shared user pool).

---

## Out of scope / explicit non-goals
- No runtime in-app env switcher (build-time only, per decision).
- No separate Firebase projects / no per-env apiKey/bucket/functionUrl.
- No data migration into dev/test (fresh-start, MVP phase).
- No env-aware Cloud Functions yet (documented follow-up).
- No change to staff-add hard-failing pre-Blaze (graceful degrade preserved).

## Docs to update after implementation
- `AGENTS.md` — env strategy + Build Agent notes; Cloud Functions follow-up in §8.
- `SKILLS.md` — new skill entry for the env model (how `FirebaseService.databaseId` is
  resolved from `PRODUCT_STAGE`); note the New-Order price field and report swipe.
- `README.md` — `PRODUCT_STAGE` → env table + one-time `gcloud` database-create steps.
