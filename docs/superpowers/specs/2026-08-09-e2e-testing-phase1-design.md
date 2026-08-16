# Design: End-to-End Testing, Phase 1 — Emulator Infra + Inventory CRUD Pilot

**Status:** Draft — awaiting Taher's review before any implementation plan is written.
**Branch:** `docs/e2e-testing-strategy-design`
**Skills invoked to reach this doc:** `superpowers:using-superpowers`, `superpowers:brainstorming`.
Full back-and-forth, including the trade-off discussion and the stale-`Gateway.mode`-test aside,
is in the session checkpoint: `CHECKPOINT.md` (root, this session).

## 1. Problem statement

Karobar has three test layers today — QML unit tests (`qmltestrunner`), Cloud Functions logic
tests (`node --test`), and Firestore rules tests (real Firestore emulator via
`@firebase/rules-unit-testing`) — and they run in isolation, per PR, in `.github/workflows/checks.yml`.
None of them exercise a real add/update/delete workflow through the actual production code path:
Store → `Gateway` → `FirebaseService`/Cloud Function → Firestore → response → Store update.

Investigating this surfaced two concrete findings that motivate the work, not just the abstract
goal:

1. **The dialog/UI layer has zero test coverage.** `grep -h "^import" tests/*.qml` shows every
   existing test imports only pure JS helpers or `qml/model` singletons — never `qml/pages` or
   `qml/components`. The positional-index bug (`NewOrderDialog.qml`/`OrderDetailDialog.qml`,
   pre-rebase on `feature/product-picker-search`) lived exactly there, and would not have been
   caught by any test in the current suite.
2. **The existing suite can give false confidence.** `tests/tst_Gateway.qml`'s
   `test_mode_defaults_to_direct()` asserted a default that had been stale since `Gateway.mode`
   was deliberately flipped to `"gateway"` in commit `649046d` — and it never failed, because
   `init()` overwrote the value before the assertion ever ran. Fixed as an aside this session
   (commit `6f00e1f`), but it's a live example of exactly the risk end-to-end coverage is meant
   to reduce.

## 2. Scope

**In scope (Phase 1, this design):**
- Firebase Local Emulator Suite extended to `auth` + `functions` (currently only `firestore` is
  configured).
- A settable `emulatorHost`-style override on `FirebaseService.qml` (Firestore REST) and
  `Gateway.qml` (Cloud Functions URL), no-op by default.
- A Node fixture-seeding script (`test/e2e/seed.js`) reusing the `@firebase/rules-unit-testing`
  admin-bypass pattern already proven in `test/firestore.rules.test.js`.
- One new CI job (`e2e-tests`) that boots the full emulator suite and runs the pilot test.
- One pilot scenario: Inventory CRUD (add → update → delete a product), driven **service-level**
  — calling `InventoryStore` methods directly, no UI involved — verified against real emulator
  state.

**Explicitly out of scope / deferred to Phase 2 (separate spec, separate branch):**
- Component-level UI tests (instantiating `NewOrderDialog.qml`/`OrderDetailDialog.qml` directly
  under `TestCase`, simulating clicks). Gated on an unresolved spike: whether Felgo's `dp()`/`sp()`
  globals and the `Constants` singleton resolve outside a Felgo `App{}` root at all. Not attempted
  in Phase 1.
- Full `Main.qml` / Felgo `App`-root UI automation. Confirmed blocked as-is —
  `find_package(Felgo REQUIRED)`, a license key, and CI today (`checks.yml`) installs plain Qt via
  `jurplel/install-qt-action` with no Felgo SDK. Not revisited unless Taher explicitly wants full
  user-journey coverage and is willing to fund the CI/licensing work that implies.
- Orders / stock-deduction / lock-manager scenarios (richer, exercises more of `Gateway`). Once
  Phase 1 proves the emulator path works end to end, extending to more stores is mechanical —
  deliberately not bundled in here so the first slice stays provably small.
- `AuthService.qml` changes. Believed unnecessary for Phase 1 — see §4.
- Promoting `e2e-tests` to a required/blocking CI check. Starts non-blocking; promotion is
  Taher's call, made outside this repo (branch protection settings), after a stabilization
  period.

## 3. Component 1 — emulator infra (`firebase.json`)

Add `auth` (port `9099`) and `functions` (port `5001`) blocks to the existing `emulators` config,
alongside the current `firestore` block (port `8080`). Both ports are Firebase's own documented
defaults, chosen for least surprise. No changes to `.firebaserc` or the three-database
(`(default)`/`test`/`dev1`) setup — the emulator is a separate, ephemeral instance, orthogonal to
that.

## 4. Component 2 — QML emulator-host override

`FirebaseService.qml`: add `property string emulatorHost: ""`. When empty (the default, every
existing build), `databaseUrl` resolves exactly as today — real `firestore.googleapis.com`, zero
behavior change. When set (e.g. `"http://127.0.0.1:8080"`), `databaseUrl` is built against that
host instead, same path/database-id suffix.

`Gateway.qml`: same pattern — `property string emulatorHost: ""` redirecting `functionUrl` when
set.

