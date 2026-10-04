"use strict";

// Unit tests for functions/lib/photoCleanup.js (PH3). Test plan ids U13-U20, U28-U48:
// docs/superpowers/test-plans/2026-09-30-photos-s3-s4-s5-test-plan.md
const test = require("node:test");
const assert = require("node:assert/strict");
const C = require("../lib/photoCleanup");

// ---- buildSweepPrefix (U13-U18) -------------------------------------------------------------
test("U13 buildSweepPrefix: exact env/tenants/t/products/p/", () => {
    assert.equal(C.buildSweepPrefix("dev1", "t_abc", "PRD-1"), "dev1/tenants/t_abc/products/PRD-1/");
    assert.equal(C.buildSweepPrefix("prd", "t_abc", "PRD-1"), "prd/tenants/t_abc/products/PRD-1/");
});

test("U14 buildSweepPrefix: always ends with / (PRD-1 never matches PRD-10)", () => {
    const p1 = C.buildSweepPrefix("test", "t", "PRD-1");
    assert.equal(p1.slice(-1), "/");
    assert.equal("test/tenants/t/products/PRD-10/x.jpg".startsWith(p1), false);
});

test("U15 buildSweepPrefix: empty productId -> null (would widen to products/)", () => {
    assert.equal(C.buildSweepPrefix("dev1", "t", ""), null);
    assert.equal(C.buildSweepPrefix("dev1", "t", undefined), null);
});

test("U16 buildSweepPrefix: unsafe tenant, product or env segment -> null, each separately", () => {
    assert.equal(C.buildSweepPrefix("dev1", "a/b", "p"), null);
    assert.equal(C.buildSweepPrefix("dev1", "t", ".."), null);
    assert.equal(C.buildSweepPrefix("dev1", "t", "a b"), null);
    assert.equal(C.buildSweepPrefix("", "t", "p"), null);
    assert.equal(C.buildSweepPrefix("de/v", "t", "p"), null);
    assert.equal(C.buildSweepPrefix("dev1", "", "p"), null);
    assert.equal(C.buildSweepPrefix("dev1", "t".repeat(65), "p"), null);
});

test("U17 buildSweepPrefix: env prefix containing / -> null", () => {
    assert.equal(C.buildSweepPrefix("dev1/tenants/x", "t", "p"), null);
    assert.equal(C.buildSweepPrefix("../dev1", "t", "p"), null);
});

test("U18 MONKEY buildSweepPrefix: random ids never yield a prefix outside their own tenant+product", () => {
    const chars = Array.from("abAB09_-./\\ %\u00e9\u{1F600}\n");
    let seed = 7;
    const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
    const rs = () => { let s = ""; const n = Math.floor(rnd() * 8); for (let i = 0; i < n; i++) s += chars[Math.floor(rnd() * chars.length)]; return s; };
    let produced = 0;
    for (let i = 0; i < 2000; i++) {
        const env = rs(), t = rs(), p = rs();
        const out = C.buildSweepPrefix(env, t, p);
        if (out === null) continue;
        produced++;
        assert.equal(out, env + "/tenants/" + t + "/products/" + p + "/");
        assert.equal(out.split("/").length, 6); // env, tenants, t, products, p, "" : no extra segment
        assert.ok(p.length > 0 && t.length > 0 && env.length > 0);
    }
    assert.ok(produced > 0, "monkey must exercise the accept path at least once");
});

// ---- buildMarker (U19-U20) ------------------------------------------------------------------
test("U19 buildMarker: fields present, attempts 0, lastError null, prefix copied, tenantId not stored", () => {
    const prefix = C.buildSweepPrefix("dev1", "t_1", "PRD-5");
    const m = C.buildMarker({ productId: "PRD-5", envPrefix: "dev1", tenantId: "t_1", prefix: prefix, createdAt: "TS" });
    assert.deepEqual(m, { productId: "PRD-5", envPrefix: "dev1", prefix: prefix, createdAt: "TS", attempts: 0, lastError: null });
    assert.equal("tenantId" in m, false);
    assert.equal("requestId" in m, false);
});

