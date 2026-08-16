# E2E Testing Phase 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a real, service-level end-to-end test — Inventory CRUD driven through
`InventoryStore` → `Gateway` → the real (emulated) `recordMutation` Cloud Function → the real
(emulated) Firestore — running against the Firebase Local Emulator Suite in a new CI job on
every PR.

**Architecture:** Extend `firebase.json` with `auth`+`functions` emulator blocks. Add a
no-op-by-default `emulatorHost` override to `FirebaseService.qml` (the one file that needs a code
change — `Gateway.qml`'s Cloud Function URLs are already plain mutable properties a test can set
directly). A Node script (`test/e2e/seed.js`) seeds a tenant/membership/supplier and mints a real
emulator-signed ID token via the Auth emulator's REST exchange, handing it to the QML test via a
generated fixture JSON file. A new `tests/e2e/tst_InventoryE2E.qml` drives the real store methods
and asserts against raw REST reads of the emulator — not just the client's own optimistic state.

**Tech Stack:** QML/Qt Quick Test (`qmltestrunner`), Node.js 20, `firebase-admin`, Firebase Local
Emulator Suite (firestore/auth/functions), GitHub Actions.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-09-e2e-testing-phase1-design.md` — this plan implements
  that spec's §3–§7 exactly, with one approved-in-conversation deviation: **`Gateway.qml` needs
  no code change** (confirmed by reading its source — `functionUrl` etc. are already plain
  mutable `property string`, not computed/readonly), so there is no Task for it.
- **This sandbox cannot run the Firebase emulator or reach its distribution** (confirmed
  constraint, same one `test/firestore.rules.test.js` already documents). Every task below that
  needs a live emulator is written to the documented Local Emulator Suite conventions and
  verified by static means available here (syntax checks, `node --check`, dependency install) —
  final pass/fail confirmation happens in CI (Task 5) or on Taher's machine, exactly like the
  project's existing `tst_*.qml` files already are.
- One commit per task, only after Taher's explicit review of that task's diff.
- `PROJECT_ID` used by the emulator must be the literal string `inventorymanager-48392` —
  matching `FirebaseService.qml`'s hardcoded `projectId` — not a randomized per-run id like
  `test/firestore.rules.test.js` uses, because the QML client has no way to override which
  project id it targets, only which *host* it targets.
- Real production/dev/test behavior must not change: every new property defaults to a value that
  reproduces today's exact behavior when unset.

## File Structure

- `firebase.json` — modified: add `auth`, `functions` emulator blocks.
- `qml/model/FirebaseService.qml` — modified: add `emulatorHost` property, change `databaseUrl`
  binding.
- `tests/tst_FirebaseService.qml` — new: unit test for the override.
- `package.json` — modified: add `firebase-admin` devDependency.
- `test/e2e/seed.js` — new: emulator fixture seeding + token minting.
- `test/e2e/.gitignore` — new: ignore the generated `.fixture.json`.
- `tests/e2e/tst_InventoryE2E.qml` — new: the pilot E2E test.
- `.github/workflows/checks.yml` — modified: new `e2e-tests` job.

---

## Task 1: Emulator infra (`firebase.json`)

**Files:**
- Modify: `firebase.json`

**Interfaces:**
- Produces: emulator listening on `127.0.0.1:8080` (firestore, already existed),
  `127.0.0.1:9099` (auth), `127.0.0.1:5001` (functions) — later tasks' `emulatorHost`/URL
  overrides point at these exact ports.

- [ ] **Step 1: Edit `firebase.json`**

```json
{
  "functions": {
    "source": "functions",
    "runtime": "nodejs20"
  },
  "firestore": {
    "rules": "firestore.rules",
    "indexes": "firestore.indexes.json"
  },
  "hosting": {
    "public": "firebase-hosting/public",
    "ignore": ["firebase.json", "**/.*", "**/node_modules/**"],
    "rewrites": []
  },
  "emulators": {
    "firestore": {
      "port": 8080
    },
    "auth": {
      "port": 9099
    },
    "functions": {
      "port": 5001
    }
  }
}
```

- [ ] **Step 2: Validate JSON syntax**

Run: `node -e "JSON.parse(require('fs').readFileSync('firebase.json', 'utf8')); console.log('valid')"`
Expected: `valid`

- [ ] **Step 3: Commit**

```bash
git add firebase.json
git commit -m "feat(e2e): add auth+functions blocks to the Firebase emulator config"
```

(Full live verification — `firebase emulators:start` actually booting all three — happens
implicitly when Task 5's CI job runs, or on Taher's machine; not possible in this sandbox.)

---

## Task 2: `FirebaseService.qml` emulator-host override

**Files:**
- Modify: `qml/model/FirebaseService.qml:16-20`
- Test: `tests/tst_FirebaseService.qml` (new)

**Interfaces:**
- Produces: `FirebaseService.emulatorHost` (settable `property string`, default `""`). Task 4
  sets this to `"http://127.0.0.1:8080"` before driving the pilot scenario.

- [ ] **Step 1: Write the failing test**

Create `tests/tst_FirebaseService.qml`:

```qml
import QtQuick
import QtTest
import "../qml/model"

// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Written to convention and manually reviewed; needs a local
// `qmltestrunner` pass before merge (same status as tst_Gateway.qml,
// tst_EnvConfig.qml).
TestCase {
    name: "FirebaseService"

    function cleanup() {
        FirebaseService.emulatorHost = "" // never leak an override into the next test file
    }

    function test_databaseUrl_defaults_to_real_firestore() {
        compare(FirebaseService.emulatorHost, "")
        verify(FirebaseService.databaseUrl.indexOf("https://firestore.googleapis.com/v1/projects/") === 0,
               "databaseUrl should default to real Firestore when emulatorHost is unset")
    }

    function test_emulatorHost_override_redirects_databaseUrl() {
        FirebaseService.emulatorHost = "http://127.0.0.1:8080"
        var expected = "http://127.0.0.1:8080/v1/projects/" + FirebaseService.projectId
                        + "/databases/" + FirebaseService.databaseId + "/documents"
        compare(FirebaseService.databaseUrl, expected)
    }

    function test_emulatorHost_reset_restores_real_firestore() {
        FirebaseService.emulatorHost = "http://127.0.0.1:8080"
        FirebaseService.emulatorHost = ""
        verify(FirebaseService.databaseUrl.indexOf("https://firestore.googleapis.com/v1/projects/") === 0)
    }
}
```

- [ ] **Step 2: Confirm it would fail against current source**

`FirebaseService.qml` has no `emulatorHost` property yet, so
`test_emulatorHost_override_redirects_databaseUrl` would throw a QML "Cannot assign to
non-existent property" error. Cannot execute `qmltestrunner` in this sandbox to observe this
directly (no Qt toolchain) — confirmed instead by reading the current source
(`qml/model/FirebaseService.qml:19`, `readonly property string databaseUrl: "https://..."`, no
`emulatorHost` anywhere in the file).

- [ ] **Step 3: Implement `emulatorHost`**

In `qml/model/FirebaseService.qml`, replace:

```qml
    readonly property string environment: EnvConfig.envForStage(
        (typeof APP_STAGE !== "undefined" && APP_STAGE) ? APP_STAGE : "")
    readonly property string databaseId: EnvConfig.databaseIdForEnv(environment)
    readonly property string databaseUrl: "https://firestore.googleapis.com/v1/projects/"
                                          + projectId + "/databases/" + databaseId + "/documents"
```

with:

```qml
    readonly property string environment: EnvConfig.envForStage(
        (typeof APP_STAGE !== "undefined" && APP_STAGE) ? APP_STAGE : "")
    readonly property string databaseId: EnvConfig.databaseIdForEnv(environment)

    // Test/dev-only override. Empty (every real build, always) means every
    // existing behavior is unchanged — real Google Firestore, exactly as
    // before. Set directly by qmltestrunner tests (tests/e2e/) to redirect
    // at a local Firebase emulator instead. Never touched by production
    // code; no build-time or CMake involvement.
    property string emulatorHost: ""

    readonly property string databaseUrl: (emulatorHost.length > 0
            ? (emulatorHost + "/v1/projects/" + projectId + "/databases/" + databaseId + "/documents")
            : ("https://firestore.googleapis.com/v1/projects/"
               + projectId + "/databases/" + databaseId + "/documents"))
