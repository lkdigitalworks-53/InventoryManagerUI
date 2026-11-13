# P1 S4b: the stock register on the phone — design (S4b-1 built, S4b-2 designed)

Status: **S4b-1 (client engine) built** on `feat/2026-11-12-p1-s4b1-register-client-engine`. S4b-2 (page) is designed here, not built. Parent: `2026-11-11-p1-s4a-stock-register-design.md` (server), `2026-06-06-india-compliance-roadmap-design.md` section 4.3 (CGST Rule 56(2)).
Decisions D1 to D12 were DEFAULTED (Taher asked for one chat turn, no interactive gate: same practice as SR-D1..13). Each is vetoable in the PR; each says what lost and what it costs.

## 1. Where P1 stands (read from `main` @ `66d3f8d`, 2026-11-12)

| Slice | State |
|---|---|
| S1a, S1b, S2a-c, S2d-1, S2f | merged |
| S4a server read model + 4 follow-ups (#193, #195) | merged |
| **S4b-1 client engine** | **this PR** (pure model + service, dormant, nothing calls it) |
| **S4b-2 page + entry point** | next |
| S4c CA column layout / export | after the CA answers P1 design section 8 |
| S2d-2 (imported-order `sale` kind), S3 (`batchRef`), S2e (pickers, waits for the CA) | open |

## 2. Slicing (D1)

S4b is split in two so each fits one chat turn and one review:
- **S4b-1 (this PR):** `qml/helper/StockRegisterModel.js` (every decision, pure) and `qml/model/StockRegisterService.qml` (send, answer once). Fully provable in the sandbox and in CI. Zero UI.
- **S4b-2 (next):** the page, one entry row, wiring in `Main.qml`. Felgo only: provable on a device, not in the sandbox.

Lost: one PR with the page. Reason: the page is the part that cannot be tested here; shipping the engine first means the page is a thin painter over about 350 checked assertions (Skill 161), and the engine is reviewable without a device.
Cost: nothing user-visible after this PR. Said plainly in the PR and the test plan.

## 3. Decisions (each with the alternative that lost)

| # | Decision | Lost alternative and why | Cost |
|---|---|---|---|
| D2 | Periods are **fixed IST (UTC+05:30)**, computed with UTC arithmetic only. A guard fails on any local-time getter. | Device local time (what `BreakdownMath.periodWindow` / Analysis use). Local time moves every boundary when the phone is not set to India, and a statutory register must not depend on a phone setting. | Analysis and the register can disagree on "this month" for a phone outside IST around midnight. Every window is printed with "(IST)". There is no tenant time-zone setting; if one is ever added, `IST_OFFSET_MS` is the one place to change. |
| D3 | Presets: this/last month, this/last **quarter**, this/last **financial year** (Apr to Mar), plus custom days. | Month only (smallest). Quarterly GST returns and the annual register are the real periods, and the code is one function. | More tests (done). |
| D4 | A current period's `to` is its **end** (e.g. 1 Dec for November), not "now". | Cap `to` at the phone's clock: a row stamped by the server a moment ahead of a slow phone would fall outside the window and vanish from a statutory report. | "Closing" on a running period equals the balance now (nothing is later), but the label reads "to 30 Nov". The page shows "as of" from `readAt`. |
| D5 | Custom range = two days, **both inclusive**, sent as `[from-day 00:00, day-after-to 00:00)`; impossible days (`2026-02-30`) refused, never rolled; years 2000 to 2100. | Free-form instants. A person thinks in days, and the server's half-open rule is the engine's problem. | No time-of-day periods. |
| D6 | **No cross-product totals.** Summary has counts only. | Sum opening/in/out/closing. Products have different units (pcs, metres, kg), so the sum is meaningless and would look authoritative. | A CA wanting a value total needs `valueAtCost` (S2e). |
| D7 | Rows with no movement ever, zero everywhere and agreeing with stock are **hidden by default** (`showAll` shows them). A row that does NOT reconcile is never hidden. | Show every product. A shop with thousands of products would scroll through noise to find the ten that moved. | Hidden count is in the summary so it is never silent. |
| D8 | **Server order is kept** (named first, case-insensitive, deleted after). | Re-sort on the client: two sources of truth for order. | None. |
| D9 | **On demand only**: no timer, no resume hook, no auto-refresh; single flight; `cached(win)` returns the last good answer for the same window, workspace and role without a request. | Reuse the L4a auto-refresh: one request reads the whole ledger, billed per row (S4a design section 5). | The cache is memory only (lost on app restart), so a cold open of the page costs one scan. |
| D10 | Client timeout **125 s**, above the server's 120 s function timeout (a guard parses both). | A short timeout (30 s): aborts a scan that is still valid and still billed, and the retry bills it again. | The person may wait up to about two minutes. The page must show a spinner AND a Cancel button (S4b-2). Cancel does not stop the server. |
| D11 | An answer is shown only if the **echoed window equals the requested one** and the shape is right; otherwise `badAnswer`. A workspace or role change during flight drops the answer. | Trust a 200. A silently moved boundary is a wrong statutory report with no error (Skill 163 rule 10). | None in practice. |
| D12 | A 401 asks `AuthService.ensureFreshToken()` (the one silent door) and tells the person to tap again. No automatic retry. | Wait for the refresh and resend: more moving parts and a second billed scan on a bad token. Also `sessionRecheckWiring` forbids any other file calling `refreshIdToken(true)`. | `ensureFreshToken` refreshes only when the local clock says the token is near expiry; a token the server rejects but the clock trusts stays rejected until the session recheck runs (KNOWN-ISSUES, S4b-1 item 4). |

## 4. What S4b-1 contains

- `StockRegisterModel.js`: `canView`, `presetWindow`, `customWindow`, `customErrorText`, `windowKey`, `requestBody`, `classify`, `message`, `validateAnswer`, `fmtQty` (Indian grouping), `buildView` (flat rows, summary, warning flag), `detailLines` / `detailFor` (per-kind IN/OUT in the kind order).
- `StockRegisterService.qml` singleton: `load(win, callback)` (callback exactly once: ok or a kind), `cancel()`, `cached(win)`, `clear()`; status snapshot for QTBUG-49896; `AuthStore` role and tenant read at send and at answer.
- Dormant: `SRS-04` greps that nothing but tests names the service.

## 5. S4b-2: the page (designed, NOT built)

- **Entry:** a row "Stock register" in `ProfilePage` under Account, visible when `StockRegisterModel.canView(AuthStore.role)`; opens an overlay in `Main.qml` like `staffPageOverlay` (z 200, closes on tab change). Not a fifth tab (the tab count is pinned to 4 by `sessionRecheckWiring`).
- **Layout (qt-ui-design):** `GlassHeader` with back; period chips (`ChipScroller`: month, last month, quarter, last quarter, FY, last FY, custom); a caption with `text` of the window and "as of <readAt>"; a **Load register** primary button (never auto); a summary line (shown, hidden quiet, warnings); a warning card when `hasWarning` (skipped ledger rows, mismatches, dropped rows); a `ListView` of flat rows (title, note, four number cells, tap to expand `detailFor`); a "Show all products" switch; Cancel while loading; an inline error with Retry when `retryable`.
- **State the page owns:** selected preset, custom days, `showAll`, `busy`; a tap latch (Skill 156 rule 5, Skill 161 rule 10); rebuild the model in place when the order is unchanged (Skill 161 rule 3); build on `aboutToShow` (rule 17).
- **Not in S4b-2:** share/export (S4c, needs the CA's layout), value columns (S2e).
- **S4b-2 test plan items to carry:** the wiring test for the entry row and overlay, the page glue's real functions in a vm (Skill 155), an emulator e2e case QML-to-endpoint (S4a KNOWN-ISSUES 9), device steps for role gating (blocked until a non-owner login exists).

## 6. Costs and risks, said plainly

- **Nothing user-visible ships.** The app is unchanged until S4b-2.
- **The QML test file never ran in the real engine here** (no Qt in the sandbox, by rule). It was shim-run in Node (13/13); CI is the oracle.
- **A register page is expensive to open.** One scan per Load; at the 250 000-row cap about 15 US cents (UNVERIFIED price, S4a design section 5). Fine for a monthly compliance report.
- **IST only** (D2). Right for the stated market; wrong if the app is sold abroad.

## 7. Advice on what comes next (honest)

1. **S4b-2 next**, as designed above: it makes P1 visible and shows what derived `adjustment` rows look like on a dev tenant, which tells us whether S2e pickers are urgent.
2. **Then S2d-2** (small): imported-order sales count as `sale`; today the register understates supplies for them (S4a KNOWN-ISSUES 7).
3. **Ask the CA now**, in parallel: P1 design section 8 (which kinds are receipts, supplies, returns) blocks S4c and S2e. Building either first risks throwing it away.
4. Do **not** add auto-refresh to the page, and do **not** raise the client timeout without raising the server's.
