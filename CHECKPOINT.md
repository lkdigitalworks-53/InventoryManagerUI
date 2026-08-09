# Session Checkpoint — End-to-end testing strategy (brainstorm)

**Started:** 2026-08-09
**Branch:** `docs/e2e-testing-strategy-design` (new, off `main` @ `a749525`)
**Status:** Phase 1 design approved by Taher; spec written to
`docs/superpowers/specs/2026-08-09-e2e-testing-phase1-design.md` and pushed. Awaiting Taher's
review of the written spec before an implementation plan is written.

## Goal (as stated by Taher)

Existing test layers (QML `tst_*.qml` via qmltestrunner, Cloud Functions logic tests via
`node --test`, Firestore rules tests via emulator) run in isolation. Taher wants to know if we
can run **full scenario end-to-end tests** — real code path (Stores → Gateway → FirebaseService
→ actual persistence layer), executed against every PR build — that exercise actual
add/update/delete workflows and validate the resulting state.

## Step log

1. Cloned `InventoryManagerUI` fresh from `https://github.com/lkdigitalworks-53/InventoryManagerUI.git`
   (cloned cleanly over HTTPS, no PAT needed for the clone itself this session).
2. Archived stale root `CHECKPOINT.md` (workspace-name-edit session, merged to main in
   `a749525` on 2026-08-04) to
   `docs/superpowers/specs/2026-08-04-workspace-name-edit-CHECKPOINT.md`.
3. Created branch `docs/e2e-testing-strategy-design` off `main` (following the existing
   `docs/<topic>-design` naming convention used for design-only branches, e.g.
   `docs/async-write-sequencing-design`).
4. Explored current test/CI architecture — key findings that will shape the design options:
   - **`.github/workflows/checks.yml`** runs 3 independent jobs per PR: `qml-tests`
     (qmltestrunner, offscreen), `functions-tests` (`node --test` on `functions/`),
     `firestore-rules-tests` (**already uses the real Firebase emulator** via
     `firebase emulators:exec --only firestore`).
   - **`firebase.json`** only configures the **firestore** emulator (port 8080). No `auth` or
     `functions` emulator block exists yet.
   - **`qml/model/FirebaseService.qml`**: `databaseUrl` is hardcoded to
     `https://firestore.googleapis.com/v1/projects/<id>/databases/<dbId>/documents` — only the
     *database id* (`(default)`/`test`/`dev1`) is switchable; the **host is always real Google
     Firestore**, never a local emulator.
   - **`qml/model/AuthService.qml`**: `authBaseUrl`/`tokenBaseUrl` are hardcoded to real
     `identitytoolkit.googleapis.com` / `securetoken.googleapis.com` — no auth-emulator support.
   - **`qml/model/Gateway.qml`**'s `_send`/`_sendBatch` XHR straight to a live Cloud Functions
     URL; `tests/tst_Gateway.qml`'s own header comment explicitly flags this as a known gap:
     *"A real mock-HTTP layer to test `_send`/`_sendBatch`'s actual request/response handling
     would need new test infrastructure this session didn't build."*
   - **Cloud Functions** (`functions/index.js`) are all `functions.onRequest` (plain HTTP), not
     `onCall` — reachable by the emulator's normal HTTP endpoint shape, no special SDK needed
     client-side.
   - Existing `tests/tst_*.qml` are component/unit-level (pure-logic `.pragma library` helpers,
     or a single Store/singleton with network calls carefully avoided via guards) — **none
     currently launch the full app or drive a multi-step business workflow.**
   - `test/firestore.rules.test.js` carries a note that **this sandbox (Claude's container)
     has no network egress to Firebase's emulator distribution** — rules tests are written here
     but verified in CI/on Taher's machine, not in-session. This constrains how much of any new
     E2E harness we can *actually run* in-session vs. author-and-hand-off.

## Open questions / not yet decided

- Whether "E2E" means driving the full UI (qmltestrunner mouse/key events through real screens)
  vs. driving Store/Gateway methods directly against emulated backends (no UI, but real
  network round-trip through Gateway → Functions emulator → Firestore emulator).
- Whether to add emulator-host overrides to `FirebaseService.qml`/`AuthService.qml` (build-time
  flag vs. env var vs. new `EnvConfig` stage) and the security/footgun implications of that.
- CI cost/time budget for a 4th job (or extending an existing one) that boots the full emulator
  suite (firestore + auth + functions) — every PR, per Taher's ask.
- Scope for a first slice: pick 1 representative scenario (e.g. create order → deduct stock →
  complete order) vs. broad coverage from day one.

## Trade-off investigation (round 1)

Taher asked for trade-offs before picking a driving layer. Two more critical findings that
shape the whole design space:

- **`qml/Main.qml`** is a Felgo `App { }` root (`import Felgo`, `licenseKey: "..."`,
  `CMakeLists.txt` does `find_package(Felgo REQUIRED)`). Current CI (`checks.yml`) installs
  **plain Qt** via `jurplel/install-qt-action` — **no Felgo SDK at all**. So `qmltestrunner`
  cannot load `Main.qml` in CI today, license question aside.
- Only 5/95 `.qml` files `import Felgo` directly (`Main.qml`, `Constants.qml`,
  `CustomeTheme.qml`, `Icon.qml`, `PhotoSourceSheet.qml`) — but business dialogs like
  `NewOrderDialog.qml` transitively depend on Felgo's global `dp()`/`sp()` functions and the
  `Constants` singleton **77 times in that one file alone**, via `import "../helper"`. So even
  component-level instantiation of a single dialog (no `App` root, no license) likely still
  needs the Felgo plugin registered — **unverified, flagged as a spike item**.
- Confirmed via `grep -h "^import" tests/*.qml`: **every existing test imports only pure JS
  helpers or `qml/model`** (plain `QtObject` singletons, Felgo-free). **Zero** existing tests
  touch `qml/pages` or `qml/components` — the dialog/UI layer has **never** been under
  automated test, and that's exactly the layer the positional-index bug (memory: `NewOrderDialog`
  and `OrderDetailDialog`) lived in.