`AuthService.qml`: **not changed in Phase 1.** The Firestore emulator (and, per Firebase's
documented behavior, the Functions emulator's `admin.auth().verifyIdToken()` when
`FIREBASE_AUTH_EMULATOR_HOST` is set) accepts unsigned emulator-format ID tokens without a real
sign-in round trip. The pilot test seeds `AuthStore.idToken`/tenant claims directly with a
fake-but-valid token rather than driving the real `identitytoolkit.googleapis.com` flow. This is
flagged as **believed, not yet proven** against this specific codebase — first item in the spike
list, §7.

This is a deliberately minimal change: no CMake changes, no new `EnvConfig` build stage, nothing
that touches `versionCode` or triggers a Felgo license-key regeneration. A future
env-var-driven manual on-device override (reading a real OS env var in `main.cpp`, forwarding it
to these same properties) stays possible later without any rework — just not built now, since
Taher's standing rule is not to build/run the app until asked.

## 5. Component 3 — fixture seeding (`test/e2e/seed.js`)

New Node script, run once per CI job invocation, before `qmltestrunner`. Reuses the
`@firebase/rules-unit-testing` admin-bypass pattern from `test/firestore.rules.test.js` to write:
- One tenant document
- One membership document (owner role, matching whatever claims the fake ID token will carry)

The QML-side pilot test never has to construct or bypass Firestore rules itself — it only needs
the emulator host overrides (§4) and a token whose claims match what `seed.js` wrote.

## 6. Component 4 — CI job (`e2e-tests`)

New job in `.github/workflows/checks.yml`, parallel to the existing three (`qml-tests`,
`functions-tests`, `firestore-rules-tests`) — **not** folded into `qml-tests`, so that job's
current speed is preserved for the fast unit suite.

Steps (union of what the existing jobs already do separately):
1. Checkout, install Qt (as `qml-tests` does today).
2. Install Node, `firebase-tools`, Java (as `firestore-rules-tests` does today).
3. `functions: npm ci` (as `functions-tests` does today).
4. `firebase emulators:exec --only firestore,auth,functions "node test/e2e/seed.js && qmltestrunner -input tests/e2e -platform offscreen -o results.xml,junitxml"`.
5. Upload/report results, same pattern as the existing jobs.

`tests/e2e/` is a **new, separate directory** from `tests/` — the existing unit-test file set and
`qml-tests` job composition don't change at all.

**Recommendation (Taher's call, not mine to make unilaterally):** mark `e2e-tests` non-blocking
for the first several PRs it runs on, promote to a required check once proven stable. New,
first-of-its-kind CI infra that's a hard merge-blocker from day one tends to get bypassed under
deadline pressure rather than fixed, which defeats the point.

## 7. Component 5 — pilot test (`tests/e2e/tst_InventoryE2E.qml`)

Three cases, service-level (no UI):
1. **Create** — call `InventoryStore.addProduct(...)`, then independently verify via a raw REST
   `GET` against the Firestore emulator that the doc exists with expected fields.
2. **Update** — mutate a field, verify the emulator doc reflects it.
3. **Delete** — remove, verify absence.

This exercises the real path this whole effort is about: `InventoryStore` → `Gateway.recordMutation`
(mode `"gateway"`, the real production default — see §1 finding 2) → POST to the emulated
`recordMutation` Cloud Function → Admin SDK write to the emulated Firestore → response back to
the client.

## 8. Known unknowns — spike items for the implementation plan, not resolved here

Being explicit about what's still unverified, so the plan phase budgets time for it rather than
discovering it mid-implementation:

1. **Fake ID token shape.** Exact claims/format the Functions emulator's `verifyIdToken()` will
   accept without a real signature, and whether `firebase emulators:exec` sets
   `FIREBASE_AUTH_EMULATOR_HOST` automatically for the functions process or needs it set
   explicitly.
2. **Emulator readiness timing.** Whether `firebase emulators:exec`'s own readiness gate is
   sufficient before `qmltestrunner` starts issuing requests, or whether the seed script itself
   needs a retry/backoff on first connect.
3. **Admin SDK auto-detection in `functions/index.js`.** `admin.initializeApp()` is called bare
   today (confirmed by reading the source) — Firebase's Admin SDK is documented to
   auto-detect emulator env vars, but this hasn't been proven against this specific codebase's
   `scopedDb(env)` wrapper.

## 9. Rollout order (proposed)

1. `firebase.json` emulator blocks (§3) — no code depends on this yet, safe to land alone.
2. `emulatorHost` properties on `FirebaseService.qml`/`Gateway.qml` (§4) — additive, default
   no-op, safe alongside existing behavior.
3. `test/e2e/seed.js` (§5), spiking unknowns #1–#3 (§8) as part of getting it working.
4. `tests/e2e/tst_InventoryE2E.qml` (§7), once seeding is proven.
5. `e2e-tests` CI job (§6), last — wire it up once the local (or CI-run-once) path is proven, not
   before.

Each step is its own commit, per the usual workflow, with Taher's confirmation before each.
