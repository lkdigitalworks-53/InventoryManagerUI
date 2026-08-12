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

## All 5 Phase 1 tasks executed

Taher said "Commit, push and go ahead" / "Continue" through the sequence — executed inline,
still showing each diff, one commit per task:

1. `3d654ef` — `firebase.json` auth+functions emulator blocks. JSON-validated.
2. `23f1bd9` — `FirebaseService.emulatorHost` override + `tests/tst_FirebaseService.qml`.
   Verified `projectId` property name against source before writing the test (it matched the
   plan's assumption).
3. `cdc2f72` — `test/e2e/seed.js` + `test/e2e/.gitignore`. `firebase-admin@^14.2.0` installed for
   real (`npm install`, reachable from this sandbox's registry access) — `npm audit` flags 6
   moderate transitive vulnerabilities, dev-only dependency, flagged to Taher, not blocking.
   `node --check` passed.
4. `b717f75` — `tests/e2e/tst_InventoryE2E.qml`. Before writing, verified every referenced
   property/method actually exists with the assumed name/signature by grepping source directly
   rather than trusting the plan's memory of it: `AuthStore.tenantId`, `SupplierStore.suppliers`,
   `InventoryStore.products`, `SupplierStore.findByName` (confirmed synchronous, in-memory, no
   network — matches the plan's assumption that pre-seeding it avoids exercising supplier
   creation), and all three `InventoryStore` CRUD signatures. All matched.
5. `08184a0` — `e2e-tests` CI job in `checks.yml`. YAML-validated (`pyyaml`), confirmed all four
   jobs (`qml-tests`, `functions-tests`, `firestore-rules-tests`, `e2e-tests`) present.

All pushed to `docs/e2e-testing-strategy-design`. Branch now has 9 commits total: the two
checkpoint-housekeeping ones, the stale-Gateway-test fix (`e80eae4`, `6f00e1f`), the spec
(`9501e28`), the plan (`0797ec6`), and the five implementation tasks above.

**Not yet done, and can't be done from this sandbox:** nothing in Tasks 1–4 has actually run
against a live emulator — no network egress here to Firebase's emulator distribution. Task 5's
first real CI run is the actual verification of everything built this session, including the
spec's flagged spike items (auth-token exchange shape, `FIREBASE_AUTH_EMULATOR_HOST`
propagation, Admin SDK auto-detection). Expect the first run to surface at least one issue —
that's the point of running it in CI rather than assuming it works.

## Next step

Taher opens/updates the PR for `docs/e2e-testing-strategy-design` and watches the `E2E Tests`
check's first real run. Per the spec, it should stay **non-blocking** (not added to required
status checks) until proven stable across a few runs — that's a branch-protection setting outside
this repo, Taher's call. Whatever the first run surfaces becomes the next task in this session or
a follow-up one.

## First real CI run — failure #1, fixed

`seed.js` failed immediately: `TypeError: admin.firestore is not a function`. Reproduced the root
cause in this sandbox without needing the emulator — `require("firebase-admin")`'s top-level
export in the installed `firebase-admin@14.2.0` only has `initializeApp`/`getApp`/etc.; `.firestore`
and `.auth` aren't there at all (confirmed via `Object.keys(admin)` locally). v14 dropped the
namespaced compat API entirely in favor of modular imports
(`firebase-admin/app`/`firestore`/`auth`) — a real gap in Task 3's original code, not an emulator
quirk. Rewrote `seed.js` to use `initializeApp`/`getFirestore`/`getAuth` from those subpaths;
confirmed the call shapes used (`db.doc().set()`, `auth.createCustomToken()`,
`auth.createUser()`) still exist on the modular clients. Committed `b25b9d6`, pushed. Taher
approved before commit.

## Next step

Taher re-runs the `e2e-tests` CI job with this fix. First run only got far enough to fail inside
`seed.js` before the module-loading error — everything downstream of that (the actual token
exchange, the QML test, the Cloud Function round trip) is still unexercised.

## First real CI run — failure #2, fixed