**Two independent axes on the table:**
1. **Driving layer** — service-level (Store/Gateway methods, no UI) vs. component-level UI
   (instantiate real dialog QML, simulate clicks — Felgo-dependency unverified) vs. full-app UI
   (Main.qml through Felgo's `App` root — confirmed needs new CI infra, possibly licensing).
2. **Backend target** — local Firebase Emulator Suite (extend `firebase.json`, matches the
   precedent already set by `firestore-rules-tests`) vs. the real cloud `test` Firestore
   database (no new emulator infra, but real latency, shared mutable state across concurrent PR
   runs, no free reset).

**My leaning (not yet proposed as a decision):** local Emulator Suite as backend (free, fast,
hermetic, matches existing precedent) + a two-tier driving strategy — broad service-level
integration coverage as the default, plus a small number of targeted component-level UI tests
for the specific dialogs where the known bug class lives, contingent on the Felgo-headless spike
passing. Full `Main.qml`/App-root automation explicitly NOT the default given the confirmed CI
cost — parked as a possible later phase.

## Correction after deeper read (round 2) — Gateway mode is NOT "direct" today

Checked `Gateway.qml` source directly rather than trusting `tests/tst_Gateway.qml`'s comments:

- **`property string mode: "gateway"`** is the actual declared default in `Gateway.qml` — not
  `"direct"`. The file's own header comment (`"direct" — DEFAULT...`) and
  `tests/tst_Gateway.qml`'s `test_mode_defaults_to_direct()` assertion are both **stale** —
  written for an earlier state of the code, before mode was flipped to `"gateway"` in production
  (matches memory: locking was wired into 3 dialogs, `LockManager` shipped). **This is a real,
  currently-undetected gap in the existing suite** — worth flagging to Taher separately from
  this session's scope, since it's exactly the "tests giving false confidence" problem he's
  worried about, caught by inspection rather than by the tests themselves.
- Confirmed via `InventoryStore.addProduct()`: the store does an in-memory optimistic update
  (`products = arr`) then calls `Gateway.recordMutation(...)` — it **never** calls
  `FirebaseService.put()` itself for the working doc. In `"gateway"` mode, the actual Firestore
  write happens **inside the `recordMutation` Cloud Function** (POST to a hardcoded
  `https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordMutation`, Bearer
  `idToken`).
- **Revised Phase-1 scope implication:** the Inventory CRUD pilot needs the **Functions
  emulator**, not just Firestore — `Gateway.functionUrl` is a third hardcoded-to-production URL
  needing an emulator-host override, alongside `FirebaseService.databaseUrl`.
- Auth: still likely avoidable as a full running emulator if the Functions emulator's Admin SDK
  is started with `FIREBASE_AUTH_EMULATOR_HOST` set — Cloud Functions' `verifyIdToken()` accepts
  unsigned emulator-format tokens in that mode. **Not fully verified** — flagged as a spike item
  for the Phase 1 plan, not asserted as fact.

## Aside: fixed the stale Gateway.mode test (Taher: "fix it now, quickly")

- `Gateway.qml`'s header comment and inline property comment both still said `"direct"` was the
  default/deployed-safe mode. Confirmed via `git log -p` that commit `649046d fix(gateway):
  change mode from "direct" to "gateway" for compliance with Cloud Function deployment`
  deliberately flipped it — not accidental drift. Updated both comments to reflect reality.
- `tests/tst_Gateway.qml`'s `test_mode_defaults_to_direct()` asserted `Gateway.mode === "direct"`
  and had been passing — but it's structurally incapable of testing what it claims: `init()` runs
  before every test function and unconditionally sets `Gateway.mode = "direct"`, so the test
  never observes the singleton's true declared value. It went stale after `649046d` without ever
  failing. Removed it and left a comment explaining why (and that this is exactly the class of
  gap the E2E work is meant to close — an integration/E2E check, not a per-case-reset unit test,
  is the right place to verify a real deployed default).
- Diff reviewed with Taher and approved. Committed as two commits: `e80eae4` (checkpoint
  housekeeping) and `6f00e1f` (the Gateway.qml/tst_Gateway.qml fix). Pushed to
  `docs/e2e-testing-strategy-design` using a PAT Taher supplied in-conversation, passed directly
  in the push URL only (never stored in git config / `origin`). Taher will regenerate the PAT
  after this feature is fully complete, not after each push, by his own choice this session.

## Design approved, spec written

Taher approved the Phase 1 design (emulator infra, `emulatorHost` QML override, Node seed
script, new `e2e-tests` CI job, Inventory CRUD pilot) as presented, with one on-the-fly
correction: the emulator-host override is a plain settable QML property, not any of the three
mechanisms I originally offered as multiple-choice options (runtime env var / new EnvConfig
build stage / test-only) — simpler and lower-risk than all three, since qmltestrunner doesn't go
through `main.cpp` and no CMake/Felgo-license surface needs touching.

Spec written to `docs/superpowers/specs/2026-08-09-e2e-testing-phase1-design.md`. Status: Draft,
awaiting Taher's review of the doc itself before an implementation plan is written (per the usual
spec → review → plan → review → implement sequence — writing the spec is not implementation).

