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

## Seventh run — 5/6 passing, FieldValue fix confirmed working; one new, different failure

The FieldValue fix worked exactly as expected: zero `write failed` exceptions anywhere in this
run's log, across all 13 `recordMutation` invocations. This is a genuinely new failure, not a
recurrence.

**Result:** `test_addProduct_creates_real_emulator_doc` failed — `'product doc never appeared in
the emulator' returned FALSE`. `test_updateProduct_persists_to_emulator` and
`test_deleteProduct_removes_from_emulator` both passed, and both run the *identical* create+poll
sequence internally (`_createProduct()` then `_pollEmulatorDoc(... d !== null ...)`) before doing
their own update/delete — so "create doesn't work" is already ruled out; this is specific to
`test_addProduct`'s own attempt, not the create code path in general.

**Investigation so far (`superpowers:systematic-debugging`, thorough but inconclusive on root
cause — documenting honestly rather than overclaiming):**

- Read the full client write path for a create: `InventoryStore.addProduct` → `_resolveSupplierId`
  (synchronous here — the test's `init()` pre-seeds `SupplierStore.suppliers` by name, so no
  network call) → `nextProductId` → `FirebaseService.mintCounterValue` (2 sequential round trips:
  GET `counters/products`, then a CAS-guarded `:commit` POST, both direct to the Firestore
  emulator on 8080, bypassing Gateway entirely — this is how product IDs are minted) → THEN
  `Gateway.recordMutation("inventory", id, "create", null, doc)` fires (fire-and-forget: enqueues
  to `OutboxStore` and calls `drainNow()`, which sends immediately and does not block) → the
  `addProduct` callback fires synchronously right after `mintCounterValue` resolves, **before**
  the actual `recordMutation` HTTP response has necessarily come back. This is why the test
  separately polls (`_pollEmulatorDoc`) instead of trusting the callback alone — by design, not a
  bug.
- Read `Gateway._send()`, `drainNow()`, `_reschedule()`, and all of `OutboxStore.qml` in full,
  specifically hunting for a shared-mutable-state race given `addProduct` fires **three**
  `Gateway.recordMutation` calls back-to-back in one synchronous tick (inventory create, then
  `TransactionStore.recordCreated`, then `StockBatchStore.addBatch` each fire their own). Found
  nothing: `_send(item)` closes over its own `item`/`xhr` per call (no shared state to race on),
  `OutboxStore._isItemBlocked`/`markInFlight`/`clearInFlight` correctly key by `entity/entityId`
  so the three concurrent sends don't interfere with each other, and `_reschedule()` restarting
  the shared drain timer multiple times in the same tick is cosmetically redundant but not
  incorrect.
- Cross-checked `seed.js`: it seeds `users/`, `tenants/{id}`, `tenants/{id}/members/{uid}`, and
  `tenants/{id}/suppliers/{id}` — **never** `tenants/{id}/inventory` or `counters/products`. So
  `test_addProduct`'s create is the first-ever write to both of those collection paths in this
  emulator instance. Initially treated this as supporting a "first write to a fresh collection is
  slower" theory.
- **That theory doesn't survive contact with the actual numbers, and I want to be honest about
  that rather than quietly dropping it.** Reconstructed the CI log's 13 `recordMutation`
  begin/finish pairs by matching each `Finished ... in Xms` back to its `Beginning execution`
  timestamp. The slowest single call took 1088ms; every other call finished within a similar
  window; all 13 began and ended inside a ~1.75s span. A poll with a fresh 5000ms budget starting
  around when `_createProduct()` returns should comfortably have caught a write that lands ~1
  second later — there's roughly a 4x margin, not a photo finish. I don't think "it just barely
  ran out of time" is well-supported by these numbers, even though it was my first instinct.
  Flagging this explicitly because guessing past evidence that doesn't fit is exactly the mistake
  this project has already paid for once (the FieldValue investigation's earlier isolated-check
  miss).
- Considered and ruled out (each checked, not assumed): a `FieldValue`-style env/database
  mismatch between what `Gateway._send()` sends (`env: FirebaseService.environment`) and what
  `_pollEmulatorDoc` hardcodes (`databases/(default)`) — ruled out because if this were wrong it
  would break *every* create's poll identically, not just the first, and update/delete's own
  embedded create-polls (identical code) passed. A stuck `OutboxStore._inFlightKeys` entry —
  ruled out because it would only affect subsequent client-side sends for that *same* entityId,
  and every test mints a fresh id, so it can't explain the poll itself failing to observe a doc
  that the server already wrote.
- **What I could not rule out, and is the most likely real gap:** `_pollEmulatorDoc`'s `fire()`
  collapsed *every* non-200 response — a permissions denial, a 500, a malformed-request 400, as
  well as a genuine "not created yet" 404 — into the identical `latest = null`. The test could not
  distinguish "the doc isn't there yet" from "the read is failing for some other reason" or from
  "there's a real problem with what the server actually did with the create." Given the timing
  data doesn't cleanly support a pure timeout explanation, I don't want to guess further blind —
  this is the textbook case for adding diagnostic instrumentation and getting one more real data
  point, per `systematic-debugging`'s evidence-gathering step, rather than picking a fix I can't
  actually explain.

