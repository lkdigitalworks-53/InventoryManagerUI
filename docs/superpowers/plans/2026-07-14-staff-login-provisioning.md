# Staff/Manager/Admin Login — Go-Live Prep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking. **Note for this session specifically:** no
> subagent-dispatch tool was available, so this plan was executed inline via
> superpowers:executing-plans instead.

**Goal:** Make the already-built `provisionMember` login-provisioning path safe to deploy, fix
a related staff-removal data-integrity bug the locked Firestore rules would otherwise expose,
and leave the actual go-live (`firebase deploy` + flipping `Gateway.provisioningAvailable`) as
a distinct, later, human-run step.

**Architecture:** Extract the existing inline `provisionMember` Cloud Function logic into a
pure, DI-style `functions/lib/provisionMember.js` module (mirroring `gatewayLogic.js`), fixing
a password-reset bug along the way. Add a new, symmetrical `functions/lib/deprovisionMember.js`
+ Cloud Function to fix a Firestore-rules-breaking bug in staff removal. Wire both into
`functions/index.js` as thin `onRequest` wrappers. Update the QML client
(`Gateway.qml`, `AuthService.qml`) to call the new deprovision endpoint. No change to
`Gateway.mode`, `runCutover`, or `Gateway.provisioningAvailable` (stays `false`).

**Tech Stack:** Firebase Cloud Functions (Node.js, Firebase Admin SDK), Node's built-in
`node:test` + `node:assert/strict` test runner, Qt/QML client (Felgo).

## Global Constraints

- `Gateway.provisioningAvailable` (`Gateway.qml:34`) stays `false` for the entire plan — it is
  flipped in a separate, later session after Taher deploys and verifies.
- No change to `Gateway.mode` or `exports.runCutover` / the P0 ledger cutover, anywhere in this
  plan.
- `users/{uid}` is never hard-deleted by any new code, regardless of `tenants[]` state —
  explicit requirement from Taher.
- No Firebase/GCP network access in this environment — nothing in this plan can be deployed or
  emulator-tested here; verification is `node --test` (real, runs locally) plus code review for
  the QML pieces (no Qt toolchain available either).
- No app build/run in this plan.
- Every task ends with a local commit (`git commit`, no push) using the existing repo commit
  style (`type(scope): summary`, matching recent history).

---

## File Structure

- **Create:** `functions/lib/provisionMember.js` — pure provisioning logic (role-matrix
  validation, Auth resolve/create/password-reset, Firestore doc writes). Zero direct Firebase
  SDK dependency; `authAdmin`/`db` passed in by the caller.
- **Create:** `functions/test/provisionMember.test.js` — Node test suite for the above.
- **Create:** `functions/lib/deprovisionMember.js` — pure deprovisioning logic (authorization,
  `tenants[]` pruning). Same DI style.
- **Create:** `functions/test/deprovisionMember.test.js` — Node test suite for the above.
- **Modify:** `functions/index.js` — replace inline `provisionMember` body with a thin wrapper
  around the new lib module; add a new thin `exports.deprovisionMember` wrapper.
- **Modify:** `qml/model/Gateway.qml` — add `deprovisionMember(uid, tenantId)`, mirroring the
  existing `provisionMember()` client function.
- **Modify:** `qml/model/AuthService.qml` — `cleanupStaffAuthDocs()` calls the new
  `Gateway.deprovisionMember()` before the existing `members/{uid}` removal, gated on
  `provisioningAvailable`.
- **Create:** `docs/DEPLOYMENT_RUNBOOK.md` — exact deploy sequence + manual verification
  checklist, for Taher.

---

### Task 1: Extract `provisionMember` logic into `functions/lib/provisionMember.js` (behavior-preserving)

**Files:**
- Create: `functions/lib/provisionMember.js`
- Create: `functions/test/provisionMember.test.js`

**Interfaces:**
- Produces: `canAssignRole(actorRole, targetRole) -> bool`, `validateProvisionRequest(body,
  actorRole) -> {ok, status?, error?, email?, displayName?, password?, targetUid?, role?}`,
  `findOrCreateAuthUser(authAdmin, email, password, displayName) -> {uid, created}`,
  `resolveTargetUser(authAdmin, db, params) -> {uid, created, resolvedEmail}`,
  `writeMemberDocs(db, ctx, resolved, role, displayName, nowIso, invitedByUid) -> void`.
  Task 3 consumes all five.

- [ ] **Step 1: Write the failing test file**