test("U20 buildMarker: null/empty/mismatched prefix refused", () => {
    const ok = C.buildSweepPrefix("dev1", "t_1", "PRD-5");
    assert.equal(C.buildMarker({ productId: "PRD-5", envPrefix: "dev1", tenantId: "t_1", prefix: null }), null);
    assert.equal(C.buildMarker({ productId: "PRD-5", envPrefix: "dev1", tenantId: "t_1", prefix: "" }), null);
    assert.equal(C.buildMarker({ productId: "PRD-5", envPrefix: "dev1", tenantId: "t_1", prefix: 42 }), null);
    assert.equal(C.buildMarker({ productId: "PRD-6", envPrefix: "dev1", tenantId: "t_1", prefix: ok }), null);
    assert.equal(C.buildMarker({ productId: "", envPrefix: "dev1", tenantId: "t_1", prefix: "dev1/tenants/t_1/products//" }), null);
    assert.equal(C.buildMarker(undefined), null);
});

// ---- canManagePhotos (U28-U30) --------------------------------------------------------------
test("U28 canManagePhotos: owner, admin true", () => {
    assert.equal(C.canManagePhotos("owner"), true);
    assert.equal(C.canManagePhotos("admin"), true);
});
test("U29 canManagePhotos: manager, staff false", () => {
    assert.equal(C.canManagePhotos("manager"), false);
    assert.equal(C.canManagePhotos("staff"), false);
});
test("U30 canManagePhotos: empty, undefined, null, viewer, OWNER, 'Owner ' false", () => {
    for (const r of ["", undefined, null, "viewer", "OWNER", "Owner ", " owner", 1, {}]) {
        assert.equal(C.canManagePhotos(r), false, String(r));
    }
});

// ---- isCascadeEntityDelete (U31-U34) --------------------------------------------------------
test("U31 isCascadeEntityDelete: inventory+delete true", () => {
    assert.equal(C.isCascadeEntityDelete("inventory", "delete"), true);
});
test("U32 isCascadeEntityDelete: inventory create/update/opening_balance false", () => {
    for (const a of ["create", "update", "opening_balance"]) assert.equal(C.isCascadeEntityDelete("inventory", a), false);
});
test("U33 isCascadeEntityDelete: other entities + delete false", () => {
    for (const e of ["stock_batch", "order", "staff", "supplier", "transaction", "removed_staff", "stock_movement"]) {
        assert.equal(C.isCascadeEntityDelete(e, "delete"), false, e);
    }
});
test("U34 isCascadeEntityDelete: wrong case / undefined false", () => {
    assert.equal(C.isCascadeEntityDelete("Inventory", "delete"), false);
    assert.equal(C.isCascadeEntityDelete("inventory", "DELETE"), false);
    assert.equal(C.isCascadeEntityDelete(undefined, undefined), false);
    assert.equal(C.isCascadeEntityDelete("inventory", undefined), false);
});

// ---- evaluateUploadPreflight (U35-U39) ------------------------------------------------------
test("U35 preflight: missing product -> 404", () => {
    assert.deepEqual(C.evaluateUploadPreflight(null, "p1", 10), { ok: false, status: 404, error: "product-not-found" });
    assert.deepEqual(C.evaluateUploadPreflight(undefined, "p1", 10), { ok: false, status: 404, error: "product-not-found" });
});
test("U36 preflight: cap reached, new photoId -> 409", () => {
    const ids = Array.from({ length: 10 }, (_, i) => "p" + i);
    assert.deepEqual(C.evaluateUploadPreflight({ photoIds: ids }, "new", 10), { ok: false, status: 409, error: "photo-limit" });
    assert.equal(C.evaluateUploadPreflight({ photoIds: ids.concat(["extra"]) }, "new", 10).status, 409); // over cap
});
test("U37 preflight: cap reached, photoId already present (replay) -> ok", () => {
    const ids = Array.from({ length: 10 }, (_, i) => "p" + i);
    assert.deepEqual(C.evaluateUploadPreflight({ photoIds: ids }, "p3", 10), { ok: true });
});
test("U38 preflight: below cap -> ok (boundary 9 of 10)", () => {
    const nine = Array.from({ length: 9 }, (_, i) => "p" + i);
    assert.deepEqual(C.evaluateUploadPreflight({ photoIds: nine }, "new", 10), { ok: true });
});
test("U39 preflight: photoIds missing or not an array treated as empty", () => {
    assert.deepEqual(C.evaluateUploadPreflight({}, "a", 10), { ok: true });
    assert.deepEqual(C.evaluateUploadPreflight({ photoIds: "nope" }, "a", 10), { ok: true });
    assert.deepEqual(C.evaluateUploadPreflight({ photoIds: null }, "a", 10), { ok: true });
    assert.deepEqual(C.evaluateUploadPreflight({}, "a", 0), { ok: false, status: 409, error: "photo-limit" });
});