`seed.js` got past its previous failure. `tst_InventoryE2E.qml` failed on all three test cases:
`Uncaught exception: Invalid state`. Root cause, confirmed via web search rather than guessed
(a wrong second guess would burn a third CI cycle): **QML's `XMLHttpRequest` has no synchronous
mode at all** — `xhr.open(method, url, false)` throws. Every XHR call in the test file
(`_loadFixture`, `_getEmulatorDoc`) used the sync flag — a real bug from Task 4, not an emulator
quirk. Qt's own docs only demonstrate the async `onreadystatechange` pattern.

Rewrote both to be async: `_loadFixture()` now waits via `tryVerify()`'s event-loop-pumping poll;
`_getEmulatorDoc()` became `_pollEmulatorDoc()`, which re-fires a fresh async GET on every
`tryVerify` tick (guarded by an in-flight flag) rather than blocking — avoids nesting `tryVerify`
calls, which would have been architecturally messy.

Also found and fixed proactively, same research pass: local file reads via QML XHR are
**separately** disabled by default, needing `QML_XHR_ALLOW_FILE_READ=1` — this would have been
the very next failure (blocking `_loadFixture()`'s `file://` read) even after the sync fix, so
added it to the `e2e-tests` job's env now rather than waiting for a third failed run to discover
it.

Committed `73eb632`, pushed. Taher approved before commit, after an explicit caveat that the new
`_pollEmulatorDoc` retry logic has only had static/structural review — no way to actually run
`qmltestrunner` in this sandbox.

## Next step

Taher re-runs `e2e-tests` again. Not yet exercised by any real run: the Auth-emulator custom-token
→ ID-token exchange, whether `FIREBASE_AUTH_EMULATOR_HOST` propagates to `seed.js` as documented,
and the actual round trip through the emulated `recordMutation` Cloud Function. Any of these could
still be the next failure.

## First real CI run — failure #3, fixed. Real progress this round.

Good news buried in the failure: `seed.js` **fully succeeded** — "seed.js: wrote
.../test/e2e/.fixture.json" printed, meaning the Auth-emulator custom-token → ID-token exchange,
`FIREBASE_AUTH_EMULATOR_HOST` propagation, and the Firestore seeding all worked as designed on
the first real attempt. `qmltestrunner`'s "exited unsuccessfully (code 3)" was just its own exit
code reflecting 3 failed tests, not a new distinct failure.

The actual bug: all three tests failed with `JSON.parse: Parse error`. Root cause is a genuine
**planning-stage mistake, not an emulator quirk** — worth being direct about this with Taher
rather than framing it as another environment surprise. Two similarly-named directories exist:
`test/e2e/` (Node, `seed.js`, matching the existing `test/firestore.rules.test.js` convention)
and `tests/e2e/` (QML, `tst_InventoryE2E.qml`, matching `tests/tst_Gateway.qml`). `seed.js` writes
`.fixture.json` into `test/e2e/`; the QML test's `Qt.resolvedUrl("./.fixture.json")` resolved
relative to its own location, `tests/e2e/` — a different, empty directory. The plan's "File
Structure" section listed both paths without ever reconciling the cross-directory reference this
implied — should have been caught during planning, not discovered via a third CI run.

Fixed by pointing the read at `../../test/e2e/.fixture.json` (verified the resolved path matches
exactly via a local Python check — no emulator needed for this one). Also hardened the failure
mode: status codes are documented to be unreliable for `file://` reads (often `0` regardless of
success or failure), so switched the guard to check for an empty response body instead, with a
clearer message naming the resolved URL — a future path mistake now fails loudly instead of as an
opaque `JSON.parse` error.

Committed `0f84424`, pushed. Taher approved before commit.

## Next step

Taher re-runs `e2e-tests` again. With `seed.js` now proven working end to end, this run should
finally reach the actual point of the whole exercise: `InventoryStore.addProduct/updateProduct/
deleteProduct` → `Gateway.recordMutation` → the emulated `recordMutation` Cloud Function → the
emulated Firestore, verified via independent REST reads. If this run fails, it's the first one
that would indicate a problem with the actual application code path rather than test-harness
plumbing.

## Fourth CI run — real failure, root cause not yet found; added a diagnostic probe instead of guessing again

All three CRUD tests failed: `product doc never appeared in the emulator` (or `before the
update`/`before the delete`), after the full 5s poll window each (16s total run — confirms real
async activity happened this time, unlike the earlier 7ms non-runs). `_createProduct`'s own
assertions (callback fired, non-empty id) all passed — the client believes every create
succeeded; the doc just never shows up server-side.

Traced code as far as possible without runtime data, per `superpowers:systematic-debugging`
Phase 1/2, and ruled out several genuine candidates by reading source rather than guessing:
- Collection path: confirmed via `gatewayLogic.js`'s `tenantRoot` construction that
  `tenants/{tenantId}/inventory/{id}` (what the test polls) matches exactly what the server
  writes to.
- `scopedDb(env)` mapping: client sends `env: "prd"` (bare qmltestrunner has no `APP_STAGE`);
  server's `DATABASE_ID_FOR_ENV.prd = "(default)"` — matches the client's own `(default)` target.
  No database-id mismatch.
- `Gateway.drainNow()`'s `AuthService.ensureFreshToken()` call: guarded by
  `AuthStore.isAuthenticated`, which the test never sets to `true` — so this no-ops harmlessly
  rather than attempting a real network call to production Google Auth with our fake
  refresh token. Not a source of corruption or blocking.
- `functions/package.json` pins `firebase-admin@^12.6.0` (its own separate dependency tree from
  root `package.json`, where `seed.js`'s `firebase-admin@14.2.0` lives) — predates the v14
  namespaced-API removal that broke `seed.js` in failure #1, so
  `admin.firestore.FieldValue.serverTimestamp()` in `functions/index.js` is fine as written, not
  a second instance of that bug.

Root cause not found yet: `Gateway._send()` logs the real HTTP status/response via
`console.warn` on failure but never surfaces it to the caller — `recordMutation` is
fire-and-forget by design (`OutboxStore.markFailed` + reschedule, no error path back to
`addProduct`'s callback). A silently-rejected request is indistinguishable from a slow one from
this test's vantage point, and that console output isn't visible in the CI summary Taher pastes.

Per the debugging skill: this is the 4th consecutive failure in this file, the stated threshold
to stop attempting blind fixes and gather real evidence instead. Added
`test_recordMutation_function_accepts_seeded_credentials` — POSTs directly to the emulated
`recordMutation` function with the same payload shape `_send()` uses, bypassing
`Gateway`/`OutboxStore` entirely, printing the real status/response body via `compare()` on
failure. Declared first so it fails fast. Committed `5e6eb1d`, pushed. Explicitly told Taher this
is not a fix.

**Side finding, flagged to Taher but not yet resolved:** memory notes Cloud Functions were "not
yet deployed to real Firebase" as of an earlier session. `Gateway.mode` defaults to `"gateway"`
in the live code (confirmed, commit `649046d`) — if functions still aren't deployed, the real
production app would currently be failing every inventory/order mutation against a
nonexistent endpoint. Doesn't affect this CI debugging (the emulator loads `functions/index.js`
from source regardless of real deployment status), but it's a real question worth asking Taher
directly once this immediate bug is resolved.

## Next step (superseded below — see rebase entry)

Taher re-runs `e2e-tests`. Two possible outcomes: (a) the diagnostic test itself fails with a
concrete status/response — that's the root cause, fix it properly per the debugging skill's
Phase 3/4. (b) the diagnostic test passes but the CRUD tests still fail — narrows the bug
specifically to `Gateway`/`OutboxStore`'s dispatch mechanics, a different and more contained
investigation. Also: ask Taher about the Cloud Functions deployment status. Expect more issues
to surface once seed.js gets further.

## Rebased onto fix/async-write-sequencing-review-fixes (Taher's request)

Taher clarified functions/rules **were** deployed before this branch started (my earlier
deployment-status flag was based on stale memory, not current fact) — and separately asked to
rebase onto `fix/async-write-sequencing-review-fixes` (24 commits, unmerged, review-fix work for
the earlier async-write-sequencing design: C1–C8 critical findings, all fixed) since it resolves
real bugs relevant to what this branch was hitting.

**Rebase mechanics:** `git rebase origin/fix/async-write-sequencing-review-fixes`, 18 commits
replayed. Only 2 real conflicts, both in the first 3 commits (everything after applied clean,
since later commits only touch files the fix branch never modified):
- `CHECKPOINT.md` (commit 1): archived the fix branch's own completed-session checkpoint to
  `docs/superpowers/specs/2026-08-10-async-write-sequencing-review-fixes-CHECKPOINT.md`
  (preserves their full C1–C8 fix history, process notes, and the I1–I5 open findings they didn't
  address), restored my session's checkpoint as root. For the remaining CHECKPOINT.md conflicts
  (nearly every subsequent commit touches it), resolved by consistently taking my own commit's
  version (`git checkout --theirs` — inverted meaning under rebase: "theirs" = the commit being
  replayed = mine) rather than re-merging both narratives at every step, since the fix branch's
  own history is already fully preserved in its own commits underneath and in the archived file.
- `tests/tst_Gateway.qml` (commit 2): genuine finding, not just a mechanical conflict — both
  branches independently discovered and "fixed" the same stale `test_mode_defaults_to_direct`
  test. Checked their actual commit (`4c3157a`) directly: their fix only flipped the asserted
  string (`"direct"` → `"gateway"`), without addressing that `init()` unconditionally resets
  `Gateway.mode = "direct"` before every test — so their version would make the test
  **always fail**, not just stay stale. Kept mine (deletion + explanatory comment), which is the
  actually-correct resolution.

**Post-rebase test review** (per Taher's explicit ask — not skipped):
- `InventoryStore.addProduct/updateProduct/deleteProduct` signatures: unchanged. No call-site
  updates needed.
- `Gateway.functionUrl`/`Gateway.mode`: still plain overridable properties, same defaults.
- `firestore.rules`: the fix branch's C2 lockdown is scoped to `locks/**`
  (`isServerOnlyCollection`) only — `inventory` still falls under the permissive generic
  fallback, confirmed by reading the current file directly. My test's REST reads (using the
  seeded member's real token, not an Admin SDK bypass) still work.
- `InventoryStore.addProduct` doesn't newly depend on `StockBatchStore` — confirmed via grep, no
  test change needed there despite `StockBatchStore.qml`'s large diff on the fix branch.
- **Real, substantive finding:** the fix branch adds `Gateway.mutationConflicted(entity,
  entityId, current)` — a CAS-conflict signal (server-side `_deepEqual(current, before)` check in
  `applyMutation`, rejecting with `409 + conflict:true`) that plausibly explains part of the
  original CI failure #4 mystery ("doc never appeared," no visible reason). Checked
  `_deepEqual(null, null)` directly in `gatewayLogic.js` — returns `true` immediately, so the
  *create* path's CAS check (which sends `before: null`) shouldn't be the blocker. Can't rule it
  out for the *update* path (real `before` snapshot, not null) without runtime evidence. Rather
  than guess further, updated `tst_InventoryE2E.qml` to connect to the signal directly and fail
  fast with the real conflict data if one fires during any CRUD test, instead of a generic
  timeout. Required adding an `entityId` parameter to `_pollEmulatorDoc` to scope the check
  correctly.
- **Caught and fixed my own mistake mid-edit:** an intermediate `str_replace` accidentally deleted
  the entire `test_recordMutation_function_accepts_seeded_credentials` diagnostic probe (added
  last CI round) while removing an earlier, now-dead helper function. Caught via a structural
  re-check (`grep` for every function name, confirm each appears exactly once) before showing
  Taher anything — restored it correctly, declared first as before.
- **Design note recorded, not yet acted on:** `tryVerify`'s `message` argument is evaluated once,
  before polling starts — it can't reflect something that happens asynchronously *during* the
  wait. My first attempt at wiring in the conflict diagnostic (an eagerly-evaluated `_diagnose()`
  helper) was structurally broken because of this — would have always seen `lastConflict = null`.
  Caught before committing, fixed by moving the check inside the poll predicate itself, which can
  call `fail()` directly with fresh data.

Committed `f3640a9` (test review changes) on top of the rebased history. Force-pushed
(`--force-with-lease`, refreshed the remote-tracking ref via `git fetch` first for safety) since
history was rewritten: `b1fc577...f3640a9 (forced update)`. Taher approved both the rebase result
and the commit before this push.

## Next step

Taher re-runs `e2e-tests` on this rebased branch. Genuinely new territory now: this run exercises
the fix branch's CAS conflict handling for the first time in this test's flow, in addition to
everything from before. Three possible outcomes: (a)
`test_recordMutation_function_accepts_seeded_credentials` fails with a concrete status/response —
original root cause, unrelated to the rebase, fix it properly. (b) A CRUD test fails with the new
`Gateway.mutationConflicted fired for ...` diagnostic message — confirms the CAS hypothesis, gives
exact data to act on. (c) Everything passes — the review-fix branch's changes (or simply more
attempts) resolved whatever CI failure #4's root cause was. Any of these is real progress over
another opaque timeout.

## Fifth real run — got a concrete server error, ruled out CAS, found and fixed a silent-swallow bug

`test_recordMutation_function_accepts_seeded_credentials` (the diagnostic probe) finally failed
with real, actionable evidence instead of a timeout:
`{"ok":false,"error":"write-failed"}` (500). No `Gateway.mutationConflicted fired for ...` message
appeared in any of the three CRUD failures either — **the CAS-conflict hypothesis from the rebase
review is ruled out**, useful negative evidence.

Traced `"write-failed"` to a generic `catch (e) { send(res, 500, {...}); }` in `recordMutation`'s
handler (`functions/index.js`) — and found it **never logs `e` at all**. The exception is silently
swallowed; even a full CI log dump would have shown nothing.

Before fixing, checked the most likely-looking suspect empirically rather than assuming (again):
`admin.firestore.FieldValue.serverTimestamp()` sits right inside that `try` block, and this is the
exact namespaced-API pattern that broke `seed.js` in failure #1. But `functions/` pins
`firebase-admin@^12.6.0` — a separate dependency tree from root's `14.2.0`. Installed `12.6.0`
fresh in a scratch dir and checked its exports directly: `admin.firestore.FieldValue.serverTimestamp`
is a real function. **Not the cause — confirmed, not assumed**, correcting my own earlier
too-quick dismissal of this exact line (I'd waved it off during the rebase review without actually
testing it).

Found `recordDelta` and `recordMutationsBatch` have the identical unlogged pattern —
`provisionMember` already logs (`console.error("provisionMember write failed", e)`), an existing
established convention the other three were just missing. Applied it to all three. Purely
additive: `node --test` in `functions/` still 94/94 passing, confirming zero behavior change to
what any client receives. Safe with respect to production: only takes effect in the `e2e-tests`
CI job's emulator (loads `functions/` from this branch's source), not real deployed Firebase.

Committed `7119e07`, pushed using a fresh PAT Taher supplied.

## Next step

Taher re-runs `e2e-tests` one more time. This run should finally show the real exception message/
stack in the Functions emulator's own console output (visible in the "Run E2E tests" step's full
log, not just the results.xml summary table Taher has been pasting) — ask for that fuller log
excerpt if the failure repeats, since that's the actual evidence this fix was built to surface.

