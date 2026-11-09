# CHECKPOINT — 2026-11-09 Toasts under dialogs + Restock busy overlay missing — resume here

**Branch:** `fix/2026-11-09-toast-and-busy-above-dialogs`, cut from `main` @ `eb6391b` (PR #188 merged; Taher says #189 merged too, tested on device).
**Commit identity:** `dextran52@gmail.com` in author and in every commit message. PAT per command only (`git -c http.extraHeader=...`), never in a URL, `.git/config`, the repo or memory; after a push `grep -c ghp_ .git/config` must print 0. Taher rotates the PAT after the work; do not spend tokens on it.
**Rules in force:** no build/run, no Qt in the sandbox (CI is the QML oracle), branch + push without asking, tests + test plan, honest trade-offs, caveman FULL in chat only (documents in normal prose), short scope per chat turn.
**Skills used:** `systematic-debugging` (root cause first, evidence from Qt source, failing-test discipline via mutants), `qt-qml`, `qt-ui-design`, `ponytail`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-09-pr188-sweep-merged-prev-CHECKPOINT.md`.

## Report (Taher, device test after #188/#189)
1. No busy spinner on top of the Restock dialog after Confirm.
2. Every toast is drawn BELOW an open dialog (all dialogs, not only Restock).

## Root causes (Phase 1, read from code and from Qt's own source)
1. `BottomSheet` shows its full-sheet `BusyOverlay` only when `busy && busyMessage.length > 0`. `RestockDialog` set `busy` and never `busyMessage`, so only the small spinner inside the Confirm button ran. `OrderDetailDialog` and `ImportPreviewDialog` set a message; `AddProductDialog`, `AddStaffDialog`, `NewOrderDialog` do not (finding, not fixed here).
2. Dialogs and sheets are Popups, drawn in the window Overlay. Qt 6.8 `qquickoverlay.cpp`: `setZ(1000001)`, so the Overlay is above the whole window item tree. `ToastHost` is an ordinary item in that tree (z 999 only orders it among siblings), so it can never be above a popup. The same source shows the Overlay ignores presses no popup claims (`handlePress` ends in `event->ignore()`), and becomes visible when it has child items.

## Steps
- [x] 1. Read memory, five skills, CHECKPOINT of #188 sweep. Clone, branch off `main`. Archive previous checkpoint.
- [x] 2. Evidence: read `BottomSheet`, `BusyOverlay`, `ToastHost`, `Toast`, `RestockDialog`, `Main.qml` z layers, all popup roots; fetched `qquickoverlay.cpp` (Qt 6.8 branch) for z, visibility, event pass-through (mouse and touch).
- [x] 3. Fix 2: `ToastHost` moves the pill into `QQC.Overlay.overlay` (z 10000) while a toast shows, back to the host in `_release()`; `slideDown.stop()` on each new toast; pill centred by `x` binding, not an anchor. Commit `713dffc`.
- [x] 4. Fix 1: `RestockDialog.busyMessage` constant. Same commit.
- [x] 5. Tests: `functions/test/toastHostLayer.test.js` (17), `functions/test/restockBusyOverlay.test.js` (6). 19/19 hand mutants killed (`/tmp/mut.py`, list in the test plan).
- [x] 6. Full suites after `npm ci` in `functions/` (needed: `node-mocks-http` is a dev dependency): functions 1280/1280 (+23), `.github/scripts` 905/905. Docs: test plan + README row, Skill 158 + SKILLS-INDEX, AGENTS, README, KNOWN-ISSUES.
- [ ] 6b. Commit docs + tests, push, open PR (see git log for the last confirmed step).
- [ ] 7. Read CI. Taher: device test (test plan on-device section, especially H5/H6 tap-through, D-1 veto).

## Decisions (vetoable in the PR)
- D-1: pill is in the Overlay ONLY while a toast shows (not always). For: idle app never on the "Overlay visible with a child" path; blast radius at most 5 s. Against: a reparent per toast, one more function. Rejected: always in the Overlay (simplest, but cannot be device-checked here); a Popup-based toast (a popup item takes presses in its area and changes focus rules).
- D-2: `busyMessage` is a constant on `RestockDialog`. Rejected: set at the tap (stale or missing on an early return); BottomSheet shows the overlay on every `busy` (changes every sheet, flicker on sub-second saves).
- D-3: toast position unchanged (bottom, above the tab bar zone). On a bottom sheet it lies over the lower part of the footer buttons; taps pass through it. Alternative (top-anchored while a dialog is open) is a design call.
- D-4: `slideDown.stop()` added: without it a toast arriving during the previous one's slide-away was hidden when that slide finished (pre-existing race, made worse by reparenting).

## Resume
Everything pushed is on the remote branch; read `git log` and this file. CI is the QML oracle (no new QML test: ToastHost, BottomSheet, RestockDialog cannot load under `qmltestrunner`).