**Change made — diagnostics only, zero behavior change:** `tests/e2e/tst_InventoryE2E.qml`,
`_pollEmulatorDoc()`. Now tracks and logs (via `console.warn`, visible in the raw CI log) the
actual HTTP status and response body on every status change during polling, plus attempt count and
elapsed time. Also appends `entityId`/`docPath` to `tryVerify`'s static failure message (previously
a bare "product doc never appeared in the emulator" didn't even say which product/path). Same
predicate, same timeout, same pass/fail outcome either way — this only makes the next run's log
tell us what actually happened instead of leaving us to reconstruct it after the fact from
Cloud-Functions-side logs that don't cover the Firestore-emulator side of the conversation at all.

**Deliberately did NOT also bump the 5000ms timeout.** Given the timing math above doesn't support
"ran out of time" as the explanation in this run, guessing a bigger number wouldn't be a fix I
could explain — it might coincidentally make the symptom go away without telling us anything, or
mask a real bug that would resurface later in a more confusing form. Flagging this as a deliberate
choice, not an oversight, and open to being told to just bump it anyway if Taher would rather trade
rigor for a faster resolution — but that should be an explicit call, not something I do silently.

**Not committed or pushed.** Diagnostics-only change, low risk, but still a new commit — same
standing rule applies.

## Next step

1. Taher reviews the diagnostic diff and the reasoning above (especially the part where the
   timing evidence undercut my own first theory — flagging that pattern-matching-then-checking-
   the-math is exactly the discipline this project has needed after the FieldValue miss).
2. On approval: commit, push, re-run `e2e-tests`.
3. Expected outcomes: (a) it now passes — in which case the failure was likely transient/flaky,
   and the enhanced logging plus richer failure message stay in the file as a permanent
   improvement regardless; or (b) it fails again — in which case the `console.warn` lines in the
   raw CI log finally tell us the actual status code and response body the poll was seeing, which
   should turn this from a guessing exercise into a concrete next bug to fix.
4. Once this is resolved, the diagnostic comment above says to consider stripping the extra
   logging back out — worth Taher's explicit call at that point (it's genuinely useful permanent
   diagnostic value vs. noise, a judgment call, not obviously one or the other).

## New session (2026-08-13) — fresh clone, checked out this branch per Taher's instruction

Per standing session rules: cloned `InventoryManagerUI` fresh into the sandbox
(`/home/claude/work/InventoryManagerUI`), fetched and checked out the existing
`docs/e2e-testing-strategy-design` branch (Taher named it explicitly this session — did not
create a new branch on top of it, since the ask was to debug and fix on this branch, matching
every prior round's pattern of committing directly here). Loaded `superpowers:systematic-debugging`
per Taher's explicit invocation before doing anything else.

## Eighth run (the diagnostic commit's first real test) — the diagnostics never reached the CI log; found out why, and it's not the addProduct bug

Taher supplied the raw CI log for the diagnostic commit's (`6053419`) first real run (job "E2E
Tests (Inventory CRUD)", run `31584114852`, PR #43). Read it in full per Phase 1.

**Confirmed, good news first:** the `FieldValue` fix from the Sixth run is still solid — zero
`write failed` exceptions anywhere in this run, across all 13 `recordMutation` invocations. The
Seventh run's pattern also repeats a third time: `test_addProduct_creates_real_emulator_doc` is
the only failure (`'product doc never appeared in the emulator (entityId=PRD-001,
docPath=tenants/e2e-tenant/inventory/PRD-001)' returned FALSE`);
`test_updateProduct_persists_to_emulator`, `test_deleteProduct_removes_from_emulator`, and the
`test_recordMutation_function_accepts_seeded_credentials` diagnostic probe all passed.

**The actual finding this round, and it's not what the diagnostic commit was built to surface:**
the `console.warn("[_pollEmulatorDoc]", ...)` lines added last round — the whole point of that
commit — **do not appear anywhere in this log.** Neither does any other qmltestrunner console
output: no `********* Start testing of InventoryE2E *********` banner, no per-test `PASS`/`FAIL`
lines, nothing between `seed.js: wrote .../.fixture.json` and `Script exited unsuccessfully (code
1)` except the Functions emulator's own `Beginning execution`/`Finished` lines. Verified this
isn't a copy/paste artifact — grepped the raw file directly (`grep -a`, byte-for-byte, no ANSI
codes or hidden text swallowing it) and it's genuinely absent, not just filtered out by my search
terms.