// ---- sweepMarker (U40-U48) ------------------------------------------------------------------
function fakeDeps(over) {
    const calls = { productExists: [], deleteFiles: [], deleteMarker: 0, updateMarker: [] };
    const deps = Object.assign({
        productExists: async (id) => { calls.productExists.push(id); return false; },
        deleteFiles: async (prefix) => { calls.deleteFiles.push(prefix); },
        deleteMarker: async () => { calls.deleteMarker++; },
        updateMarker: async (patch) => { calls.updateMarker.push(patch); }
    }, over || {});
    return { deps, calls };
}
const TENANT = "t_1";
function goodMarker(over) {
    return Object.assign({
        productId: "PRD-5", envPrefix: "dev1", prefix: "dev1/tenants/t_1/products/PRD-5/", attempts: 0
    }, over || {});
}

test("U40 sweepMarker: product exists again -> marker deleted, deleteFiles NOT called", async () => {
    const { deps, calls } = fakeDeps({ productExists: async () => true });
    const r = await C.sweepMarker(deps, TENANT, goodMarker());
    assert.deepEqual(r, { ok: true, dropped: true });
    assert.equal(calls.deleteFiles.length, 0);
    assert.equal(calls.deleteMarker, 1);
});

test("U41 sweepMarker: product absent -> deleteFiles once with exact prefix, marker deleted", async () => {
    const { deps, calls } = fakeDeps();
    const r = await C.sweepMarker(deps, TENANT, goodMarker());
    assert.deepEqual(r, { ok: true, swept: true });
    assert.deepEqual(calls.deleteFiles, ["dev1/tenants/t_1/products/PRD-5/"]);
    assert.equal(calls.deleteMarker, 1);
    assert.equal(calls.updateMarker.length, 0);
});

test("U42 sweepMarker: deleteFiles throws -> marker kept, attempts+1, lastError set and truncated to 200", async () => {
    const { deps, calls } = fakeDeps({ deleteFiles: async () => { throw new Error("x".repeat(500)); } });
    const r = await C.sweepMarker(deps, TENANT, goodMarker({ attempts: 2 }));
    assert.equal(r.ok, false);
    assert.equal(calls.deleteMarker, 0);
    assert.equal(calls.updateMarker.length, 1);
    assert.equal(calls.updateMarker[0].attempts, 3);
    assert.equal(calls.updateMarker[0].lastError.length, C.MAX_LAST_ERROR_CHARS);
    assert.equal(r.error.length, C.MAX_LAST_ERROR_CHARS);
});

test("U43 sweepMarker: marker delete throws after a good sweep -> swallowed, still ok", async () => {
    const { deps } = fakeDeps({ deleteMarker: async () => { throw new Error("boom"); } });
    assert.deepEqual(await C.sweepMarker(deps, TENANT, goodMarker()), { ok: true, swept: true });
    const reused = fakeDeps({ productExists: async () => true, deleteMarker: async () => { throw new Error("boom"); } });
    assert.deepEqual(await C.sweepMarker(reused.deps, TENANT, goodMarker()), { ok: true, dropped: true });
});

test("U44 sweepMarker: product read throws -> marker kept, attempts+1, no sweep (never sweep when unsure)", async () => {
    const { deps, calls } = fakeDeps({ productExists: async () => { throw new Error("firestore down"); } });
    const r = await C.sweepMarker(deps, TENANT, goodMarker());
    assert.equal(r.ok, false);
    assert.equal(r.error, "firestore down");
    assert.equal(calls.deleteFiles.length, 0);
    assert.equal(calls.deleteMarker, 0);
    assert.equal(calls.updateMarker[0].attempts, 1);
});