```

- [ ] **Step 4: Confirm it would pass**

Not executable in this sandbox. Manually trace: with `emulatorHost` unset, the ternary's false
branch reproduces the original literal expression exactly (byte-for-byte) — zero behavior change
for every existing build. With `emulatorHost = "http://127.0.0.1:8080"`, the true branch builds
`"http://127.0.0.1:8080/v1/projects/inventorymanager-48392/databases/(default)/documents"`,
matching the test's `expected` construction. Flag for Taher/CI to confirm with a real
`qmltestrunner -input tests` run.

- [ ] **Step 5: Commit**

```bash
git add qml/model/FirebaseService.qml tests/tst_FirebaseService.qml
git commit -m "feat(e2e): add FirebaseService.emulatorHost override, no-op by default"
```

---

## Task 3: Fixture seeding (`test/e2e/seed.js`)

**Files:**
- Modify: `package.json` (add `firebase-admin` devDependency)
- Create: `test/e2e/seed.js`
- Create: `test/e2e/.gitignore`

**Interfaces:**
- Consumes: `FIRESTORE_EMULATOR_HOST`, `FIREBASE_AUTH_EMULATOR_HOST` env vars (set automatically
  by `firebase emulators:exec --only firestore,auth,functions ...` for every child process it
  launches — documented Local Emulator Suite behavior).
- Produces: `test/e2e/.fixture.json` with the exact shape
  `{ idToken: string, uid: string, tenantId: string, supplierId: string, supplierName: string }`.
  Task 4's test reads this file verbatim.

- [ ] **Step 1: Add `firebase-admin` as a devDependency**

Run: `npm install --save-dev firebase-admin@^14.2.0`
Expected: `package.json`'s `devDependencies` gains `"firebase-admin": "^14.2.0"`, and
`package-lock.json` updates. (Verified reachable from this sandbox — `npm view firebase-admin
version` resolved `14.2.0` during planning.)

- [ ] **Step 2: Write `test/e2e/seed.js`**

```js
"use strict";

// Seeds a minimal tenant + membership + auth user directly into the
// Firebase Local Emulator Suite (Firestore + Auth), then mints a real
// (emulator-signed) ID token for that user and writes it — plus the ids
// the QML e2e test needs — to test/e2e/.fixture.json.
//
// Must run BEFORE qmltestrunner, inside the same `firebase emulators:exec`
// invocation that starts firestore+auth+functions — see
// .github/workflows/checks.yml's e2e-tests job, or run locally with:
//   firebase emulators:exec --only firestore,auth,functions \
//     "node test/e2e/seed.js && qmltestrunner -input tests/e2e -platform offscreen"
//
// NOT RUN IN THIS SANDBOX — no network egress here to Firebase's emulator
// distribution. Written to documented Local Emulator Suite REST/Admin SDK
// conventions; needs a real emulator pass (CI or Taher's machine) before
// the e2e-tests job can be trusted. Specifically unverified: whether
// `firebase emulators:exec` sets FIREBASE_AUTH_EMULATOR_HOST for child
// processes exactly as documented for this firebase-tools version — if
// this script exits early with the guard below, that's the first thing to
// check.

const fs = require("node:fs");
const path = require("node:path");
const admin = require("firebase-admin");

const PROJECT_ID = "inventorymanager-48392"; // MUST match FirebaseService.qml's
                                              // hardcoded projectId — the emulator
                                              // namespaces data by projectId, and
                                              // the QML client can't override that,
                                              // only which host it talks to.
const TENANT_ID = "e2e-tenant";
const TEST_UID = "e2e-owner";
const SUPPLIER_ID = "SUP-001";
const SUPPLIER_NAME = "E2E Supplier";
const AUTH_EMULATOR_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST || "";

if (!process.env.FIRESTORE_EMULATOR_HOST) {
    console.error("seed.js: FIRESTORE_EMULATOR_HOST is not set — refusing to run " +
                   "against what might be real Firestore.");
    process.exit(1);
}
if (!AUTH_EMULATOR_HOST) {
    console.error("seed.js: FIREBASE_AUTH_EMULATOR_HOST is not set — refusing to run " +
                   "against what might be real Firebase Auth.");
    process.exit(1);
}

admin.initializeApp({ projectId: PROJECT_ID });

async function mintIdToken(uid) {
    // Admin SDK can only mint a *custom* token. Exchanging it for a real ID
    // token that Cloud Functions' verifyIdToken() and the Firestore
    // emulator's rules evaluation will both accept is done via the Auth
    // emulator's identitytoolkit-compatible REST endpoint — documented
    // Local Emulator Suite behavior; any non-empty string works as the API
    // key, the emulator doesn't check it.
    const customToken = await admin.auth().createCustomToken(uid);
    const url = "http://" + AUTH_EMULATOR_HOST
        + "/identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=fake-api-key";
    const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token: customToken, returnSecureToken: true })
    });
    if (!res.ok) {
        throw new Error("signInWithCustomToken failed: " + res.status + " " + await res.text());
    }
    const data = await res.json();
    return data.idToken;
}