```javascript
// functions/test/provisionMember.test.js
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const ProvisionMemberLogic = require("../lib/provisionMember");

// ── Fakes ────────────────────────────────────────────────────────────────

function makeFakeDb(seedDocs) {
    const documents = Object.assign({}, seedDocs || {}); // path -> data
    const writes = []; // { type: "set", path, data, options }

    function docRef(path) {
        return {
            path,
            async get() {
                const exists = Object.prototype.hasOwnProperty.call(documents, path);
                return { exists, data: () => documents[path] };
            }
        };
    }

    return {
        documents,
        writes,
        doc: docRef,
        async runTransaction(fn) {
            const txn = {
                async get(ref) { return docRef(ref.path).get(); },
                set(ref, data, options) {
                    const merge = options && options.merge;
                    const prior = documents[ref.path] || {};
                    documents[ref.path] = merge ? Object.assign({}, prior, data) : data;
                    writes.push({ type: "set", path: ref.path, data, options });
                }
            };
            return fn(txn);
        }
    };
}

function makeFakeAuthAdmin(seedUsersByEmail) {
    const byEmail = Object.assign({}, seedUsersByEmail || {});
    const byUid = {};
    Object.keys(byEmail).forEach((email) => { byUid[byEmail[email].uid] = byEmail[email]; });
    const createdUsers = [];
    const updatedUsers = [];

    return {
        createdUsers,
        updatedUsers,
        async getUserByEmail(email) {
            const u = byEmail[email];
            if (!u) {
                const err = new Error("no user");
                err.code = "auth/user-not-found";
                throw err;
            }
            return u;
        },
        async getUser(uid) {
            const u = byUid[uid];
            if (!u) {
                const err = new Error("no user");
                err.code = "auth/user-not-found";
                throw err;
            }
            return u;
        },
        async createUser(fields) {
            const uid = "new-uid-" + (createdUsers.length + 1);
            const u = { uid: uid, email: fields.email, displayName: fields.displayName };
            byEmail[fields.email] = u;
            byUid[uid] = u;
            createdUsers.push({ uid: uid, email: fields.email, password: fields.password,
                displayName: fields.displayName });
            return u;
        },
        async updateUser(uid, fields) {
            updatedUsers.push({ uid: uid, fields: fields });
            if (byUid[uid]) Object.assign(byUid[uid], fields);
        }
    };
}

function baseCtx(overrides) {
    return Object.assign({ tenantId: "tenant-1", tenantName: "Tenant One" }, overrides || {});
}

// ── canAssignRole ────────────────────────────────────────────────────────

test("canAssignRole: owner may assign admin, manager, or staff", () => {
    assert.equal(ProvisionMemberLogic.canAssignRole("owner", "admin"), true);
    assert.equal(ProvisionMemberLogic.canAssignRole("owner", "manager"), true);
    assert.equal(ProvisionMemberLogic.canAssignRole("owner", "staff"), true);
});

test("canAssignRole: admin may assign manager or staff, not admin or owner", () => {
    assert.equal(ProvisionMemberLogic.canAssignRole("admin", "manager"), true);
    assert.equal(ProvisionMemberLogic.canAssignRole("admin", "staff"), true);
    assert.equal(ProvisionMemberLogic.canAssignRole("admin", "admin"), false);
    assert.equal(ProvisionMemberLogic.canAssignRole("admin", "owner"), false);
});

test("canAssignRole: manager and staff may assign no one", () => {
    assert.equal(ProvisionMemberLogic.canAssignRole("manager", "staff"), false);
    assert.equal(ProvisionMemberLogic.canAssignRole("staff", "staff"), false);
});

// ── validateProvisionRequest ─────────────────────────────────────────────

test("validateProvisionRequest rejects a role the actor can't assign", () => {
    const result = ProvisionMemberLogic.validateProvisionRequest(
        { email: "a@b.com", role: "admin" }, "admin");
    assert.equal(result.ok, false);
    assert.equal(result.status, 403);
    assert.equal(result.error, "role-not-allowed");
});

test("validateProvisionRequest rejects missing email and uid", () => {
    const result = ProvisionMemberLogic.validateProvisionRequest(
        { role: "staff" }, "owner");
    assert.equal(result.ok, false);
    assert.equal(result.status, 400);
    assert.equal(result.error, "email-or-uid-required");
});

test("validateProvisionRequest falls back to staff for an unknown role", () => {
    const result = ProvisionMemberLogic.validateProvisionRequest(
        { email: "a@b.com", role: "superadmin" }, "owner");
    assert.equal(result.ok, true);
    assert.equal(result.role, "staff");
});

test("validateProvisionRequest normalizes and lowercases email", () => {
    const result = ProvisionMemberLogic.validateProvisionRequest(
        { email: "  A@B.com  ", role: "staff" }, "owner");
    assert.equal(result.ok, true);
    assert.equal(result.email, "a@b.com");
});

// ── findOrCreateAuthUser ─────────────────────────────────────────────────

test("findOrCreateAuthUser returns the existing account without creating one", async () => {
    const authAdmin = makeFakeAuthAdmin({ "a@b.com": { uid: "uid-existing", email: "a@b.com" } });
    const result = await ProvisionMemberLogic.findOrCreateAuthUser(
        authAdmin, "a@b.com", "somepassword", "Name");
    assert.equal(result.uid, "uid-existing");
    assert.equal(result.created, false);
    assert.equal(authAdmin.createdUsers.length, 0);
});

test("findOrCreateAuthUser creates a new account when none exists and a valid password is given", async () => {
    const authAdmin = makeFakeAuthAdmin();
    const result = await ProvisionMemberLogic.findOrCreateAuthUser(
        authAdmin, "new@b.com", "longenough", "New Person");
    assert.equal(result.created, true);
    assert.equal(authAdmin.createdUsers.length, 1);
    assert.equal(authAdmin.createdUsers[0].email, "new@b.com");
    assert.equal(authAdmin.createdUsers[0].password, "longenough");
});

test("findOrCreateAuthUser rejects creation with a too-short password", async () => {
    const authAdmin = makeFakeAuthAdmin();
    await assert.rejects(
        () => ProvisionMemberLogic.findOrCreateAuthUser(authAdmin, "new@b.com", "abc", "N"),
        (err) => err.code === "password-required"
    );
});

test("findOrCreateAuthUser rejects creation with no password at all", async () => {
    const authAdmin = makeFakeAuthAdmin();
    await assert.rejects(
        () => ProvisionMemberLogic.findOrCreateAuthUser(authAdmin, "new@b.com", "", "N"),
        (err) => err.code === "password-required"
    );
});

// ── resolveTargetUser (includes the password-reset-on-reattach fix — see Task 2) ─

test("resolveTargetUser: explicit uid resolves via getUser, ignores password", async () => {
    const authAdmin = makeFakeAuthAdmin();
    authAdmin.byUidSeed = null; // not used; getUser is seeded via createUser below
    const created = await authAdmin.createUser({ email: "x@b.com", password: "p", displayName: "X" });
    const db = makeFakeDb();
    const result = await ProvisionMemberLogic.resolveTargetUser(authAdmin, db, {
        targetUid: created.uid, email: "", password: "", displayName: ""
    });
    assert.equal(result.uid, created.uid);
    assert.equal(result.created, false);
    assert.equal(authAdmin.updatedUsers.length, 0);
});

module.exports = { makeFakeDb, makeFakeAuthAdmin, baseCtx };
```