test("U45 sweepMarker: null prefix, prefix without trailing slash, or prefix != rebuilt prefix -> no deleteFiles, marker kept with lastError", async () => {
    const bad = [
        goodMarker({ prefix: null }),
        goodMarker({ prefix: "" }),
        goodMarker({ prefix: "dev1/tenants/t_1/products/PRD-5" }),            // no trailing slash
        goodMarker({ prefix: "dev1/tenants/t_1/products/" }),                  // widened to every product
        goodMarker({ prefix: "dev1/tenants/t_1/" }),                           // widened to the tenant
        goodMarker({ prefix: "dev1/tenants/t_OTHER/products/PRD-5/" }),        // other tenant
        goodMarker({ prefix: "dev1/tenants/t_1/products/PRD-6/" }),            // other product
        goodMarker({ productId: "", prefix: "dev1/tenants/t_1/products//" }),  // empty product id
        goodMarker({ productId: "../x", prefix: "dev1/tenants/t_1/products/../x/" })
    ];
    for (const m of bad) {
        const { deps, calls } = fakeDeps();
        const r = await C.sweepMarker(deps, TENANT, m);
        assert.equal(r.ok, false, JSON.stringify(m));
        assert.equal(r.error, "unsafe-sweep-prefix");
        assert.equal(calls.deleteFiles.length, 0, JSON.stringify(m));
        assert.equal(calls.productExists.length, 0, "guard runs before any read");
        assert.equal(calls.deleteMarker, 0);
        assert.equal(calls.updateMarker[0].lastError, "unsafe-sweep-prefix");
    }
});

test("U45b sweepMarker: tenantId comes from the argument (doc path), not the marker body", async () => {
    const { deps, calls } = fakeDeps();
    // marker body claims t_1; the doc path says t_2 -> prefix mismatch -> refused.
    const r = await C.sweepMarker(deps, "t_2", goodMarker());
    assert.equal(r.ok, false);
    assert.equal(calls.deleteFiles.length, 0);
    // unsafe tenant from the path is refused too.
    const r2 = await C.sweepMarker(deps, "a/b", goodMarker());
    assert.equal(r2.ok, false);
});

test("U46 sweepMarker: second run with no files -> ok (idempotent)", async () => {
    const { deps, calls } = fakeDeps();
    assert.equal((await C.sweepMarker(deps, TENANT, goodMarker())).ok, true);
    assert.equal((await C.sweepMarker(deps, TENANT, goodMarker())).ok, true);
    assert.equal(calls.deleteFiles.length, 2);
});

test("U47 sweepMarker: two concurrent sweeps of one marker both finish", async () => {
    const { deps, calls } = fakeDeps();
    const [a, b] = await Promise.all([
        C.sweepMarker(deps, TENANT, goodMarker()),
        C.sweepMarker(deps, TENANT, goodMarker())
    ]);
    assert.equal(a.ok, true);
    assert.equal(b.ok, true);
    assert.equal(calls.deleteFiles.length, 2);
    assert.deepEqual(calls.deleteFiles[0], calls.deleteFiles[1]);
});

test("U48 sweepMarker: missing or unsafe envPrefix -> no deleteFiles, marker kept with lastError (review I2)", async () => {
    for (const envPrefix of [undefined, null, "", "de/v", "..", "dev 1"]) {
        const { deps, calls } = fakeDeps();
        const r = await C.sweepMarker(deps, TENANT, goodMarker({ envPrefix: envPrefix }));
        assert.equal(r.ok, false, String(envPrefix));
        assert.equal(calls.deleteFiles.length, 0);
        assert.equal(calls.updateMarker[0].lastError, "unsafe-sweep-prefix");
    }
});

test("sweepMarker: updateMarker itself throwing never escapes (never throws contract)", async () => {
    const { deps } = fakeDeps({
        deleteFiles: async () => { throw new Error("storage down"); },
        updateMarker: async () => { throw new Error("firestore down too"); }
    });
    const r = await C.sweepMarker(deps, TENANT, goodMarker());
    assert.deepEqual(r, { ok: false, error: "storage down" });
});

test("sweepMarker: non-Error throw values and missing marker are handled", async () => {
    const { deps, calls } = fakeDeps({ deleteFiles: async () => { throw "plain string"; } });
    const r = await C.sweepMarker(deps, TENANT, goodMarker({ attempts: "junk" }));
    assert.equal(r.error, "plain string");
    assert.equal(calls.updateMarker[0].attempts, 1); // junk attempts treated as 0
    const { deps: d2, calls: c2 } = fakeDeps({ deleteFiles: async () => { throw undefined; } });
    assert.equal((await C.sweepMarker(d2, TENANT, goodMarker())).error, "unknown-error");
    assert.equal(c2.updateMarker.length, 1);
    const r3 = await C.sweepMarker(fakeDeps().deps, TENANT, undefined);
    assert.equal(r3.ok, false);
});