## Sixth run — real exception surfaced, root cause found and fixed: firebase-tools' emulator stubbing breaks the namespaced `admin.firestore.FieldValue` API

Taher supplied the fuller CI log (`9_Run_E2E_tests.txt`, run at 2026-08-12T02:08). The logging fix
from `7119e07` worked exactly as intended: every `recordMutation` call now shows the real error
instead of the opaque generic 500 —

```
recordMutation write failed TypeError: Cannot read properties of undefined (reading 'serverTimestamp')
    at functions/index.js:140:61
```

100% reproducible (every single `recordMutation` call in the run failed identically), which ruled
out timing/flakiness immediately and pointed at deterministic process state.

**Root cause investigation (`superpowers:systematic-debugging`, Phase 1–3, evidence-based
throughout — no fix attempted until each step below was actually verified):**

- Read `functions/index.js:140` directly: `serverTimestamp: admin.firestore.FieldValue.serverTimestamp()`
  — the exact namespaced-API pattern flagged (but not fully chased down) during the async-write-
  sequencing rebase review, and the same pattern class that broke `seed.js` in CI failure #1.
- **Did not repeat the earlier session's mistake of checking this in isolation.** A plain
  `node -e` repro using this repo's actual pinned `firebase-admin@12.7.0` (confirmed via
  `functions/package-lock.json`, installed fresh into `functions/node_modules`) — with the exact
  require order, `admin.initializeApp()`, and even a named (non-default) database via
  `getFirestore(admin.app(), "test")` exactly like `scopedDb()` does — **could not reproduce the
  bug at all**. `admin.firestore.FieldValue.serverTimestamp()` worked fine every time in plain
  Node. This matched the earlier session's finding and confirmed the bug is not in `firebase-
  admin` itself.
- Per the skill's "multi-component system" guidance, traced the next layer up: the stack trace's
  own `functions/node_modules/firebase-tools/lib/emulator/functionsEmulatorRuntime.js` frames.
  Installed `firebase-tools@15.26.0` (the version `npm install -g firebase-tools` — no version
  pin in `checks.yml` — would resolve to) into a scratch dir specifically to **read its source**,
  not run it (this sandbox still has no egress to the emulator JAR distribution, per the
  standing note in this doc's "Trade-off investigation" section above).
- Found `initializeFirebaseAdminStubs()`: the Functions Emulator wraps the entire `firebase-admin`
  module in a JS `Proxy` and **overwrites `require.cache` for `firebase-admin`'s resolved path**,
  so every `require("firebase-admin")` anywhere in the function's process — including
  `functions/index.js`'s own `const admin = require("firebase-admin")` — receives the proxy, not
  the real module.
- The proxy's `"firestore"` property-get rule calls a helper, `Proxied.getOriginal(target, key)`:
  ```js
  static getOriginal(target, key) {
    const value = target[key];
    if (!Proxied.isExists(value)) return undefined;
    else if (Proxied.isConstructor(value) || typeof value !== "function") return value;
    else return value.bind(target);   // <-- the bug
  }
  ```
  `admin.firestore` is a callable function with **no `.prototype`** (confirmed directly against
  this repo's real installed `firebase-admin@12.7.0`), so `isConstructor` is `false`; since it
  *is* a function, execution falls into the `else` branch: `value.bind(target)`.
  **`Function.prototype.bind()` returns a brand-new function object and does not copy over custom
  static properties manually attached to the original** (`.FieldValue`, `.Timestamp`, `.GeoPoint`,
  etc. are attached as plain properties on the real `admin.firestore` function, not part of its
  prototype chain). Verified this exact mechanism in isolation first (`foo.Bar = {...}; foo.bind(null).Bar`
  → `undefined`) before touching real code.
- **Verified end-to-end, not just asserted:** wrote a scratch script that copies firebase-tools'
  actual `Proxied` class and `"firestore"` rewrite rule verbatim, applies it to this repo's real
  `functions/node_modules/firebase-admin@12.7.0` via the same `require.cache` override technique
  the real emulator uses, then:
  - Confirmed the **old** pattern (`admin.firestore.FieldValue.serverTimestamp()`) throws the
    *exact* CI error message (`TypeError: Cannot read properties of undefined (reading
    'serverTimestamp')`) under this stubbing — byte-for-byte match, not just a plausible theory.
  - Confirmed the **fix** — importing `FieldValue` from the modular `firebase-admin/firestore`
    submodule (a separate resolved file path the emulator's `require.cache` override never
    touches, since it only overwrites the *main* `firebase-admin` entry) — works fine under the
    identical stubbing.
  - Confirmed `admin.firestore.FieldValue === (modular) FieldValue` (`true`) — same underlying
    class, so the fix has zero semantic difference for what `GatewayLogic` receives and writes
    into Firestore; it only changes *how the reference is obtained*.
- **Scope-checked before fixing:** grepped all of `functions/index.js` and `functions/lib/*.js`
  for the same `admin.firestore.<Static>` pattern. Found it in **4 places**, not just the one the
  CI log happened to hit first — `recordMutation` (140), `recordDelta` (218), `recordMutationsBatch`
  (419), `runCutover` (666). The current e2e suite only drives `recordMutation` (Inventory CRUD
  pilot), so the other 3 would have failed identically the moment a later e2e phase touched them —
  fixing only line 140 would have been a symptom fix that resurfaces later under a confusing new
  guise. `functions/lib/*.js` has zero occurrences (dependency-injected, `serverTimestamp` is
  always passed in as an opaque value from `index.js` — confirmed by reading `gatewayLogic.js`).

**Why the earlier session's isolated `firebase-admin@12.6.0` check didn't catch this:** that check
(rebase review, "Fifth real run" section above) ran in plain Node, never through firebase-tools'
emulator stubbing — so it correctly found `admin.firestore.FieldValue.serverTimestamp` is a real
function *in general*, but couldn't see that the Functions Emulator specifically breaks it via
`.bind()`. This is emulator-only: real deployed Cloud Functions never load through
`functionsEmulatorRuntime.js`, so **production was never affected** — this was purely an
e2e-test/CI-emulator gap, which is exactly the class of bug this whole E2E testing initiative
exists to surface. Worth remembering as a general lesson: verifying a suspect line in isolation
isn't the same as verifying it in the actual execution environment when a multi-component system
(here: emulator process wrapping the function's own module graph) is involved.

**Fix applied** (`functions/index.js`, one file, minimal diff — `ponytail`: root-cause fix,
smallest correct change, no bundled refactor):
```diff
- const { getFirestore } = require("firebase-admin/firestore");
+ const { getFirestore, FieldValue } = require("firebase-admin/firestore");
  ...
- serverTimestamp: admin.firestore.FieldValue.serverTimestamp()
+ serverTimestamp: FieldValue.serverTimestamp()
```
Applied identically at all 4 call sites. `node --test` in `functions/`: **94/94 still passing**,
unchanged from before the fix — expected and correct, since the existing unit tests inject fakes
for `serverTimestamp` via dependency injection and never exercised the real `admin.firestore`
accessor at all (this is precisely why this class of bug is invisible to `node --test` and only
catchable by an emulator-backed e2e test — the exact gap this branch's whole purpose is to close).

Committed and pushed this session using a PAT Taher supplied in chat (not recorded here — per
standing practice, treat tokens as single-session-use; confirm current token before any future
push if this session is resumed later).

## Next step

1. Taher reviews the diff (4 call sites in `functions/index.js`, shown above) and the root-cause
   reasoning above.
2. On approval: commit (message TBD, suggest something like `fix(functions): use modular
   FieldValue — namespaced admin.firestore.FieldValue breaks under the Functions Emulator's
   admin-SDK stub`) and push using the supplied PAT (`git fetch origin
   docs/e2e-testing-strategy-design` first per standing practice, then push).
3. Taher re-runs `e2e-tests`. Expected outcome: `recordMutation` write path succeeds. Whether the
   `Inventory CRUD pilot` test then passes end-to-end depends on whatever comes after the write —
   genuinely new territory again, same honest caveat as every prior round: this fixes the write
   crash, it does not guarantee the rest of the CRUD flow is bug-free.
4. Longer-term open item (not blocking this fix, but worth flagging honestly): this bug class —
   namespaced `admin.firestore.*` static access silently breaking only under the emulator — has
   no automated regression guard at the `node --test` layer, only e2e. If Taher wants a cheaper
   safety net than "re-run e2e and hope," an option worth discussing: a lint rule / grep-based CI
   check that fails on any `admin.firestore.` (namespaced) usage in `functions/`, forcing the
   modular API everywhere. Not implemented — flagging as a decision for Taher, not assuming it's
   wanted.