- [ ] **Step 2: Run the tests to verify they fail (module doesn't exist yet)**

Run: `cd functions && node --test test/provisionMember.test.js`
Expected: FAIL — `Cannot find module '../lib/provisionMember'`

- [ ] **Step 3: Write `functions/lib/provisionMember.js`** (behavior-preserving extraction —
  the password-reset fix is `resolveTargetUser`'s orphan check below; Task 2 adds tests that
  exercise it, but the logic is written now since it can't be cleanly separated from the
  extraction without leaving the extracted module behavior-*changing* relative to the current
  code, which the plan wants to avoid as two reviewable steps instead of one — Task 2 focuses
  purely on the *test coverage* proving the fix, not on writing it a second time.)

```javascript
// functions/lib/provisionMember.js
"use strict";

// Pure, testable core of the login-provisioning Cloud Function. Deliberately
// has zero Firebase SDK dependency of its own — `authAdmin` (an
// admin.auth()-shaped object) and `db` are passed in by the caller
// (index.js), so this module can be unit tested without a real or emulated
// Firebase project.
//
// Extracted from functions/index.js's exports.provisionMember — behavior-
// preserving refactor plus one fix (see resolveTargetUser) — see
// docs/superpowers/specs/2026-07-14-staff-login-provisioning-design.md.

// Mirrors AuthService._canAssignRole so client and server agree.
function canAssignRole(actorRole, targetRole) {
    if (actorRole === "owner")
        return ["admin", "manager", "staff"].indexOf(targetRole) >= 0;
    if (actorRole === "admin")
        return ["manager", "staff"].indexOf(targetRole) >= 0;
    return false;
}

// Validates + normalizes a provisionMember request body against the actor's
// role. Returns { ok: true, email, displayName, password, targetUid, role }
// or { ok: false, status, error }.
function validateProvisionRequest(body, actorRole) {
    const b = body || {};
    const email = String(b.email || "").trim().toLowerCase();
    const displayName = String(b.displayName || "").trim();
    const password = b.password ? String(b.password) : "";
    const targetUid = String(b.uid || "").trim();
    let role = String(b.role || "staff");
    if (["admin", "manager", "staff"].indexOf(role) < 0) role = "staff";

    if (!canAssignRole(actorRole, role)) {
        return { ok: false, status: 403, error: "role-not-allowed" };
    }
    if (!email && !targetUid) {
        return { ok: false, status: 400, error: "email-or-uid-required" };
    }
    return {
        ok: true,
        email: email,
        displayName: displayName,
        password: password,
        targetUid: targetUid,
        role: role
    };
}

// Resolve an email to an existing Auth user, or create one. `password` is
// only used when creating. Returns { uid, created }.
async function findOrCreateAuthUser(authAdmin, email, password, displayName) {
    try {
        const existing = await authAdmin.getUserByEmail(email);
        return { uid: existing.uid, created: false };
    } catch (e) {
        if (e.code !== "auth/user-not-found") throw e;
    }
    if (!password || password.length < 6) {
        const err = new Error("password-required");
        err.code = "password-required";
        throw err;
    }
    const created = await authAdmin.createUser({
        email: email,
        password: password,
        displayName: displayName || undefined
    });
    return { uid: created.uid, created: true };
}

// Resolves the target uid for a provision request: explicit uid wins
// (invite-by-uid), else find-or-create by email (add-staff).
//
// Password-reset-on-reattach fix: if the resolved account already existed
// (created === false) and a password was supplied, checks whether
// users/{uid} exists in Firestore. If it does NOT — the account is
// genuinely orphaned (e.g. a previously-removed staff member's Auth
// account, still alive but with no active tenant membership) — the new
// password is applied via authAdmin.updateUser(). If a users/{uid} doc
// DOES exist, the account is an active member of some tenant and the
// password is left untouched, so one tenant owner can never silently reset
// another tenant's already-active staff member's password just by
// re-entering their email on an add-staff form.
async function resolveTargetUser(authAdmin, db, params) {
    let uid, created = false, resolvedEmail = params.email;
    if (params.targetUid) {
        uid = params.targetUid;
        const u = await authAdmin.getUser(params.targetUid);
        resolvedEmail = u.email || params.email;
    } else {
        const r = await findOrCreateAuthUser(
            authAdmin, params.email, params.password, params.displayName);
        uid = r.uid;
        created = r.created;
    }

    if (!created && params.password) {
        const existingUserDoc = await db.doc("users/" + uid).get();
        if (!existingUserDoc.exists) {
            await authAdmin.updateUser(uid, {
                password: params.password,
                displayName: params.displayName || undefined
            });
        }
    }

    return { uid: uid, created: created, resolvedEmail: resolvedEmail };
}

// Writes users/{uid} and tenants/{tenantId}/members/{uid} in one
// transaction. `ctx` is the caller's derived tenant context
// ({tenantId, tenantName}); `resolved` is resolveTargetUser's return value.
async function writeMemberDocs(db, ctx, resolved, role, displayName, nowIso, invitedByUid) {
    const userRef = db.doc("users/" + resolved.uid);
    const memberRef = db.doc("tenants/" + ctx.tenantId + "/members/" + resolved.uid);

    await db.runTransaction(async (txn) => {
        const userSnap = await txn.get(userRef);
        const existing = userSnap.exists ? (userSnap.data() || {}) : {};
        const tenants = Array.isArray(existing.tenants) ? existing.tenants.slice() : [];
        if (tenants.indexOf(ctx.tenantId) < 0) tenants.push(ctx.tenantId);

        const userDoc = {
            uid: resolved.uid,
            email: existing.email || resolved.resolvedEmail,
            displayName: existing.displayName || displayName,
            photoUrl: existing.photoUrl || "",
            tenants: tenants,
            tenantId: resolved.created ? ctx.tenantId : (existing.tenantId || ctx.tenantId),
            tenantName: resolved.created ? ctx.tenantName : (existing.tenantName || ctx.tenantName),
            role: resolved.created ? role : (existing.role || role),
            createdAt: existing.createdAt || nowIso,
            lastLoginAt: existing.lastLoginAt || nowIso,
            status: "active"
        };
        txn.set(userRef, userDoc, { merge: true });

        txn.set(memberRef, {
            uid: resolved.uid,
            role: role,
            email: resolved.resolvedEmail,
            displayName: displayName,
            tenantName: ctx.tenantName,
            joinedAt: nowIso,
            invitedBy: invitedByUid,
            status: "active"
        }, { merge: true });
    });
}

module.exports = {
    canAssignRole,
    validateProvisionRequest,
    findOrCreateAuthUser,
    resolveTargetUser,
    writeMemberDocs
};
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd functions && node --test test/provisionMember.test.js`
Expected: PASS — all tests green (this includes the `resolveTargetUser` uid-path test; the
password-reset-specific tests are added in Task 2).

- [ ] **Step 5: Commit**

```bash
git add functions/lib/provisionMember.js functions/test/provisionMember.test.js
git commit -m "feat(functions): extract provisionMember logic into lib/provisionMember.js"
```

---

### Task 2: Add password-reset-on-reattach test coverage

**Files:**
- Modify: `functions/test/provisionMember.test.js` (append tests; logic already exists from
  Task 1)

**Interfaces:**
- Consumes: `ProvisionMemberLogic.resolveTargetUser(authAdmin, db, params)` from Task 1.

- [ ] **Step 1: Add the two failing-if-the-fix-were-absent tests**

Append to `functions/test/provisionMember.test.js`, before the final `module.exports` line:

```javascript
test("resolveTargetUser resets the password when the account is orphaned (no users/{uid} doc)", async () => {
    const authAdmin = makeFakeAuthAdmin({ "a@b.com": { uid: "uid-orphan", email: "a@b.com" } });
    const db = makeFakeDb(); // no users/uid-orphan doc — orphaned
    await ProvisionMemberLogic.resolveTargetUser(authAdmin, db, {
        email: "a@b.com", password: "newpassword123", displayName: "A"
    });
    assert.equal(authAdmin.updatedUsers.length, 1);
    assert.equal(authAdmin.updatedUsers[0].uid, "uid-orphan");
    assert.equal(authAdmin.updatedUsers[0].fields.password, "newpassword123");
});

test("resolveTargetUser leaves the password untouched when the account is active in another tenant", async () => {
    const authAdmin = makeFakeAuthAdmin({ "a@b.com": { uid: "uid-active", email: "a@b.com" } });
    const db = makeFakeDb({
        "users/uid-active": { uid: "uid-active", tenantId: "tenant-other", role: "staff",
            tenants: ["tenant-other"] }
    });
    await ProvisionMemberLogic.resolveTargetUser(authAdmin, db, {
        email: "a@b.com", password: "attemptedreset1", displayName: "A"
    });
    assert.equal(authAdmin.updatedUsers.length, 0,
        "must not reset the password of an account active in a different tenant");
});

test("resolveTargetUser does not attempt a password reset when no password was supplied (invite-by-uid style)", async () => {
    const authAdmin = makeFakeAuthAdmin({ "a@b.com": { uid: "uid-orphan2", email: "a@b.com" } });
    const db = makeFakeDb();
    await ProvisionMemberLogic.resolveTargetUser(authAdmin, db, {
        email: "a@b.com", password: "", displayName: "A"
    });
    assert.equal(authAdmin.updatedUsers.length, 0);
});
```

- [ ] **Step 2: Run to verify they pass (the fix already exists from Task 1, so this proves it — not a red/green cycle, a coverage cycle)**

Run: `cd functions && node --test test/provisionMember.test.js`
Expected: PASS — all tests, including the 3 new ones.

- [ ] **Step 3: Commit**

```bash
git add functions/test/provisionMember.test.js
git commit -m "test(functions): cover password-reset-on-reattach behavior for provisionMember"
```

---

### Task 3: Wire `provisionMember.js` into `functions/index.js`

**Files:**
- Modify: `functions/index.js:265-390` (replace `exports.provisionMember` body)

**Interfaces:**
- Consumes: all five exports from `functions/lib/provisionMember.js` (Task 1).
- Produces: `exports.provisionMember` — same HTTP contract as before (status codes, response
  shapes) — no client-visible behavior change except the password-reset fix.

- [ ] **Step 1: Add the require at the top of `functions/index.js`** (near the other lib
  requires, e.g. next to `CutoverLogic`/`GatewayLogic`)

```javascript
const ProvisionMemberLogic = require("./lib/provisionMember");
```

- [ ] **Step 2: Replace the body of `exports.provisionMember`** (currently `index.js:265-390`)
  with:

```javascript
exports.provisionMember = functions.onRequest(
    { region: "asia-south1", cors: true },
    async (req, res) => {
        if (req.method === "OPTIONS") { send(res, 204, {}); return; }
        if (req.method !== "POST") {
            send(res, 405, { ok: false, error: "method-not-allowed" });
            return;
        }

        const authHeader = req.get("Authorization") || "";
        const match = authHeader.match(/^Bearer\s+(.+)$/i);
        if (!match) { send(res, 401, { ok: false, error: "missing-token" }); return; }

        let decoded;
        try {
            decoded = await admin.auth().verifyIdToken(match[1]);
        } catch (e) {
            send(res, 401, { ok: false, error: "invalid-token" });
            return;
        }

        const body = req.body || {};
        const db = scopedDb(body.env);
        const ctx = await deriveContext(db, decoded.uid);
        if (!ctx) { send(res, 403, { ok: false, error: "no-tenant-context" }); return; }
        if (ctx.role !== "owner" && ctx.role !== "admin") {
            send(res, 403, { ok: false, error: "not-authorized" });
            return;
        }

        const validated = ProvisionMemberLogic.validateProvisionRequest(body, ctx.role);
        if (!validated.ok) {
            send(res, validated.status, { ok: false, error: validated.error });
            return;
        }

        let resolved;
        try {
            resolved = await ProvisionMemberLogic.resolveTargetUser(admin.auth(), db, validated);
        } catch (e) {
            if (e.code === "password-required") {
                send(res, 400, { ok: false, error: "password-required" });
                return;
            }
            if (e.code === "auth/user-not-found") {
                send(res, 404, { ok: false, error: "user-not-found" });
                return;
            }
            console.error("provisionMember auth resolve failed", e);
            send(res, 500, { ok: false, error: "auth-failed" });
            return;
        }

        const nowIso = new Date().toISOString();
        try {
            await ProvisionMemberLogic.writeMemberDocs(
                db, ctx, resolved, validated.role, validated.displayName, nowIso, decoded.uid);
        } catch (e) {
            console.error("provisionMember write failed", e);
            send(res, 500, { ok: false, error: "write-failed" });
            return;
        }

        send(res, 200, { ok: true, uid: resolved.uid, created: resolved.created });
    });
```

- [ ] **Step 3: Remove the now-dead inline `canAssignRole` and `findOrCreateAuthUser`
  functions from `functions/index.js`** (originally `:234-263`) — they're superseded by the
  lib module. Double-check nothing else in `index.js` still calls them directly before
  deleting (grep for both names first).

- [ ] **Step 4: Run the full functions test suite to confirm nothing else broke**

Run: `cd functions && node --test`
Expected: PASS — every existing test file plus the two new `provisionMember` tests, no
regressions in `gatewayLogic.test.js`, `cutoverLogic.test.js`, `batchMutationLogic.test.js`,
`breakdownMath.test.js`, `realisedMath.test.js`.

- [ ] **Step 5: Commit**

```bash
git add functions/index.js
git commit -m "refactor(functions): wire provisionMember through lib/provisionMember.js"
```

---

### Task 4: `functions/lib/deprovisionMember.js` + tests

**Files:**
- Create: `functions/lib/deprovisionMember.js`
- Create: `functions/test/deprovisionMember.test.js`

**Interfaces:**
- Produces: `canDeprovision(actorRole, targetRole, targetUid, actorUid) -> bool`,
  `pruneUserTenant(db, targetUid, tenantId) -> void`. Task 5 consumes both.

- [ ] **Step 1: Write the failing test file**

```javascript
// functions/test/deprovisionMember.test.js
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const DeprovisionMemberLogic = require("../lib/deprovisionMember");

function makeFakeDb(seedDocs) {
    const documents = Object.assign({}, seedDocs || {});
    const writes = [];

    function docRef(path) {
        return {
            path,
            async get() {
                const exists = Object.prototype.hasOwnProperty.call(documents, path);
                return { exists, data: () => documents[path] };
            }
        };
    }

    return {
        documents,
        writes,
        doc: docRef,
        async runTransaction(fn) {
            const txn = {
                async get(ref) { return docRef(ref.path).get(); },
                set(ref, data, options) {
                    const merge = options && options.merge;
                    const prior = documents[ref.path] || {};
                    documents[ref.path] = merge ? Object.assign({}, prior, data) : data;
                    writes.push({ type: "set", path: ref.path, data, options });
                }
            };
            return fn(txn);
        }
    };
}

// ── canDeprovision ───────────────────────────────────────────────────────

test("canDeprovision: owner may remove an admin, manager, or staff", () => {
    assert.equal(DeprovisionMemberLogic.canDeprovision("owner", "admin", "uid-2", "uid-1"), true);
    assert.equal(DeprovisionMemberLogic.canDeprovision("owner", "manager", "uid-2", "uid-1"), true);
});

test("canDeprovision: admin may remove a manager or staff", () => {
    assert.equal(DeprovisionMemberLogic.canDeprovision("admin", "staff", "uid-2", "uid-1"), true);
});

test("canDeprovision: no one may remove an owner", () => {
    assert.equal(DeprovisionMemberLogic.canDeprovision("owner", "owner", "uid-2", "uid-1"), false);
});

test("canDeprovision: no one may remove themselves via this path", () => {
    assert.equal(DeprovisionMemberLogic.canDeprovision("owner", "staff", "uid-1", "uid-1"), false);
});

test("canDeprovision: manager and staff may remove no one", () => {
    assert.equal(DeprovisionMemberLogic.canDeprovision("manager", "staff", "uid-2", "uid-1"), false);
    assert.equal(DeprovisionMemberLogic.canDeprovision("staff", "staff", "uid-2", "uid-1"), false);
});

// ── pruneUserTenant ──────────────────────────────────────────────────────

test("pruneUserTenant removes just the departed tenant, keeps others, keeps the doc", async () => {
    const db = makeFakeDb({
        "users/uid-x": { uid: "uid-x", tenants: ["tenant-1", "tenant-2"],
            tenantId: "tenant-2", tenantName: "Two", role: "staff" }
    });
    await DeprovisionMemberLogic.pruneUserTenant(db, "uid-x", "tenant-1");
    const after = db.documents["users/uid-x"];
    assert.deepEqual(after.tenants, ["tenant-2"]);
    // scalar pointer was tenant-2, not the removed tenant-1 — left alone
    assert.equal(after.tenantId, "tenant-2");
    assert.equal(after.role, "staff");
});

test("pruneUserTenant clears the scalar pointer when it matches the departed tenant", async () => {
    const db = makeFakeDb({
        "users/uid-x": { uid: "uid-x", tenants: ["tenant-1", "tenant-2"],
            tenantId: "tenant-1", tenantName: "One", role: "manager" }
    });
    await DeprovisionMemberLogic.pruneUserTenant(db, "uid-x", "tenant-1");
    const after = db.documents["users/uid-x"];
    assert.deepEqual(after.tenants, ["tenant-2"]);
    assert.equal(after.tenantId, "");
    assert.equal(after.tenantName, "");
    assert.equal(after.role, "");
});

test("pruneUserTenant keeps the doc (not deleted) when the last tenant is pruned", async () => {
    const db = makeFakeDb({
        "users/uid-x": { uid: "uid-x", tenants: ["tenant-1"],
            tenantId: "tenant-1", tenantName: "One", role: "staff" }
    });
    await DeprovisionMemberLogic.pruneUserTenant(db, "uid-x", "tenant-1");
    assert.ok(
        Object.prototype.hasOwnProperty.call(db.documents, "users/uid-x"),
        "users/{uid} must never be deleted, even when tenants[] becomes empty"
    );
    assert.deepEqual(db.documents["users/uid-x"].tenants, []);
});

test("pruneUserTenant is a no-op when users/{uid} doesn't exist", async () => {
    const db = makeFakeDb();
    await DeprovisionMemberLogic.pruneUserTenant(db, "uid-ghost", "tenant-1");
    assert.equal(
        Object.prototype.hasOwnProperty.call(db.documents, "users/uid-ghost"), false);
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd functions && node --test test/deprovisionMember.test.js`
Expected: FAIL — `Cannot find module '../lib/deprovisionMember'`

- [ ] **Step 3: Write `functions/lib/deprovisionMember.js`**

```javascript
// functions/lib/deprovisionMember.js
"use strict";

// Pure, testable core of the staff-deprovisioning Cloud Function. Zero
// Firebase SDK dependency of its own — `db` is passed in by the caller
// (index.js). See docs/superpowers/specs/2026-07-14-staff-login-
// provisioning-design.md for why this exists: the locked firestore.rules
// (users/{uid}: allow delete: if false; allow update: if request.auth.uid
// == uid) mean an owner/admin can never touch another user's users/{uid}
// doc from the client — that write has to happen here, via Admin SDK.

// Mirrors firestore.rules' tenants/{tenantId}/members/{uid} delete rule
// exactly: only owner/admin, never targeting an owner, never targeting
// yourself through this path.
function canDeprovision(actorRole, targetRole, targetUid, actorUid) {
    if (targetRole === "owner") return false;
    if (targetUid === actorUid) return false;
    return actorRole === "owner" || actorRole === "admin";
}

// Removes `tenantId` from users/{targetUid}'s tenants[] array. If the
// scalar tenantId/tenantName/role fields currently point at that same
// tenant, clears them (empty string) so a stale pointer never survives a
// removal — but the doc itself is NEVER deleted, even if tenants[] ends up
// empty: it still holds account-level profile fields (phone, address,
// photo) that belong to the person, not to any one tenant.
async function pruneUserTenant(db, targetUid, tenantId) {
    const userRef = db.doc("users/" + targetUid);
    await db.runTransaction(async (txn) => {
        const snap = await txn.get(userRef);
        if (!snap.exists) return; // nothing to prune
        const existing = snap.data() || {};
        const tenants = Array.isArray(existing.tenants) ? existing.tenants.slice() : [];
        const idx = tenants.indexOf(tenantId);
        if (idx >= 0) tenants.splice(idx, 1);

        const update = { tenants: tenants };
        if (existing.tenantId === tenantId) {
            update.tenantId = "";
            update.tenantName = "";
            update.role = "";
        }
        txn.set(userRef, update, { merge: true });
    });
}

module.exports = { canDeprovision, pruneUserTenant };
```

- [ ] **Step 4: Run to verify pass**

Run: `cd functions && node --test test/deprovisionMember.test.js`
Expected: PASS — all tests green.

- [ ] **Step 5: Commit**

```bash
git add functions/lib/deprovisionMember.js functions/test/deprovisionMember.test.js
git commit -m "feat(functions): add deprovisionMember logic (tenant-scoped users/{uid} prune)"
```

---

### Task 5: Wire `deprovisionMember` into `functions/index.js`

**Files:**
- Modify: `functions/index.js` (add `exports.deprovisionMember`, placed after
  `exports.provisionMember`)

**Interfaces:**
- Consumes: `DeprovisionMemberLogic.canDeprovision`, `DeprovisionMemberLogic.pruneUserTenant`
  (Task 4).
- Produces: `exports.deprovisionMember` — new endpoint,
  `POST /deprovisionMember` body `{ uid, targetRole }`, region `asia-south1`, same
  auth/response conventions as `provisionMember`. `targetRole` is supplied by the client (it
  already has it, from the member list it's displaying) but is **not trusted** for
  authorization — the function independently reads
  `tenants/{ctx.tenantId}/members/{uid}` server-side and uses *that* role for the
  `canDeprovision` check.

- [ ] **Step 1: Add the require** next to the `ProvisionMemberLogic` require added in Task 3:

```javascript
const DeprovisionMemberLogic = require("./lib/deprovisionMember");
```

- [ ] **Step 2: Add the new export**, directly after `exports.provisionMember`'s closing
  `});`:

```javascript
exports.deprovisionMember = functions.onRequest(
    { region: "asia-south1", cors: true },
    async (req, res) => {
        if (req.method === "OPTIONS") { send(res, 204, {}); return; }
        if (req.method !== "POST") {
            send(res, 405, { ok: false, error: "method-not-allowed" });
            return;
        }

        const authHeader = req.get("Authorization") || "";
        const match = authHeader.match(/^Bearer\s+(.+)$/i);
        if (!match) { send(res, 401, { ok: false, error: "missing-token" }); return; }

        let decoded;
        try {
            decoded = await admin.auth().verifyIdToken(match[1]);
        } catch (e) {
            send(res, 401, { ok: false, error: "invalid-token" });
            return;
        }

        const body = req.body || {};
        const db = scopedDb(body.env);
        const ctx = await deriveContext(db, decoded.uid);
        if (!ctx) { send(res, 403, { ok: false, error: "no-tenant-context" }); return; }

        const targetUid = String(body.uid || "").trim();
        if (!targetUid) { send(res, 400, { ok: false, error: "uid-required" }); return; }

        // Read the target's CURRENT role server-side — never trust the
        // client's copy for an authorization decision.
        const memberRef = db.doc("tenants/" + ctx.tenantId + "/members/" + targetUid);
        const memberSnap = await memberRef.get();
        if (!memberSnap.exists) {
            send(res, 404, { ok: false, error: "member-not-found" });
            return;
        }
        const targetRole = (memberSnap.data() || {}).role || "";

        if (!DeprovisionMemberLogic.canDeprovision(ctx.role, targetRole, targetUid, decoded.uid)) {
            send(res, 403, { ok: false, error: "not-authorized" });
            return;
        }

        try {
            await DeprovisionMemberLogic.pruneUserTenant(db, targetUid, ctx.tenantId);
        } catch (e) {
            console.error("deprovisionMember prune failed", e);
            send(res, 500, { ok: false, error: "write-failed" });
            return;
        }

        send(res, 200, { ok: true, uid: targetUid });
    });
```

- [ ] **Step 3: Run the full functions test suite**

Run: `cd functions && node --test`
Expected: PASS — every test file, no regressions.

- [ ] **Step 4: Commit**

```bash
git add functions/index.js
git commit -m "feat(functions): wire deprovisionMember Cloud Function endpoint"
```

---

### Task 6: Client wiring — `Gateway.qml` + `AuthService.qml`

**Files:**
- Modify: `qml/model/Gateway.qml` (add `deprovisionMember`, near `provisionMember` at
  `:300-368`)
- Modify: `qml/model/AuthService.qml` (`cleanupStaffAuthDocs`, `:911-920`)

**Interfaces:**
- Consumes: nothing new from earlier tasks (this is the HTTP client side of Task 5's endpoint).
- Produces: `Gateway.deprovisionMember(uid, tenantId, callback)` for `AuthService` to call.

**Note on verification:** no Qt toolchain is available in this environment (same constraint
prior sessions hit), so these two steps are code-review-only here — they cannot be run. They
become part of Taher's manual QA checklist after real deployment (Deployment Runbook, Task 7).

- [ ] **Step 1: Add `deprovisionMember` to `Gateway.qml`**, immediately after the existing
  `provisionMember` function (`:300-368`), mirroring its structure exactly (same
  `provisioningAvailable` gate, same error-callback shape):

```qml
function deprovisionMember(uid, tenantId, callback) {
    if (!provisioningAvailable) {
        if (callback) callback(false, "provisioning-unavailable")
        return
    }
    AuthStore.currentUser.getIdToken(function(token) {
        if (!token) { if (callback) callback(false, "no-token"); return }
        var xhr = new XMLHttpRequest()
        xhr.open("POST", "https://asia-south1-inventorymanager-48392.cloudfunctions.net/deprovisionMember")
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + token)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var ok = xhr.status === 200
            var body = {}
            try { body = JSON.parse(xhr.responseText) } catch (e) {}
            if (callback) callback(ok, body.error || "")
        }
        xhr.send(JSON.stringify({ uid: uid, tenantId: tenantId }))
    })
}
```

(Match whatever the real `provisionMember` function's exact token-fetch/XHR mechanics turn out
to be at edit time — `Gateway.qml:300-368` is the source of truth; this step's job is
structural parity with it, not a byte-for-byte guess from this plan.)

- [ ] **Step 2: Update `AuthService.cleanupStaffAuthDocs` in `AuthService.qml`** (currently
  `:911-920`) to call `Gateway.deprovisionMember` *before* the `members/{uid}` removal (so the
  member doc — which the Cloud Function reads to authorize the call — still exists when it
  runs):

```qml
function cleanupStaffAuthDocs(uid) {
    if (!uid || uid.length === 0) return
    if (!AuthStore.tenantId || AuthStore.tenantId.length === 0) return
    Gateway.deprovisionMember(uid, AuthStore.tenantId, function(ok, err) {
        if (!ok && err !== "provisioning-unavailable") {
            console.warn("[AuthService] deprovisionMember failed for", uid, err)
        }
    })
    FirebaseService.remove("tenants/" + AuthStore.tenantId + "/members/" + uid, function(okMember) {
        if (!okMember) console.warn("[AuthService] Failed to remove member doc for", uid)
    })
}
```

Note the old direct `FirebaseService.remove("users/" + uid, ...)` call is deleted entirely —
that's the call that will fail under the locked rules; `deprovisionMember` replaces it.

- [ ] **Step 3: Commit**

```bash
git add qml/model/Gateway.qml qml/model/AuthService.qml
git commit -m "feat(client): wire deprovisionMember into staff removal cleanup"
```

---

### Task 7: Deployment runbook

**Files:**
- Create: `docs/DEPLOYMENT_RUNBOOK.md`

- [ ] **Step 1: Write the runbook**

```markdown
# Deployment Runbook — Staff Login Provisioning Go-Live

Run this yourself — no part of it can be executed from a Claude session (no network route to
Firebase/GCP from that environment).

## Prerequisites
- Blaze plan enabled on the Firebase project (done).
- Firebase CLI installed and authenticated (`firebase login`) as an account with deploy rights
  on this project.

## 1. Deploy Cloud Functions

    cd functions
    npm install
    npm test          # confirm all suites still pass locally first
    firebase deploy --only functions

This deploys every exported function, including `provisionMember`, `deprovisionMember`,
`recordMutation`, `runCutover`, `computeAnalysis`, `recordMutationsBatch`. Deploying the
others alongside is harmless — `Gateway.mode` stays `"direct"` and `Gateway.
provisioningAvailable` stays `false`, so nothing client-side calls them yet.

## 2. Deploy Firestore rules

    firebase deploy --only firestore:rules

## 3. Manual verification (before touching the app)

- Firebase Console → Functions: confirm `provisionMember` and `deprovisionMember` show as
  deployed and healthy in `asia-south1`.
- Firebase Console → Firestore → Rules: confirm the deployed ruleset matches this repo's
  `firestore.rules` (check the "last deployed" timestamp/diff).
- Optional smoke test: a single authenticated `curl` POST to the `provisionMember` URL with a
  throwaway test tenant/email, confirming a 200 response and that `users/{uid}` +
  `tenants/{tenantId}/members/{uid}` appear correctly in the console. Clean up the test data
  afterward.

## 4. Only after all of the above is confirmed

Come back to a session and ask to flip `Gateway.provisioningAvailable` to `true`
(`qml/model/Gateway.qml:34`) — a separate, small change, followed by an end-to-end manual QA
pass (add each of the three assignable roles, log in as each, confirm scoped access, confirm
remove-then-re-add no longer reuses a stale password). App build/run still requires your
explicit go-ahead.
```

- [ ] **Step 2: Commit**

```bash
git add docs/DEPLOYMENT_RUNBOOK.md
git commit -m "docs: deployment runbook for staff login provisioning go-live"
```

---

## Plan Self-Review

**Spec coverage:** Design spec sections 1–6 map to Tasks 1–3 (§1 extraction, §2 password fix),
4–5 (§3 deprovisionMember), 6 (§4 client wiring), 1–5 (§5 tests woven into each task), 7 (§6
runbook). Non-goals (flag flip, `mode`/cutover, Auth account deletion, app build/run) are not
touched by any task — confirmed by scanning every task's Files/Steps.

**Placeholder scan:** No TBD/TODO. One deliberate exception, flagged inline in Task 6 Step 1:
the exact token-fetch/XHR mechanics are "match the real function," not guessed — because the
plan author (this session) has read `Gateway.qml:300-368` but is writing this before Task 6
executes, and the *executor* of Task 6 will have the real file open and should copy its actual
plumbing rather than trust a paraphrase. This is a deliberate parity instruction, not a
scope gap — flagged explicitly rather than silently guessed.

**Type consistency:** `resolveTargetUser`'s return shape `{uid, created, resolvedEmail}` is
used identically in Task 1's own tests, Task 3's wrapper, and matches `writeMemberDocs`'s
`resolved` parameter. `pruneUserTenant(db, targetUid, tenantId)`'s signature matches its Task 4
test calls and Task 5's wrapper call exactly.