async function main() {
    const db = admin.firestore();

    await admin.auth().createUser({ uid: TEST_UID, email: "e2e@example.com" })
        .catch((e) => {
            if (e.code !== "auth/uid-already-exists") throw e;
        });

    await db.doc("users/" + TEST_UID).set({
        tenantId: TENANT_ID,
        tenantName: "E2E Test Co",
        role: "owner",
        name: "E2E Owner"
    });
    await db.doc("tenants/" + TENANT_ID).set({
        ownerId: TEST_UID,
        name: "E2E Test Co"
    });
    await db.doc("tenants/" + TENANT_ID + "/members/" + TEST_UID).set({
        uid: TEST_UID,
        role: "owner",
        status: "active",
        name: "E2E Owner"
    });
    // Pre-seeded so the pilot's addProduct() call resolves the supplier
    // name synchronously (InventoryStore._resolveSupplierId ->
    // SupplierStore.findByName) instead of also exercising supplier
    // creation through the gateway — keeps the pilot scoped to inventory
    // CRUD only, per the approved spec.
    await db.doc("tenants/" + TENANT_ID + "/suppliers/" + SUPPLIER_ID).set({
        supplierId: SUPPLIER_ID,
        name: SUPPLIER_NAME
    });

    const idToken = await mintIdToken(TEST_UID);

    const fixture = {
        idToken: idToken,
        uid: TEST_UID,
        tenantId: TENANT_ID,
        supplierId: SUPPLIER_ID,
        supplierName: SUPPLIER_NAME
    };
    const outPath = path.join(__dirname, ".fixture.json");
    fs.writeFileSync(outPath, JSON.stringify(fixture, null, 2));
    console.log("seed.js: wrote", outPath);
}

main().catch((e) => {
    console.error("seed.js failed:", e);
    process.exit(1);
});
```

- [ ] **Step 3: Ignore the generated fixture**

Create `test/e2e/.gitignore`:

```
.fixture.json
```

- [ ] **Step 4: Syntax-check (the closest verification available in this sandbox)**

Run: `node --check test/e2e/seed.js`
Expected: no output, exit code 0 (valid syntax; does not execute `main()`, which needs a live
emulator this sandbox can't reach).

- [ ] **Step 5: Commit**

```bash
git add package.json package-lock.json test/e2e/seed.js test/e2e/.gitignore
git commit -m "feat(e2e): add seed.js — emulator fixture seeding + ID token minting"
```

---

## Task 4: Pilot test (`tests/e2e/tst_InventoryE2E.qml`)

**Files:**
- Create: `tests/e2e/tst_InventoryE2E.qml`

**Interfaces:**
- Consumes: `FirebaseService.emulatorHost` (Task 2), `test/e2e/.fixture.json` shape (Task 3),
  `Gateway.functionUrl`/`Gateway.mode` (pre-existing, plain mutable properties — confirmed no
  code change needed), `InventoryStore.addProduct(name, sku, category, description, price, unit,
  stock, minStock, sellingPrice, taxable, taxPercent, party, unitCost, size, callback)`,
  `InventoryStore.updateProduct(productId, fields, reason)`,
  `InventoryStore.deleteProduct(productId)` (all pre-existing, unchanged signatures).

- [ ] **Step 1: Write `tests/e2e/tst_InventoryE2E.qml`**

```qml
import QtQuick
import QtTest
import "../../qml/model"

// Phase 1 E2E pilot — Inventory CRUD driven service-level (no UI) against
// the real Firebase Local Emulator Suite (Firestore + Auth + Functions).
// Real code path: InventoryStore.addProduct/updateProduct/deleteProduct ->
// Gateway.recordMutation ("gateway" mode, the real production default) ->
// POST to the emulated recordMutation Cloud Function -> Admin SDK write to
// the emulated Firestore -> response back to the client. Verified
// independently via a raw REST GET against the Firestore emulator, not
// just the client's own optimistic in-memory state.
//
// NOT RUN IN THIS SANDBOX — no network egress here to Firebase's emulator
// distribution. Requires test/e2e/.fixture.json (written by
// test/e2e/seed.js) and a running emulator suite. Run locally with:
//   firebase emulators:exec --only firestore,auth,functions \
//     "node test/e2e/seed.js && qmltestrunner -input tests/e2e -platform offscreen"

