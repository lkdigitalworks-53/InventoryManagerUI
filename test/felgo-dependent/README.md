# test/felgo-dependent/

QML test files that need the real Felgo SDK to compile — they instantiate a full app `Page`
(e.g. `InventoryPage`, `OrdersPage`), and every real Page transitively needs
`qml/helper/Constants.qml`, which does `import Felgo`.

No job in `.github/workflows/checks.yml` points `qmltestrunner` at this directory (the "QML
Tests" job scans `tests/`, "E2E Tests" scans `test/e2e/` under a Firebase emulator — neither
installs Felgo). Confirmed by an actual CI run failing with `module "Felgo" is not installed`
when these files lived under `tests/` (2026-09-01) — not a guess.

Run these manually on a machine that has the Felgo SDK (Qt Creator with Felgo installed), or
fold their specific checks into an on-device test-plan checklist. They're not part of any
automated pass/fail gate.
