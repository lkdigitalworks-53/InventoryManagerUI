"use strict";

// Unit tests for PH3b runCleanupSweep + readAllMarkers (functions/lib/photoCleanup.js), fakes only.
// Test plan ids UL01-UL07, UR01-UR18:
// docs/superpowers/test-plans/2026-10-05-ph3b-scheduled-cleanup-test-plan.md sec 1.4 / 1.4b
const test = require("node:test");
const assert = require("node:assert/strict");
const C = require("../lib/photoCleanup");

function mulberry32(seed) {
    let a = seed >>> 0;
    return function () {
        a = (a + 0x6D2B79F5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

// ---- readAllMarkers (UL01-UL07) ---------------------------------------------------------------
function pagedStore(total) {
    const all = [];
    for (let i = 0; i < total; i++) all.push({ id: "d" + i });
    const calls = [];
    const fetchPage = async (cursor, size) => {
        calls.push(cursor);
        const from = cursor === null ? 0 : all.indexOf(cursor) + 1;
        return all.slice(from, from + size);
    };
    return { all, calls, fetchPage };
}

test("UL01 readAllMarkers: empty first page -> {docs:[], backlog:false}, one call", async () => {
    const s = pagedStore(0);
    const r = await C.readAllMarkers((c) => s.fetchPage(c, 5), { pageSize: 5, maxPages: 3 });
    assert.deepEqual(r, { docs: [], backlog: false });
    assert.equal(s.calls.length, 1);
});

test("UL02 readAllMarkers: one short page -> all docs, backlog false, one call", async () => {
    const s = pagedStore(3);
    const r = await C.readAllMarkers((c) => s.fetchPage(c, 5), { pageSize: 5, maxPages: 3 });
    assert.equal(r.docs.length, 3);
    assert.equal(r.backlog, false);
    assert.equal(s.calls.length, 1);
});

test("UL03 readAllMarkers: exactly pageSize docs then empty page -> all docs, backlog false, two calls", async () => {
    const s = pagedStore(5);
    const r = await C.readAllMarkers((c) => s.fetchPage(c, 5), { pageSize: 5, maxPages: 3 });
    assert.equal(r.docs.length, 5);
    assert.equal(r.backlog, false);
    assert.equal(s.calls.length, 2);
});

test("UL04 readAllMarkers: 3 pages (full, full, short) in order, no duplicates, cursor = previous last doc", async () => {
    const s = pagedStore(12);
    const r = await C.readAllMarkers((c) => s.fetchPage(c, 5), { pageSize: 5, maxPages: 5 });
    assert.deepEqual(r.docs, s.all);
    assert.equal(new Set(r.docs).size, 12);
    assert.equal(r.backlog, false);
    assert.deepEqual(s.calls, [null, s.all[4], s.all[9]]);
});

test("UL05 readAllMarkers: maxPages full pages -> backlog true, exactly maxPages calls", async () => {
    const s = pagedStore(1000);
    const r = await C.readAllMarkers((c) => s.fetchPage(c, 5), { pageSize: 5, maxPages: 4 });
    assert.equal(r.backlog, true);
    assert.equal(r.docs.length, 20);
    assert.equal(s.calls.length, 4);
});

test("UL06 readAllMarkers: fetchPage throws on page 2 -> error propagates, no partial result", async () => {
    let n = 0;
    await assert.rejects(
        C.readAllMarkers(async () => {
            if (++n === 2) throw new Error("page 2 failed");
            return [{ id: 1 }, { id: 2 }];
        }, { pageSize: 2, maxPages: 5 }),
        /page 2 failed/
    );
});

test("UL07 MONKEY readAllMarkers: 300 random (pageSize, maxPages, total) vs fake paged store", async () => {
    const rnd = mulberry32(7);
    for (let i = 0; i < 300; i++) {
        const pageSize = 1 + Math.floor(rnd() * 8);
        const maxPages = 1 + Math.floor(rnd() * 6);
        const total = Math.floor(rnd() * 60);
        const s = pagedStore(total);
        const r = await C.readAllMarkers((c) => s.fetchPage(c, pageSize), { pageSize, maxPages });
        const cap = pageSize * maxPages;
        assert.deepEqual(r.docs, s.all.slice(0, Math.min(total, cap)), "triple " + [pageSize, maxPages, total]);
        // maxPages full pages read => backlog, even when exactly `cap` docs exist (a full page proves nothing)
        assert.equal(r.backlog, total >= cap, "backlog " + [pageSize, maxPages, total]);
        assert.ok(s.calls.length <= maxPages);
    }
});

test("readAllMarkers: defaults (PAGE_SIZE / MAX_PAGES), invalid opts fall back, non-array page = empty", async () => {
    assert.equal(C.MAX_SCAN, C.PAGE_SIZE * C.MAX_PAGES);
    let calls = 0;
    const r = await C.readAllMarkers(async () => { calls++; return undefined; });
    assert.deepEqual(r, { docs: [], backlog: false });
    assert.equal(calls, 1);
    for (const bad of [{ pageSize: 0, maxPages: -1 }, { pageSize: 1.5, maxPages: "3" }, null, undefined]) {
        let n = 0;
        const out = await C.readAllMarkers(async () => { n++; return new Array(C.PAGE_SIZE).fill({}); }, bad);
        assert.equal(out.backlog, true);
        assert.equal(n, C.MAX_PAGES, JSON.stringify(bad));
    }
});

// ---- runCleanupSweep fakes ---------------------------------------------------------------------
const NOW = 2_000_000_000_000;
const ENVS = [
    { name: "dev", envPrefix: "dev1" },
    { name: "test", envPrefix: "test" },
    { name: "prd", envPrefix: "prd" }
];

function entry(envPrefix, tenant, product, over, ageMs) {
    return {
        path: "tenants/" + tenant + "/pending_cleanup/" + product,
        createdAtMs: NOW - (ageMs === undefined ? 3_600_000 : ageMs),
        data: Object.assign({
            productId: product, envPrefix: envPrefix,
            prefix: envPrefix + "/tenants/" + tenant + "/products/" + product + "/",
            attempts: 0, lastError: null
        }, over || {})
    };
}

function mkRun(opts) {
    const o = opts || {};
    const clock = { t: NOW };
    const log = [];
    const sweeps = [];
    const parks = [];
    const store = o.store || {};            // env name -> entries[]
    const deps = {
        envs: ENVS,
        listMarkers: async (env) => {
            if (o.listThrows && o.listThrows[env.name]) throw new Error(o.listThrows[env.name]);
            return { entries: store[env.name] || [], backlog: !!(o.backlog && o.backlog[env.name]) };
        },
        sweep: async (env, tenantId, marker) => {
            sweeps.push({ env: env.name, tenantId, marker });
            if (o.onSweep) return o.onSweep(env, tenantId, marker, clock, sweeps.length);
            return { ok: true, swept: true };
        },
        park: async (env, path, reason) => {
            parks.push({ env: env.name, path, reason });
            if (o.parkThrows) throw new Error("park failed");
        },
        now: () => clock.t,
        log: (sev, obj) => log.push({ sev, obj })
    };
    return { deps, clock, log, sweeps, parks };
}
const alerts = (log) => log.filter((l) => l.sev === "ERROR" && String(l.obj.message).indexOf("PH3B_ALERT") === 0);
const summaryOf = (out, name) => out.envs.find((s) => s.env === name);

test("UR01 happy path: 3 due markers in 1 env -> swept oldest first, swept 3, envFailures 0", async () => {
    const r = mkRun({ store: { dev: [
        entry("dev1", "T1", "NEW", {}, 1_000_000),
        entry("dev1", "T1", "OLD", {}, 9_000_000),
        entry("dev1", "T2", "MID", {}, 5_000_000)
    ] } });
    const out = await C.runCleanupSweep(r.deps);
    assert.deepEqual(r.sweeps.map((s) => s.marker.productId), ["OLD", "MID", "NEW"]);
    assert.equal(r.sweeps[1].tenantId, "T2");
    assert.equal(summaryOf(out, "dev").swept, 3);
    assert.equal(summaryOf(out, "dev").scanned, 3);
    assert.equal(out.envFailures, 0);
});

test("UR02 empty run: no sweep / park, all counters 0, no throw", async () => {
    const r = mkRun();
    const out = await C.runCleanupSweep(r.deps);
    assert.equal(r.sweeps.length + r.parks.length, 0);
    assert.equal(out.envs.length, 3);
    for (const s of out.envs) {
        for (const k of ["scanned", "swept", "droppedIdReuse", "failed", "parked", "malformed", "notDue", "deferred"]) assert.equal(s[k], 0, k);
        assert.equal(s.backlog, false);
        assert.equal(s.error, null);
    }
    assert.equal(out.envFailures, 0);
});

test("UR03 env isolation: listMarkers throws for env 2 -> env 1 and 3 still run, envFailures 1", async () => {
    const r = mkRun({
        listThrows: { test: "db missing" },
        store: { dev: [entry("dev1", "T1", "P1")], prd: [entry("prd", "T1", "P2")] }
    });
    const out = await C.runCleanupSweep(r.deps);
    assert.equal(out.envFailures, 1);
    assert.equal(summaryOf(out, "test").error, "db missing");
    assert.equal(summaryOf(out, "dev").swept, 1);
    assert.equal(summaryOf(out, "prd").swept, 1);
});

test("UR04 marker isolation: sweep throws for A -> B still swept, A counted failed", async () => {
    const r = mkRun({
        store: { dev: [entry("dev1", "T1", "A", {}, 9_000_000), entry("dev1", "T1", "B", {}, 5_000_000)] },
        onSweep: (env, t, m) => { if (m.productId === "A") throw new Error("boom"); return { ok: true, swept: true }; }
    });
    const out = await C.runCleanupSweep(r.deps);
    assert.equal(summaryOf(out, "dev").failed, 1);
    assert.equal(summaryOf(out, "dev").swept, 1);
    assert.equal(r.parks.length, 0); // a throw means attempts were not incremented: never park on it
    assert.equal(out.envFailures, 0);
});

test("UR05 sweep ok:false below the cap -> failed, park NOT called", async () => {
    const r = mkRun({
        store: { dev: [entry("dev1", "T1", "P1", { attempts: C.PARK_AT - 2 })] },
        onSweep: () => ({ ok: false, error: "storage down" })
    });
    const out = await C.runCleanupSweep(r.deps);
    assert.equal(summaryOf(out, "dev").failed, 1);
    assert.equal(summaryOf(out, "dev").parked, 0);
    assert.equal(r.parks.length, 0);
});

test("UR06 sweep ok:false at attempts + 1 == PARK_AT -> park once with the sweep's error", async () => {
    const r = mkRun({
        store: { dev: [entry("dev1", "T1", "P1", { attempts: C.PARK_AT - 1 })] },
        onSweep: () => ({ ok: false, error: "storage down" })
    });
    const out = await C.runCleanupSweep(r.deps);
    assert.deepEqual(r.parks, [{ env: "dev", path: "tenants/T1/pending_cleanup/P1", reason: "storage down" }]);
    assert.equal(summaryOf(out, "dev").parked, 1);
    assert.equal(summaryOf(out, "dev").failed, 1);
});

test("UR07 sweep returns dropped -> droppedIdReuse +1, no park, not counted swept", async () => {
    const r = mkRun({
        store: { dev: [entry("dev1", "T1", "P1")] },
        onSweep: () => ({ ok: true, dropped: true })
    });
    const out = await C.runCleanupSweep(r.deps);
    assert.equal(summaryOf(out, "dev").droppedIdReuse, 1);
    assert.equal(summaryOf(out, "dev").swept, 0);
    assert.equal(r.parks.length, 0);
});

test("UR08 budget: clock past RUN_BUDGET_MS after the 2nd marker -> 3rd+ deferred, none parked/swept", async () => {
    const r = mkRun({
        store: { dev: [1, 2, 3, 4, 5].map((i) => entry("dev1", "T1", "P" + i, {}, 9_000_000 - i * 1000)) },
        onSweep: (env, t, m, clock, n) => { if (n === 2) clock.t += C.RUN_BUDGET_MS; return { ok: true, swept: true }; }
    });
    const out = await C.runCleanupSweep(r.deps);
    assert.equal(r.sweeps.length, 2);
    assert.equal(summaryOf(out, "dev").swept, 2);
    assert.equal(summaryOf(out, "dev").deferred, 3);
    assert.equal(r.parks.length, 0);
});

test("UR09 malformed marker -> parked at once, reason malformed-marker: ..., never swept", async () => {
    const r = mkRun({ store: { dev: [entry("dev1", "T1", "P1", { productId: "OTHER" })] } });
    const out = await C.runCleanupSweep(r.deps);
    assert.equal(r.sweeps.length, 0);
    assert.equal(r.parks.length, 1);
    assert.equal(r.parks[0].reason, "malformed-marker: product-id-mismatch");
    assert.equal(summaryOf(out, "dev").malformed, 1);
});

test("UR10 parked marker skipped: never swept, counted parked, no park call", async () => {
    const r = mkRun({ store: { dev: [entry("dev1", "T1", "P1", { parked: true, attempts: 12 }, 99_999_999)] } });
    const out = await C.runCleanupSweep(r.deps);
    assert.equal(r.sweeps.length + r.parks.length, 0);
    assert.equal(summaryOf(out, "dev").parked, 1);
    assert.equal(alerts(r.log).length, 0); // a parked marker must not re-alert every run
});

test("UR11 park throws -> counted failed, run continues with the next marker", async () => {
    const r = mkRun({
        parkThrows: true,
        store: { dev: [
            entry("dev1", "T1", "BAD", { productId: "X" }, 9_000_000),
            entry("dev1", "T1", "GOOD", {}, 5_000_000)
        ] }
    });
    const out = await C.runCleanupSweep(r.deps);
    assert.equal(summaryOf(out, "dev").failed, 1);
    assert.equal(summaryOf(out, "dev").swept, 1);
    assert.equal(summaryOf(out, "dev").parked, 0);
    assert.equal(out.envFailures, 0);
    assert.equal(alerts(r.log).length, 1); // park-failed is itself an alert
    assert.match(alerts(r.log)[0].obj.message, /park-failed/);
});

test("UR11b park throws at the cap -> failed counted once (sweep failure only), parked 0", async () => {
    const r = mkRun({
        parkThrows: true,
        store: { dev: [entry("dev1", "T1", "P1", { attempts: C.PARK_AT - 1 })] },
        onSweep: () => ({ ok: false, error: "e" })
    });
    const out = await C.runCleanupSweep(r.deps);
    assert.equal(summaryOf(out, "dev").failed, 1);
    assert.equal(summaryOf(out, "dev").parked, 0);
});

test("UR12 backlog true -> summary backlog true and an ERROR PH3B_ALERT line", async () => {
    const r = mkRun({ backlog: { test: true } });
    const out = await C.runCleanupSweep(r.deps);
    assert.equal(summaryOf(out, "test").backlog, true);
    assert.equal(summaryOf(out, "dev").backlog, false);
    const a = alerts(r.log);
    assert.equal(a.length, 1);
    assert.equal(a[0].obj.env, "test");
    assert.match(a[0].obj.message, /backlog/);
});

test("UR13 crashed sweep: attempts 0 marker older than grace -> swept next run, marker gone", async () => {
    const markers = [entry("dev1", "T1", "CRASHED", {}, C.GRACE_MS + 1000)];
    const r = mkRun({
        store: { dev: markers },
        onSweep: (env, t, m) => { markers.splice(0, markers.length); return { ok: true, swept: true }; }
    });
    const out = await C.runCleanupSweep(r.deps);
    assert.equal(summaryOf(out, "dev").swept, 1);
    assert.equal(markers.length, 0);
    const again = await C.runCleanupSweep(r.deps);
    assert.equal(summaryOf(again, "dev").scanned, 0);
});

test("UR14 summary shape: documented keys only, one log call per env on a clean run", async () => {
    const r = mkRun({ store: { dev: [entry("dev1", "T1", "P1")] } });
    const out = await C.runCleanupSweep(r.deps);
    const keys = ["backlog", "deferred", "droppedIdReuse", "env", "error", "failed", "malformed", "notDue", "parked", "scanned", "swept"];
    for (const s of out.envs) assert.deepEqual(Object.keys(s).sort(), keys);
    assert.equal(r.log.length, ENVS.length);
    assert.ok(r.log.every((l) => l.sev === "INFO"));
    assert.equal(Object.keys(out).sort().join(), "envFailures,envs");
});

test("UR14b notDue counted: marker inside grace is left alone", async () => {
    const r = mkRun({ store: { dev: [entry("dev1", "T1", "P1", {}, 1000)] } });
    const out = await C.runCleanupSweep(r.deps);
    assert.equal(summaryOf(out, "dev").notDue, 1);
    assert.equal(r.sweeps.length, 0);
});

test("UR15 marker parked at the cap -> one ERROR PH3B_ALERT with env, tenantId, productId, reason", async () => {
    const r = mkRun({
        store: { dev: [entry("dev1", "T1", "P1", { attempts: C.PARK_AT - 1 })] },
        onSweep: () => ({ ok: false, error: "storage down" })
    });
    await C.runCleanupSweep(r.deps);
    const a = alerts(r.log);
    assert.equal(a.length, 1);
    assert.equal(a[0].obj.message.indexOf("PH3B_ALERT"), 0);
    assert.deepEqual([a[0].obj.env, a[0].obj.tenantId, a[0].obj.productId, a[0].obj.reason], ["dev", "T1", "P1", "storage down"]);
});

test("UR16 malformed marker parked -> same alert, reason starts malformed-marker", async () => {
    const r = mkRun({ store: { dev: [entry("dev1", "T1", "P1", { envPrefix: "prd" })] } });
    await C.runCleanupSweep(r.deps);
    const a = alerts(r.log);
    assert.equal(a.length, 1);
    assert.equal(a[0].obj.reason.indexOf("malformed-marker"), 0);
    assert.equal(a[0].obj.tenantId, "T1");
});

test("UR16b malformed marker with unparsable path: alert carries null ids, park addressed by path", async () => {
    const bad = { path: "tenants/T1/x/y/pending_cleanup/P1", createdAtMs: NOW, data: { productId: "P1" } };
    const r = mkRun({ store: { dev: [bad] } });
    await C.runCleanupSweep(r.deps);
    assert.equal(r.parks[0].path, bad.path);
    assert.equal(r.parks[0].reason, "malformed-marker: bad-path");
    const a = alerts(r.log);
    assert.equal(a[0].obj.tenantId, null);
    assert.equal(a[0].obj.productId, null);
});

test("UR17 sub-cap failure -> WARNING log only, NO PH3B_ALERT anywhere (noise guard)", async () => {
    const r = mkRun({
        store: { dev: [entry("dev1", "T1", "P1", { attempts: 2 })] },
        onSweep: () => ({ ok: false, error: "storage down" })
    });
    await C.runCleanupSweep(r.deps);
    assert.equal(r.log.filter((l) => l.sev === "WARNING").length, 1);
    assert.equal(r.log.filter((l) => JSON.stringify(l.obj).indexOf("PH3B_ALERT") !== -1).length, 0);
    // a thrown sweep is also WARNING-only
    const t = mkRun({ store: { dev: [entry("dev1", "T1", "P1")] }, onSweep: () => { throw new Error("x"); } });
    await C.runCleanupSweep(t.deps);
    assert.equal(t.log.filter((l) => JSON.stringify(l.obj).indexOf("PH3B_ALERT") !== -1).length, 0);
    assert.equal(t.log.filter((l) => l.sev === "WARNING").length, 1);
});

test("UR18 env-level failure -> ERROR PH3B_ALERT with env; envFailures counted", async () => {
    const r = mkRun({ listThrows: { prd: "cannot read" } });
    const out = await C.runCleanupSweep(r.deps);
    const a = alerts(r.log);
    assert.equal(a.length, 1);
    assert.equal(a[0].obj.env, "prd");
    assert.equal(a[0].obj.reason, "cannot read");
    assert.equal(out.envFailures, 1);
});

test("runCleanupSweep: sweep returning junk (undefined / {ok:false} w/o error) counts as failed, never throws", async () => {
    for (const junk of [undefined, null, {}, { ok: false }]) {
        const r = mkRun({ store: { dev: [entry("dev1", "T1", "P1")] }, onSweep: () => junk });
        const out = await C.runCleanupSweep(r.deps);
        assert.equal(summaryOf(out, "dev").failed, 1);
    }
});

test("runCleanupSweep: sweep gets the marker with productId from the PATH, body fields preserved", async () => {
    const r = mkRun({ store: { dev: [entry("dev1", "T1", "P1", { actorUid: "u1", actorRole: "owner", requestId: "rq" })] } });
    await C.runCleanupSweep(r.deps);
    const m = r.sweeps[0].marker;
    assert.equal(m.productId, "P1");
    assert.equal(m.actorUid, "u1");
    assert.equal(m.prefix, "dev1/tenants/T1/products/P1/");
});

test("runCleanupSweep: listMarkers returning garbage -> env failure, other envs run", async () => {
    const r = mkRun({ store: { test: [entry("test", "T1", "P1")] } });
    const orig = r.deps.listMarkers;
    r.deps.listMarkers = async (env) => (env.name === "dev" ? undefined : orig(env));
    const out = await C.runCleanupSweep(r.deps);
    assert.equal(out.envFailures, 1);
    assert.equal(summaryOf(out, "test").swept, 1);
});

test("UR19 MONKEY runCleanupSweep: 300 random runs never throw; counters add up", async () => {
    const rnd = mulberry32(19);
    const pick = (a) => a[Math.floor(rnd() * a.length)];
    for (let i = 0; i < 300; i++) {
        const entries = [];
        const n = Math.floor(rnd() * 8);
        for (let j = 0; j < n; j++) {
            entries.push(entry("dev1", pick(["T1", "T2"]), "P" + j + "_" + i, pick([
                {}, { parked: true }, { productId: "zz" }, { attempts: C.PARK_AT - 1 }, { envPrefix: "prd" }, { attempts: 3, lastAttemptAtMs: NOW }
            ]), Math.floor(rnd() * 1e7)));
        }
        const r = mkRun({
            store: { dev: entries },
            parkThrows: rnd() < 0.2,
            onSweep: () => pick([{ ok: true, swept: true }, { ok: true, dropped: true }, { ok: false, error: "e" }, null])
        });
        const out = await C.runCleanupSweep(r.deps);
        const s = summaryOf(out, "dev");
        assert.equal(s.scanned, n);
        // every scanned entry is notDue, parked(already), malformed, or went through sweep (due)
        const handled = s.notDue + s.malformed + r.sweeps.length + s.deferred;
        const preParked = entries.filter((e) => e.data.parked === true).length;
        assert.equal(handled + preParked, n, "iteration " + i);
    }
});