Checked why, rather than assuming a fluke, since this is exactly the pattern the debugging skill
warns about ("no root cause" is usually incomplete investigation): confirmed via Qt's own
documentation (`doc.qt.io/qt-6/qtest-overview.html`) that <cite index="1-1">the `-o filename,format` option writes output to the specified file, and if that first version of `-o` is used, no other output goes to standard output — the special filename `-` has to be used to explicitly also log to stdout, and the option can be repeated once to get both a file and stdout at the same time</cite>. The
`e2e-tests` job's `Run E2E tests` step invokes qmltestrunner with exactly one `-o
results.xml,junitxml` and nothing else. Per that documented behavior, **every bit of test
output — the standard PASS/FAIL banner AND any `console.warn`/`console.log` calls the test itself
makes — goes only into `results.xml`, never to stdout.** That's the whole gap: the diagnostic
commit worked exactly as designed, the data just landed somewhere this session's raw-log-reading
workflow can't see.

**This is a real, verifiable, low-risk gap — but it's not the root cause of the CRUD failure
itself, and I want to be direct about that distinction rather than letting a fix here read as
"found and fixed the bug."** It's the root cause of *why the last three CI rounds of `console.warn`
instrumentation have all felt like shouting into a void* — a separate, real problem, worth fixing
regardless of what the underlying addProduct issue turns out to be.

**Fix applied** (`.github/workflows/checks.yml`, `e2e-tests` job, one line):
```diff
-  "node test/e2e/seed.js && qmltestrunner -input tests/e2e -platform offscreen -o results.xml,junitxml"
+  "node test/e2e/seed.js && qmltestrunner -input tests/e2e -platform offscreen -o results.xml,junitxml -o -,txt"
```
Second `-o -,txt` target streams plain-text output (banner + PASS/FAIL + every `console.warn`) to
stdout *in addition to* the existing `results.xml`/junitxml (still consumed unchanged by
`dorny/test-reporter` and the `upload-artifact` step) — the documented "repeat `-o` once, second
one targets `-` for stdout" pattern, not a guess. YAML-validated (`pyyaml`).

**Deliberately NOT touched:** the `qml-tests` job (`checks.yml` line 29,
`qmltestrunner -input tests -platform offscreen -o results.xml,junitxml`) has the exact same
single-`-o` gap. Left alone — that job runs the *entire* `tests/` directory (far more test files
than `tests/e2e/`), so mirroring this fix there would meaningfully bloat that job's log on every
PR, and it isn't blocking anything today (no one's added `console.warn` diagnostics there). Flagging
it as a real, related, and easy-to-fix gap if Taher wants it, not silently expanding scope into a
job this branch didn't create and doesn't need for its own purpose.

**Faster alternative worth Taher knowing about, not just the next-CI-run path:** `results.xml` for
*this exact run* was already uploaded — `actions/upload-artifact` succeeded before the job failed
(`if: always()`), artifact ID `9136403898`, download URL was in the log:
`https://github.com/lkdigitalworks-53/InventoryManagerUI/actions/runs/31584114852/artifacts/9136403898`.
Junitxml output includes each test's captured console messages as part of its own result data — so
that artifact almost certainly already contains the exact `[_pollEmulatorDoc]` status/body lines
this whole diagnostic round was built to produce, with zero need to wait for another CI run. Told
Taher this is the faster path if he wants the actual answer sooner; the `-o -,txt` fix guarantees
future runs show it directly in the log regardless.

**Own hypothesis, held loosely and explicitly labeled as unconfirmed:** re-read
`FirebaseService.mintCounterValue` and `Gateway.qml`'s drain/send path while doing this pass.
`test_addProduct` is the *first-ever* call to `InventoryStore.addProduct` in the whole suite
(`test_recordMutation_function_accepts_seeded_credentials`'s diagnostic call bypasses minting
entirely — hardcoded `entityId: "diag-" + Date.now()`), making it the first-ever mint of
`counters/products` and — per this run's own timing — the recordMutation calls clustered right
after it show ~950–1070ms durations for the first 3 vs. ~65–110ms for the rest, a clear first-call
cold-start signature (consistent with Node/V8 JIT warm-up or Firestore-client connection setup on
a function's first real invocation, not something `node --test`'s fakes ever exercise). This is a
plausible contributor, not a proven one — I have not traced it to a concrete number that exceeds
`_pollEmulatorDoc`'s 5000ms budget, and the Seventh run's own timing math (also inconclusive) is a
reminder not to trust a plausible story without the actual numbers. The `results.xml` artifact
(or a future run with `-o -,txt`) is what actually settles this, not more source-reading.

**Committed and pushed** (`be61228`) — see the log excerpt below; this restored visibility, as
predicted, without touching the CRUD test failure itself.

## Ninth run — the `-o -,txt` fix worked; real diagnostic data changed the diagnosis entirely

Taher supplied both the raw CI log **and** `results.xml` for the very next `e2e-tests` run
(2026-08-13, run started 02:08:59). Confirmed the previous fix worked exactly as intended: the raw
log now shows the full `********* Start testing of qmltestrunner *********` banner, every
`PASS`/`FAIL!` line, and every `console.warn`/`QWARN` line, in real time with millisecond
timestamps — no artifact download needed. `results.xml` independently confirms the same content
via each testcase's `<system-err>`. Cross-checked the two against each other; they agree.

**First correction to something I got wrong last round:** I'd assumed
`test_recordMutation_function_accepts_seeded_credentials` runs first, since it's declared first in
the file and its own comment says so ("declared first so it fails fast"). The raw log's own
per-line test-context annotations prove that's false — **actual execution order this run was
`test_addProduct` → `test_deleteProduct` → `test_recordMutation_function_accepts_seeded_credentials`
→ `test_updateProduct`** — alphabetical, not declaration order. QtQuickTest does not preserve
source order for QML-defined test functions the way classic moc'd C++ QTestLib does. This is a
real, previously-unexamined assumption behind a chunk of the earlier investigation (including my
own read of the Eighth run) — the "fail-fast probe" never actually ran fail-fast, in any of the
prior CI rounds either, since nothing changed this run's ordering behavior. Worth remembering
going forward: don't infer QML TestCase execution order from source position.