## Next step

Get Taher's sign-off on the spec doc itself (he approved the design conversationally; the
written doc should still get an explicit look), then write the implementation plan.

## Implementation plan written

Taher said "go ahead with implementation plan and execution" — proceeded per the
`superpowers:writing-plans` skill. Deep-dived the actual code (not just the spec's assumptions)
while drafting, which surfaced real refinements worth tracking:

- **`Gateway.qml` needs zero code changes** — its Cloud Function URLs (`functionUrl` etc.) are
  already plain mutable `property string`, not computed/readonly like `FirebaseService.databaseUrl`
  was. A test can set `Gateway.functionUrl` directly. This is a real, evidence-based deviation
  from the spec's Component 2 (which proposed an `emulatorHost` property on both files) — flagged
  explicitly, not silently applied.
- Traced `InventoryStore.addProduct()`'s full call chain: `_resolveSupplierId` (sync if the
  supplier name is already known — seeded so the pilot stays inventory-only) →
  `nextProductId`/`FirebaseService.mintCounterValue` (direct Firestore write, bypasses Gateway) →
  `Gateway.recordMutation` (the actual audited write, via the emulated `recordMutation` Cloud
  Function).
- Confirmed `FirebaseService._resolvePath` auto-prefixes non-`tenants/`/`users/` paths with
  `tenants/{AuthStore.tenantId}/` — so `counters/products` actually lands at
  `tenants/{tenantId}/counters/products`, which the existing `firestore.rules`' generic
  `match /{collection}/{docId}` fallback covers. No rules gap.
- Confirmed `_request()` defaults its Bearer header to `AuthStore.idToken` when no explicit token
  is passed — one seeded ID token covers both the direct Firestore emulator calls and the
  Gateway/Functions-emulator call.
- Designed the auth-token hand-off: `test/e2e/seed.js` (Admin SDK) creates an emulator Auth user,
  mints a custom token, exchanges it for a real ID token via the Auth emulator's
  `identitytoolkit`-compatible REST endpoint, and writes it (with `uid`/`tenantId`/supplier ids)
  to a generated `test/e2e/.fixture.json` that the QML test reads via a synchronous `file://` XHR
  — the standard QtTest fixture-loading idiom.
- Verified `firebase-admin@14.2.0` resolves from this sandbox's npm registry access (not
  previously a root dependency) — will be added for real in Task 3.

Plan saved to `docs/superpowers/plans/2026-08-09-e2e-testing-phase1.md`. Five tasks: (1)
`firebase.json` emulator blocks, (2) `FirebaseService.emulatorHost`, (3) `test/e2e/seed.js`, (4)
`tests/e2e/tst_InventoryE2E.qml`, (5) the `e2e-tests` CI job. Everything up through Task 4 is
static/unverifiable-in-sandbox by construction — this environment cannot reach the Firebase
emulator distribution — so the plan's real correctness test is Task 5's first CI run.

## Next step

Commit+push the plan doc, then begin executing tasks in order (inline in this session — no
subagent dispatch tool is available in this chat interface, so `superpowers:executing-plans`
rather than `superpowers:subagent-driven-development`), one commit per task, confirming the diff
with Taher before each commit per his standing rule.
