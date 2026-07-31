# Session Checkpoint — GitHub Actions PR checks (build/test)

**Started:** 2026-07-31
**Branch:** `ci/github-actions-pr-checks`
**Status:** Brainstorming in progress (per `superpowers:brainstorming`). No design approved yet,
no workflow YAML written yet.

## Step log

1. Cloned `InventoryManagerUI` fresh into the sandbox (per standing session instructions).
2. Archived the stale root `CHECKPOINT.md` (left over from the completed/merged
   `feature/analysis-by-name-chart-all-views` session, last touched 2026-07-12) to
   `docs/superpowers/specs/2026-07-12-analysis-by-name-chart-all-views-CHECKPOINT.md`.
3. Created branch `ci/github-actions-pr-checks` off `main`.
4. Explored the repo for CI feasibility ahead of brainstorming. Key findings:

   **No existing CI.** `.github/` only has agent config files (`qt-qml-review`, `qt-cpp-review`,
   etc.); no `.github/workflows/`.

   **Three independent test surfaces exist, already written:**
   - `tests/*.qml` (28 files) — Qt Quick Test, run via `qmltestrunner`. Historical baseline:
     140 cases passing (verified locally by Taher via Felgo's bundled Qt). 3 newer suites
     (`tst_Gateway`, `tst_OutboxStore`, and one more per AGENTS.md) are **written but never
     actually run**, even locally.
   - `functions/test/*.test.js` (48 tests) — plain Node `node --test` against `functions/lib/`
     pure-logic modules. No emulator, no network. `cd functions && npm test`.
   - `test/firestore.rules.test.js` — needs the Firebase emulator:
     `firebase emulators:exec --only firestore "node --test test/"`. Not yet run anywhere
     (sandbox sessions have had no network path to the emulator distribution).

   **QML tests appear Felgo-independent by design.** Every `tests/tst_*.qml` file imports only
   `QtQuick`, `QtTest`, and pure `.pragma library` `.js` helpers (or the `qml/model` singleton
   directory, which itself imports only `QtQuick`/`QtCore`). The project's own convention
   (documented in `AGENTS.md`) is that anything needing the full Felgo `App` context
   (`dp()`/`sp()`/`Theme`/`GlassHeader`) is deliberately kept OUT of this suite. This suggests the
   QML test job could plausibly run on a stock open-source Qt6 install on a Linux runner, with
   no Felgo SDK at all — but this is not yet verified by actually running it.

   **A real app "build" is very likely infeasible on a standard GitHub-hosted runner.**
   `CMakeLists.txt` starts with `find_package(Felgo REQUIRED)`, and `main.cpp` directly
   `#include <FelgoApplication>` — so even a C++ syntax/compile check of the entry point requires
   the proprietary, license-gated Felgo SDK. `CMakePresets.json` only defines Windows/MinGW
   presets pointing at `C:/Felgo/...`. Felgo does offer a separate hosted product, "Felgo Cloud
   Builds," for this exact problem — but it's its own platform (connects to GitHub directly), not
   something wired up through a `.github/workflows/*.yml` file.

   **Flagged, not yet actioned (adjacent finding, not this task):** `CMakeLists.txt` has a
   `PRODUCT_LICENSE_KEY` hardcoded in plaintext, committed to a public repo. Raised to Taher for
   awareness; out of scope for the CI task unless he wants it addressed.

5. Presented findings to Taher; awaiting answers to scoping questions before proposing approaches.

## Next steps

- Get Taher's answers on scope (what "build" should mean given the Felgo constraint; which of the
  three test surfaces to wire up; self-hosted runner appetite; how to handle the exposed license
  key).
- Propose 2-3 approaches with trade-offs.
- Present design, write spec to `docs/superpowers/specs/`, get approval.
- Hand off to `writing-plans` for the implementation plan.