**The actual root cause, now backed by hard numbers, not a hypothesis:**
```
02:09:01.611  qmltestrunner starts
02:09:02.143  test_addProduct's poll for PRD-001 starts (attempt 1, 404 — expected, still early)
02:09:07.195  test_addProduct FAILS — 5000ms poll budget exhausted, PRD-001 still 404
02:09:08.820  Functions emulator logs its FIRST "Beginning execution of recordMutation" — ever,
              this whole run — 6.68s after the poll started, 1.62s AFTER the test had already failed
```
Zero `recordMutation` invocations appear in the Functions emulator log anywhere before 08.820.
`OutboxStore.enqueue()`/`Gateway.drainNow()` run synchronously and client-side (confirmed by
re-reading `Gateway.qml`) — the client dispatches its POST within ~500ms of the test starting
(matches the `ActivityLog`/`Firestore` QWARN lines clustered around 02:09:02.08–02.14). So the
request left the client almost immediately; **the Cloud Functions Emulator itself didn't even log
receiving it for 6.68 seconds.** That gap is on the server side, not the client.

This matches `firebase-tools`' well-documented Functions Emulator behavior: function *definitions*
are statically registered at emulator boot ("Loaded functions definitions from source", visible
much earlier in the log), but each function's actual Node worker process is spun up lazily, on
its first real invocation — a genuine cold start (new child process, module resolution,
`firebase-admin` init) that can run several seconds, paid exactly once per function per emulator
session. Every `recordMutation` call after that first one in this run completed in well under 1s
(confirmed via the Functions log's own `Finished ... in Nms` lines) — consistent with a warm
worker handling everything from the second call onward. This is *not* Firestore-doc-read latency,
*not* a `mintCounterValue`/counter cold-start issue (that hypothesis from the Eighth run doesn't
survive this data — the delay is entirely server-side, before the write is even attempted), and
*not* the `QSettings` warnings (see gaps below — those don't throw, request dispatch happened on
schedule regardless of them).

Whichever CRUD test happens to run first (by this alphabetical ordering, always
`test_addProduct`) is the one that pays this cold-start cost inside its own 5000ms poll budget —
and loses. Every other test runs after the worker's already warm, which is exactly why
`test_updateProduct`/`test_deleteProduct` have passed identically across every single prior CI
round: not because create genuinely works and addProduct is special, but because they're
structurally guaranteed to run *after* whichever test the alphabet puts first.

**Fix applied** (`tests/e2e/tst_InventoryE2E.qml`):
- Added `initTestCase()` — runs exactly once, unconditionally, before any `test_` function
  (unlike declared order, this ordering guarantee is real and documented Qt Test behavior). Fires
  one throwaway `recordMutation` POST (bypassing Gateway/OutboxStore, identical shape to the
  existing diagnostic probe) with a 15000ms timeout — generous on purpose, since it represents a
  one-time emulator warm-up cost, not per-call latency the real tests should ever need to budget
  for.
- Extracted the raw-POST logic (`XMLHttpRequest` + headers + payload + `tryVerify`) that
  `test_recordMutation_function_accepts_seeded_credentials` already had into a shared
  `_postRecordMutationDirect(entityId, timeoutMs, timeoutMessage)` helper, used by both
  `initTestCase()` and the now-slimmed-down diagnostic test — avoided duplicating the XHR
  boilerplate a second time.
- Corrected `test_recordMutation_function_accepts_seeded_credentials`'s comment (it no longer
  claims to run first/fail-fast — it doesn't, and per the ordering finding above, never did).
  Kept the test itself: still a fast, useful credentials/payload-shape regression check, now
  reliably fast since `initTestCase()` warms the worker before it runs.
- Left every CRUD test's own `_pollEmulatorDoc`/`tryVerify` timeout at 5000ms, unchanged.
  Considered and rejected bumping them as a "belt and suspenders" safety margin: that would mask
  a real regression behind a longer wait rather than fix anything, and 5000ms is a fine budget for
  *warm* recordMutation + Firestore round trips (confirmed by this exact run: PRD-002/PRD-003 both
  completed in well under that once warm). If `initTestCase()`'s warm-up itself starts flaking or
  needs more margin, that's the number to revisit, not the individual tests.
- Did not clean up the throwaway `warmup-*` inventory doc `initTestCase()` creates. Harmless to
  all 4 CRUD tests (none assert on collection counts or iterate all inventory docs) — a
  deliberate, disclosed minimal-diff choice, not an oversight.

**Not yet committed — reviewing with Taher first, given this is a real behavior change (moves
where a cost is paid, not just a logging flag) rather than the low-risk CI-only edit from the
Eighth run.**

## Gaps found this round — documented per Taher's instruction, deliberately NOT fixed now

Taher's explicit call: fix the actual CRUD bug now, document everything else, address separately
later. Four items, none touched:

1. **`QSettings` never initializes under `qmltestrunner`** — `AuthStore.qml:62` and
   `OutboxStore.qml:54` both warn on every run: `Failed to initialize QSettings instance. Status
   code is: 1` / `The following application identifiers have not been set: QList("organizationName",
   "organizationDomain")`. Root cause (read, not just guessed): `QCoreApplication::setOrganizationName`
   /`setOrganizationDomain` are normally set in the real app's `main.cpp`, which `qmltestrunner` —
   a generic Qt-provided binary — never runs, so `Settings { category: ... }` has nowhere to
   resolve a storage path under it. Confirmed this is **not** the E2E bug's cause: the warning is
   logged and execution continues immediately in the same run (recordMutation dispatch happened on
   its normal client-side schedule regardless), so property writes to a mis-initialized `Settings`
   object appear to no-op rather than throw. Real gap though — `OutboxStore`'s durability-across-relaunch
   guarantee (the entire reason it persists to `Settings` at all) is silently untested by this
   whole E2E suite, every single run. Worth a real fix (e.g. set org identifiers in a
   `qmltestrunner`-only init path, or accept this is permanently untestable under qmltestrunner and
   document that limitation explicitly) — not attempted here.
2. **`ActivityLog` writes are rejected by Firestore rules in this test's context** — every run,
   confirmed via both logs: a `runQuery` POST and a `PATCH`/`PUT` to `activity_log/{id}` both come
   back `403 PERMISSION_DENIED, "No matching allow statements"`. `ActivityLog` writes directly to
   Firestore client-side (bypassing `Gateway`/Cloud Functions entirely, unlike every other store) —
   the E2E fixture's seeded credentials evidently don't satisfy whatever `firestore.rules` requires
   for that collection. Two live questions worth Taher's own read on `firestore.rules`, not mine to
   guess: (a) is this rules-vs-fixture mismatch specific to the E2E fixture, or would a real
   Owner/Admin/Manager/Staff account hit the identical 403 in production? (b) if it's fixture-only,
   what's actually missing from `seed.js`'s fixture generation? Not investigated further — flagged,
   not fixed, and I don't have enough evidence yet to guess which.
3. **`qml-tests` job has the identical single-`-o` gap** (`checks.yml` line 29) — flagged in the
   Eighth run's entry above, still open. Same fix (`-o -,txt`) would apply; deliberately not
   mirrored there without Taher's go-ahead, given it's a much larger test surface (`tests/` vs.
   `tests/e2e/`) and would meaningfully bloat that job's log on every PR.
4. **QtQuickTest doesn't preserve declared test-function order** — not a bug exactly, but a real
   gap in this file's own design assumptions (see the Ninth-run findings above): the
   `test_recordMutation_function_accepts_seeded_credentials` comment relied on declaration order
   for "fail fast" behavior that never actually held. Fixed the misleading comment as part of this
   round's edit; did not investigate whether QtQuickTest offers any actual ordering control
   (`-functions` flag, naming convention, etc.) if guaranteed ordering is ever wanted for a future
   test file — noting it here as a "how QtQuickTest actually behaves" fact worth remembering
   project-wide, not just patching locally.

## Next step (superseded — see Tenth run below)

**Committed and pushed** (`e511cd7`). Verification came back via the next CI run — see below.

## Tenth run — the initTestCase() warm-up was tested and disproven; found a real, unlogged candidate instead of guessing again

Taher supplied the raw log and `results.xml` for the very next run after `e511cd7` (2026-08-13,
run started 11:07:29). Same failure, same message, same entityId (`PRD-001`) — but this time with
`initTestCase()` in the picture, and its own timing is the whole story:

```
InventoryE2E::initTestCase          PASS   time=1.215s  (includes the warm-up's own 349ms round trip)
InventoryE2E::test_addProduct_...   FAIL!  time=5.636s  — same "doc never appeared" message
```

**The warm-up worked exactly as designed and still didn't help.** Its own `recordMutation` call
completed in 349ms (`Beginning execution` → `Finished` in the Functions log) — the emulator is
provably warm by the time `test_addProduct` starts. And it still failed, identically. That's a
clean disproof of the Ninth run's hypothesis, not an ambiguous result — worth stating plainly
rather than quietly moving past it: **the Functions-Emulator-cold-start theory was wrong.** Not
"insufficient margin" — wrong. Recording that so it doesn't get re-tried later under a different
name.

Re-measured the actual gap with the emulator now confirmed warm:
```
poll for PRD-001 starts:                     11:07:31.529
test_addProduct FAILs (5000ms budget spent):  11:07:36.573
first NEW "Beginning execution" (PRD-001's own create), 56ms AFTER the test had already failed:
                                               11:07:36.629
```
Same ~5.1s gap as the Eighth/Ninth runs, structurally identical to before, just with the cold-start
explanation now closed off. Ruled out three more things by re-reading code rather than guessing,
each cheap enough to check before reaching for instrumentation again:
- **Not `Gateway.mode`** — `property string mode: "gateway"` is the literal default, not bound to
  anything that could be false at this point; `init()` also sets it explicitly every time.
- **Not a global JS/engine stall** — `_pollEmulatorDoc`'s own poll timer keeps firing every ~50ms
  throughout the whole 5s gap (visible in the attempt-count progression), so the event loop is
  demonstrably alive and processing timers the entire time. Whatever's blocked is scoped to this
  one call, not the engine.
- **Not slow singleton construction** — traced the full synchronous call chain from
  `InventoryStore.addProduct()` (`Gateway.recordMutation()` on line 423, then
  `TransactionStore.recordCreated()`, `StockBatchStore.addBatch()`, then the test's own `callback(true, id)`
  that flips `_createProduct()`'s `done` flag) — all of it, including everything AFTER the
  `Gateway.recordMutation()` call, provably completes within ~30ms (the poll's attempt 1 fires at
  32ms elapsed). If `OutboxStore`'s first-ever singleton construction (triggered by this exact
  call, `Settings` init failure and all) took anywhere near 5s, that chain couldn't have finished
  in 30ms. It's fast, whatever else it's doing.

**Found one real, specific, currently-unlogged candidate instead of a fourth guess.**
`Gateway._send()` (`Gateway.qml`, right above the `xhr.send()` call) has this guard:
```js
if (!AuthStore.idToken || AuthStore.idToken.length === 0) {
    OutboxStore.clearInFlight(item)
    return
}
```
If `AuthStore.idToken` is empty at the exact moment this runs, `_send()` returns **without
sending, without logging anything, and without calling `_reschedule()`** — the item stays queued
and unblocked, but nothing schedules a retry. It would only go out whenever some UNRELATED later
`drainNow()` call (triggered by a different `recordMutation()` elsewhere) happens to drain it. That
is *exactly* the shape of what's been observed twice now: the client-side chain looks prompt, and
the item eventually appears bundled in with the very next test's own create. This is a real
candidate with a mechanism that fits the evidence, not a vibe — but I don't have a way to confirm
`AuthStore.idToken`'s actual value at that instant without either running the app (not available
in this sandbox) or logging it, and I'm not shipping a third unverified fix after the second one
just failed. Chose to log instead.