TestCase {
    name: "InventoryE2E"

    readonly property string emulatorFirestoreHost: "http://127.0.0.1:8080"
    readonly property string emulatorFunctionsBase: "http://127.0.0.1:5001/inventorymanager-48392/asia-south1"
    readonly property string realFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordMutation"

    property var fixture: null

    function _loadFixture() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", Qt.resolvedUrl("./.fixture.json"), false) // synchronous local read
        xhr.send()
        if (xhr.status !== 200 && xhr.status !== 0) { // status 0 is file:// success on some Qt builds
            fail("could not read .fixture.json (status " + xhr.status
                 + ") — run test/e2e/seed.js against a running emulator first")
        }
        return JSON.parse(xhr.responseText)
    }

    // Raw REST read against the emulator, independent of FirebaseService —
    // asserting via the same client code that wrote the data would only
    // prove the client's local cache is self-consistent, not that anything
    // real reached the server.
    function _getEmulatorDoc(docPath) {
        var url = emulatorFirestoreHost
            + "/v1/projects/inventorymanager-48392/databases/(default)/documents/" + docPath
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url, false)
        xhr.setRequestHeader("Authorization", "Bearer " + fixture.idToken)
        xhr.send()
        if (xhr.status !== 200) return null
        return JSON.parse(xhr.responseText)
    }

    function init() {
        fixture = _loadFixture()
        FirebaseService.emulatorHost = emulatorFirestoreHost
        Gateway.functionUrl = emulatorFunctionsBase + "/recordMutation"
        Gateway.mode = "gateway" // the real production default — see Gateway.qml
        AuthStore.idToken = fixture.idToken
        AuthStore.tenantId = fixture.tenantId
        SupplierStore.suppliers = [{ supplierId: fixture.supplierId, name: fixture.supplierName }]
        InventoryStore.products = []
    }

    function cleanup() {
        FirebaseService.emulatorHost = ""
        Gateway.functionUrl = realFunctionUrl
        AuthStore.idToken = ""
        AuthStore.tenantId = ""
    }

    function _createProduct(name, sku, stock) {
        var createdId = ""
        var done = false
        InventoryStore.addProduct(
            name, sku, "General", "", 100, "pc", stock, 2,
            120, false, 0, fixture.supplierName, 80, "",
            function(ok, id) { done = true; createdId = ok ? id : "" }
        )
        tryVerify(function() { return done }, 5000, "addProduct callback never fired")
        verify(createdId.length > 0, "addProduct did not return a productId")
        return createdId
    }

    function test_addProduct_creates_real_emulator_doc() {
        var id = _createProduct("E2E Widget", "SKU-E2E-1", 10)
        var docPath = "tenants/" + fixture.tenantId + "/inventory/" + id
        var doc = null
        tryVerify(function() { doc = _getEmulatorDoc(docPath); return doc !== null }, 5000,
                  "product doc never appeared in the emulator")
        compare(doc.fields.name.stringValue, "E2E Widget")
        compare(Number(doc.fields.stock.integerValue), 10)
    }

    function test_updateProduct_persists_to_emulator() {
        var id = _createProduct("E2E Widget Update", "SKU-E2E-2", 5)
        var docPath = "tenants/" + fixture.tenantId + "/inventory/" + id
        tryVerify(function() { return _getEmulatorDoc(docPath) !== null }, 5000,
                  "product doc never appeared before the update")

        InventoryStore.updateProduct(id, { stock: 25 }, "e2e adjustment")

        var doc = null
        tryVerify(function() {
            doc = _getEmulatorDoc(docPath)
            return doc !== null && Number(doc.fields.stock.integerValue) === 25
        }, 5000, "updated stock never reached the emulator")
        compare(Number(doc.fields.stock.integerValue), 25)
    }

    function test_deleteProduct_removes_from_emulator() {
        var id = _createProduct("E2E Widget Delete", "SKU-E2E-3", 3)
        var docPath = "tenants/" + fixture.tenantId + "/inventory/" + id
        tryVerify(function() { return _getEmulatorDoc(docPath) !== null }, 5000,
                  "product doc never appeared before the delete")

        InventoryStore.deleteProduct(id)

        tryVerify(function() { return _getEmulatorDoc(docPath) === null }, 5000,
                  "product doc was never removed from the emulator")
    }
}
```

- [ ] **Step 2: Syntax sanity-check**

This sandbox has no `qmltestrunner`. As a partial static check, confirm balanced braces/quotes
and that every method called (`InventoryStore.addProduct`, `.updateProduct`, `.deleteProduct`,
`Gateway.functionUrl`, `Gateway.mode`, `FirebaseService.emulatorHost`, `AuthStore.idToken`,
`AuthStore.tenantId`, `SupplierStore.suppliers`) exists in the current source — re-grep each name
against `qml/model/*.qml` before committing.

Run: `grep -n "function addProduct\|function updateProduct\|function deleteProduct" qml/model/InventoryStore.qml`
Expected: all three found (confirmed during planning — see this plan's research).

- [ ] **Step 3: Commit**

```bash
git add tests/e2e/tst_InventoryE2E.qml
git commit -m "feat(e2e): add Inventory CRUD pilot E2E test"
```

---

## Task 5: CI job (`e2e-tests`)

**Files:**
- Modify: `.github/workflows/checks.yml`

**Interfaces:**
- Consumes: everything from Tasks 1–4. First point where all of it actually runs together.

- [ ] **Step 1: Add the job**

Append to `.github/workflows/checks.yml`, as a new job alongside the existing three:

```yaml
  e2e-tests:
    name: E2E Tests (Inventory CRUD)
    runs-on: ubuntu-latest
    permissions:
      checks: write
      contents: read
    steps:
      - uses: actions/checkout@v4

      - name: Install Qt
        uses: jurplel/install-qt-action@v4
        with:
          version: '6.8.*'

      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
          cache-dependency-path: package-lock.json

      - uses: actions/setup-java@v4
        with:
          distribution: 'temurin'
          java-version: '21'

      - name: Install root dependencies
        run: npm ci

      - name: Install functions dependencies
        working-directory: functions
        run: npm ci

      - name: Install firebase-tools
        run: npm install -g firebase-tools

      - name: Run E2E tests
        env:
          QT_QPA_PLATFORM: offscreen
          QT_FORCE_STDERR_LOGGING: 1
          QT_LOGGING_TO_CONSOLE: 1
        run: |
          firebase emulators:exec --only firestore,auth,functions \
            "node test/e2e/seed.js && qmltestrunner -input tests/e2e -platform offscreen -o results.xml,junitxml"

      - name: Upload E2E test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: e2e-test-results
          path: results.xml

      - name: Report E2E test results
        if: always()
        uses: dorny/test-reporter@v1
        with:
          name: E2E Tests
          path: results.xml
          reporter: java-junit
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml, sys; yaml.safe_load(open('.github/workflows/checks.yml')); print('valid')"`
(or `node -e "require('js-yaml') ..."` if `python3`/`pyyaml` aren't available — either just needs
to confirm the file parses)
Expected: `valid`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/checks.yml
git commit -m "ci(e2e): add e2e-tests job running the Inventory CRUD pilot against the Local Emulator Suite"
```

- [ ] **Step 4: Push and open the real verification loop**

This is the first point anything in this plan actually runs for real. Push the branch, open (or
update) the PR, and watch the `E2E Tests` check. Expect the first run to surface at least one of
the flagged unknowns (§8 of the spec) — that's the point of running it in CI rather than assuming
it works. Per the spec's recommendation: treat this job as **non-blocking** until it's been green
across a few PRs; promoting it to a required check is a branch-protection setting Taher makes
outside this repo, once he's satisfied it's stable.

---

## Self-review

**Spec coverage:** §3 (Task 1), §4 for `FirebaseService.qml` (Task 2) with the noted, approved
deviation that `Gateway.qml` needs no change, §5 (Task 3), §6 (Task 5), §7 (Task 4). §8's spike
items are addressed by writing real, documented-convention code for each (custom-token→ID-token
exchange, `FIREBASE_AUTH_EMULATOR_HOST` propagation, Admin SDK auto-detection) rather than left
open — but their correctness is unverified until Task 5 Step 4 actually runs them.

**Placeholder scan:** none — every step has real, complete code; the two `grep`/syntax-check
steps are genuine verification actions available in this sandbox, not stand-ins for the ones that
aren't.

**Type/name consistency:** `emulatorHost` (Task 2) is the exact name Task 4 sets. The
`.fixture.json` shape produced in Task 3 (`idToken`, `uid`, `tenantId`, `supplierId`,
`supplierName`) matches exactly what Task 4 reads. `PROJECT_ID`/`TENANT_ID` literals in Task 3
(`inventorymanager-48392` / `e2e-tenant`) match what Task 4's `_getEmulatorDoc` and
`emulatorFunctionsBase` construct.