**Change made — diagnostic only, explicitly no behavior change:** added one `console.warn` at the
top of `Gateway._send()` (`qml/model/Gateway.qml`) logging `entity`, `entityId`,
`AuthStore.idToken`'s length, and `Date.now()` — on every single call, both branches. If the next
run shows `idTokenLength 0` on `_send`'s first-ever call, this guard is confirmed as the cause and
the actual fix (make `_send()` call `_reschedule()` before it returns early, so a token that
arrives later actually gets retried instead of waiting on an unrelated trigger — needs its own
proper look, not decided yet) becomes a targeted, evidence-backed change instead of a guess. If
`idTokenLength` is already correct at that point, this is ruled out too, and the next candidate is
network-transport-layer queueing (Qt's connection-pool/concurrency limits under the burst of
near-simultaneous XHR calls `addProduct()` fires — polling GETs, `ActivityLog`'s three failed
calls, and three `recordMutation` POSTs, all within milliseconds of each other) — flagged as the
next thing to instrument if this doesn't pan out, not investigated further this round.

Left `initTestCase()`'s warm-up in place — it's not wrong, it's just not sufficient on its own. It
still guards a real, separately-measured risk (the emulator's cold-start latency is real, just not
what's causing THIS failure), and removing it would lose that coverage for no reason.

**Committed and pushed** (`24e708a`). Verification came back the next run — see below.

## Eleventh run — confirmed root cause, real fix implemented, diagnostic removed

Taher supplied the log + `results.xml` for the run right after `24e708a` (2026-08-14, run started
01:47:49). The `idTokenLength` diagnostic answered the question directly:

```
idTokenLength 0    atMs 1786672069019   (first _send() call, entity=inventory)
idTokenLength 0    atMs 1786672069278   (retry, 259ms later)
idTokenLength 0    atMs 1786672069531   (retry, 253ms later)
... repeats every ~250-255ms ...
idTokenLength 0    atMs 1786672074095   (last 0 — still failing after ~5.08s)
idTokenLength 469  atMs 1786672074148   (53ms later — a real token, finally)
```
**Confirmed: `AuthStore.idToken` was empty on every single `_send()` call for ~5.1 seconds, then
became valid (469 chars, a real JWT-length token) the instant the next test's `init()` re-ran.**
Not partial evidence this time — direct measurement of the exact variable the guard checks.

**Also worth correcting from the Tenth-run writeup:** I'd written that `_send()`'s early return
happens "without calling `_reschedule()`" — true of `_send()` in isolation, but `drainNow()` (which
calls `_send()`) calls `_reschedule()` unconditionally right after its loop, regardless of what any
individual `_send()` call did. The 250ms-interval retries visible above are that mechanism working
exactly as designed — the item wasn't stuck with zero retries, it was retried roughly 20 times over
5.1 seconds, and every single retry failed for the same reason. Worth being precise about: the
retry *scheduling* was never the problem.

**Root cause, fully traced through the code, not just observed:**
1. `AuthService` (`qml/model/AuthService.qml`, `pragma Singleton`) is never referenced anywhere in
   `tst_InventoryE2E.qml` or in its own `init()`. Its actual first reference in the whole run is
   inside `Gateway.drainNow()`: `if (typeof AuthService !== "undefined" && AuthService)
   AuthService.ensureFreshToken()`.
2. Referencing a QML singleton for the first time triggers its `Component.onCompleted`. For
   `AuthService` that's `{ init() }`, which calls `AuthStore.loadSession()`.
3. `AuthStore.loadSession()` (`qml/model/AuthStore.qml:86`) calls `clear()` **unconditionally, first**
   — wiping `idToken`, `tenantId`, and everything else back to `""` — *before* checking whether
   `_settings.sessionJson` has anything to restore. On a fresh emulator run there's nothing to
   restore, so `clear()` is the only thing that happens.
4. Sequence for `test_addProduct` specifically: its own `init()` runs first and sets
   `AuthStore.idToken = fixture.idToken` — correctly, at that moment. Then the test body runs,
   reaches `Gateway.recordMutation()` for the first time ever, which calls `drainNow()`, which
   references `AuthService` for the first time ever, which fires the construction-time `clear()` —
   **wiping the idToken `init()` had just set, moments before `_send()`'s own guard checks it.**
   Every test after this one is unaffected: `AuthService` is already constructed by then, so
   referencing it is a normal no-op, and each test's own `init()` sets `idToken` *after* that
   one-time construction has already happened and already cleared whatever was there before.

This is why `test_addProduct` — specifically whichever test the alphabet happens to run first — has
failed identically across every CI round since the Seventh run, while every other CRUD test has
passed: not cold emulator, not slow singleton construction, not a network-layer delay. A one-time,
order-dependent side effect of lazily constructing `AuthService`, landing exactly once, exactly
between one test's `init()` setting real values and that same test's first `Gateway.recordMutation()`
call reading them back.

**Fix implemented** (`tests/e2e/tst_InventoryE2E.qml`, `initTestCase()`): added
`AuthService.ensureFreshToken()` as the first line — a real, existing, already-safe method
(no-ops when `AuthStore.isAuthenticated` is false, which it is at that point) — called purely to
force `AuthService`'s one-time construction-and-wipe to happen *before* any test's `init()` sets
real values, not after. Once `AuthService` exists, referencing it again from `drainNow()` is an
ordinary no-op, so every subsequent test (and this test's own real `init()` call, moments later)
is unaffected.

**Diagnostic removed** (`qml/model/Gateway.qml`): the `console.warn` added to `_send()` last round
did its job — it's gone now. Worth flagging explicitly why removal (not "leave it, it's harmless")
was the right call this time, unlike `_pollEmulatorDoc`'s diagnostic which stayed: `Gateway._send()`
is production code that runs on *every* real mutation the actual app ever makes, not just this test
file. Leaving a `console.warn` there would mean every real user action logs to console in production
— a real regression, not harmless leftover instrumentation.

**Why this is very likely test-only, not a latent production bug** (inference, not fully traced):
the real app's normal UI/bootstrap flow almost certainly references `AuthService` very early — some
screen has to check login state on launch — long before any real login sets `AuthStore.idToken`. So
in production, `AuthService`'s construction-time `clear()` lands on already-empty state, same as it
now does here. This test is the exception because it pokes `AuthStore` directly, skipping the app's
normal bootstrap sequence entirely, so it's the one place that needed to force the ordering
explicitly. **Have not traced this end-to-end against `main.qml`'s actual bootstrap sequence to
confirm** — stating the inference plainly rather than dressing it up as verified. Worth Taher's own
five-minute check of `main.qml`/whatever screen first touches auth state, at his convenience — not
blocking this fix, since the fix is correct regardless of whether production is also exposed.

**Related design gap, worth a note, not a rewrite:** `Gateway.drainNow()`'s pattern of referencing
a heavier singleton with real side effects (`AuthService`) lazily, "just in time," inside a hot path
is inherently a little fragile — this exact class of bug (a singleton's first-reference side effect
racing against code that assumes state already set) could in principle recur anywhere else that
touches `AuthService` for the first time at an inconvenient moment. Not fixing the underlying
pattern now — no evidence it's actually biting production, and forcing construction order in one
test file is a minimal, targeted, low-risk fix for the actual failure. Flagging the pattern itself
as worth remembering, same spirit as the QtQuickTest-ordering gap from the Ninth run.

**Verification status, stated plainly:** this fix is evidence-driven and traced end-to-end through
the actual code, with direct measurement (`idTokenLength`) confirming the mechanism — the strongest
basis of any fix this branch has shipped so far. It is still not build/run-verified in this sandbox.
A green `e2e-tests` run is what actually confirms it.

**Confirmed by Taher: `e2e-tests` passed.** `test_addProduct_creates_real_emulator_doc` — and by
extension the `AuthService`-construction-ordering fix from the Eleventh run — is closed. This
branch's original E2E goal (Phase 1 pilot: real CRUD against the real Local Emulator Suite,
service-level, no UI) is now actually green, eleven rounds after the first real CI attempt.

## Twelfth run — `qml-tests` and `firestore-rules-tests` both failing, two unrelated root causes, both confirmed via documented tool behavior rather than guessed

Taher supplied `0_Firestore_Rules_Tests.txt` and `2_QML_Tests.txt` (2026-08-14). Two different
jobs, two different failures, no relation to each other or to the E2E bug just closed.

### `firestore-rules-tests`: exit code 1, "No tests found," zero console output

The job's own command: `firebase emulators:exec --only firestore "node --test
--test-reporter=junit --test-reporter-destination=results.xml test/"`. Confirmed against Node's
own documentation (`nodejs.org/docs/latest-v24.x/api/test.html`) rather than assumed: <cite>"If a
directory named test is encountered, the test runner will search it recursively for all .js, .cjs,
and .mjs files. All of these files are treated as test files, and do not need to match the
specific naming convention."</cite> `test/` (the literal directory name) contains both
`test/firestore.rules.test.js` (the intended target) and `test/e2e/seed.js` — and per that
documented rule, **both get swept in and executed as test files**, regardless of `seed.js` never
being written as one.

`seed.js`'s own header comment confirms it needs Firestore *and* Auth *and* Functions emulators
(`getAuth()` calls to mint a real emulator-signed ID token) — this job starts `--only firestore`
alone. Run this way, `seed.js` fails immediately trying to reach an Auth emulator that was never
started, and since Node executes matching files as regular scripts, a crashing "test file" takes
the whole `node --test` invocation down with it — consistent with every observed symptom: exit
code 1, an empty/near-empty (993 byte) `results.xml`, and no console output in the raw log (same
`--test-reporter-destination` redirect-away-from-stdout behavior already seen twice with
qmltestrunner's `-o`, now confirmed as a pattern in this repo's Node test setup too).

**Fix:** changed the job to target `test/firestore.rules.test.js` explicitly instead of the whole
`test/` directory (`.github/workflows/checks.yml`). Also updated `firestore.rules.test.js`'s own
header comment, which had documented the old (buggy) `"node --test test/"` invocation as the
correct way to run it locally — left uncorrected, that comment would have silently reintroduced
this exact bug the next time someone copied it back into the workflow.

### `qml-tests`: `InventoryE2E::initTestCase` — `'timed out reading .fixture.json' returned FALSE`

The `qml-tests` job runs `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml`
— recursively scanning the entire `tests/` directory. `tst_InventoryE2E.qml` lived at
`tests/e2e/tst_InventoryE2E.qml` — physically *inside* that tree, even though the original design
spec (`docs/superpowers/specs/2026-08-09-e2e-testing-phase1-design.md` §7) explicitly called it
out as "a new, **separate** directory from `tests/`." That separation was never actually enforced
at the filesystem level, just intended — `qml-tests` doesn't start any Firebase emulator or run
`seed.js`, so `test/e2e/.fixture.json` never exists when it runs `InventoryE2E`'s `initTestCase()`,
which calls `_loadFixture()`, which times out reading a file that was never created. This is the
inverse problem of the Firestore-rules one above: there, a script that shouldn't be a test got
swept in; here, a test that shouldn't run in this job got swept in — same underlying cause
(a too-broad directory scan with no exclude mechanism), different direction.

Checked for a `qmltestrunner` flag to exclude a subdirectory from `-input` before reaching for a
structural fix — none documented (`doc.qt.io/qt-6/qtest-overview.html`, various Qt Forum threads);
"Takes a filename or directory of files to run," no exclude option. Considered generating an
explicit file list via shell globbing instead of a directory path, but couldn't confirm
`qmltestrunner` accepts multiple positional/`-input` file arguments reliably from documentation
alone, and this sandbox can't run qmltestrunner to test the syntax directly — guessing at
unverified CLI syntax for a script Taher can't easily catch a mistake in before it ships felt like
the wrong trade-off versus a structural change I could verify completely with tools already
available (`git mv`, path arithmetic).

**Fix:** moved `tst_InventoryE2E.qml` from `tests/e2e/` to `test/e2e/` — physically alongside
`seed.js`, and genuinely outside the `tests/` tree the `qml-tests` job scans, not just
conceptually separate. Verified safe before moving, not assumed: both `Qt.resolvedUrl("../../qml/model")`-style
relative references in the file resolve identically from the new location, since `tests/e2e/` and
`test/e2e/` are the same depth (2 segments) from the repo root — `fixtureUrl`'s
`../../test/e2e/.fixture.json` and the `import "../../qml/model"` line needed no changes at all.
Updated the `e2e-tests` job's `-input tests/e2e` → `-input test/e2e` to match, plus the two stale
in-file comments (in `seed.js` and the test file itself) that documented the old path — left
uncorrected, either one could have misled a future change back into the same layout.

**Not touched, flagged only:** `functions-tests` (`working-directory: functions`, bare `node --test`
with no explicit path) has the same directory-name-triggers-recursive-sweep mechanism available to
it — `functions/test/fixtures/*.js` sit inside a directory named `test` too. Didn't investigate or
change this: Taher hasn't reported that job failing, and those fixture files are plain data
exports with no side effects (unlike `seed.js`), so a swept-in "test file" that does nothing and
exits 0 is registered as trivially passing, not a crash. Worth knowing the mechanism could bite
here too if a future fixture file ever gains a side effect on load — not changing anything
speculatively.

**Verification status:** both fixes are grounded in documented tool behavior (Node's own docs,
directly quoted; `qmltestrunner`'s documented lack of an exclude flag) and verified-safe path
arithmetic, not guesses. Neither is build/run-verified in this sandbox — same standing limitation
as every fix this session. Next CI run of both jobs is what actually confirms them.

Per Taher's standing instruction: **committed and pushed without waiting for review.**

## Next step

1. Trigger `qml-tests` and `firestore-rules-tests` (or wait for the next scheduled run) and send
   the logs the same way.
2. If both pass: every CI job on this branch is green for the first time. Worth Taher's own check
   of whether `docs/superpowers/specs/2026-08-09-e2e-testing-phase1-design.md` should get a short
   addendum noting the actual final file location, since the spec's own stated intent (§7,
   "separate directory from tests/") is what this fix actually delivered on — not required, but
   the spec is now slightly stale relative to what shipped.
3. Gap list carried forward, unaffected by any of this: QSettings org-identifier warnings under
   qmltestrunner, `ActivityLog`'s client-side 403s, the `AuthService`-lazy-construction pattern as
   a design note, and now the `functions-tests` job's same-shape (currently benign) exposure to the
   directory-sweep mechanism above.
