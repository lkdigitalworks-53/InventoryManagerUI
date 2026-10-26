"use strict";

// S2f-7: decideProvision is the whole policy for "what may provisionMember do to an existing member
// doc". Pure, so every row of the table, every odd input shape and a seeded fuzz run here; the
// handler file (index.handlers.provisionMemberTarget.test.js) proves index.js obeys the verdict.

const test = require("node:test");
const assert = require("node:assert/strict");
const { decideProvision } = require("../lib/memberProvisionLogic");

const REQUESTED = ["admin", "manager", "staff"]; // what the endpoint can ask for after normalisation
const ROLES = ["owner", "admin", "manager", "staff"];

test("no existing doc -> create", () => {
    for (const r of REQUESTED) assert.deepEqual(decideProvision(null, r), { action: "create" });
});

test("owner target is refused whatever its status or the requested role (reason owner)", () => {
    for (const status of ["active", "suspended", undefined, "", "ACTIVE", 1]) {
        for (const r of REQUESTED) {
            assert.deepEqual(decideProvision({ role: "owner", status: status }, r), { action: "refuse", reason: "owner" });
        }
    }
});

test("existing non-active member is refused: suspended, missing, empty, wrong case, wrong type (reason not-active)", () => {
    for (const status of ["suspended", "removed", "", "ACTIVE", "Active", undefined, null, 0, 1, true, {}, []]) {
        for (const role of ["admin", "manager", "staff"]) {
            const d = decideProvision({ role: role, status: status }, role);
            assert.deepEqual(d, { action: "refuse", reason: "not-active" }, JSON.stringify([role, status]));
        }
    }
});

test("existing active member with a different role is refused (reason role-differs), both up and down", () => {
    for (const have of ["admin", "manager", "staff"]) {
        for (const want of REQUESTED) {
            if (have === want) continue;
            assert.deepEqual(decideProvision({ role: have, status: "active" }, want), { action: "refuse", reason: "role-differs" }, have + " -> " + want);
        }
    }
});

test("exact repeat (same role, active) -> unchanged, so a retry after a lost response succeeds", () => {
    for (const r of REQUESTED) assert.deepEqual(decideProvision({ role: r, status: "active" }, r), { action: "unchanged" });
});

test("an existing doc with a missing, empty or non-string role is refused (role-differs), never unchanged", () => {
    for (const role of [undefined, null, "", "Owner", "viewer", 7, {}, []]) {
        const d = decideProvision({ role: role, status: "active" }, "staff");
        assert.equal(d.action, "refuse", JSON.stringify(role));
    }
});

test("fails closed on input that is not a plain object (a caller bug must not become a write)", () => {
    for (const bad of [undefined, 0, 1, "", "member", true, false, [], [1], () => ({})]) {
        assert.deepEqual(decideProvision(bad, "staff"), { action: "refuse", reason: "unreadable" }, String(bad));
    }
});

test("the empty object (a doc whose data() came back empty) is refused as not-active, never created", () => {
    assert.deepEqual(decideProvision({}, "staff"), { action: "refuse", reason: "not-active" });
});

test("does not mutate its input", () => {
    const doc = Object.freeze({ role: "admin", status: "active", joinedAt: "x" });
    assert.deepEqual(decideProvision(doc, "admin"), { action: "unchanged" });
    assert.deepEqual(doc, { role: "admin", status: "active", joinedAt: "x" });
});

test("pure: same input, same verdict", () => {
    const doc = { role: "staff", status: "active" };
    assert.deepEqual(decideProvision(doc, "staff"), decideProvision(doc, "staff"));
});

// Seeded fuzz (mulberry32, fixed seed, reproducible): random doc shapes and requested roles. The
// invariants are the policy, written independently of the implementation's branch order.
function rng(seed) {
    let a = seed >>> 0;
    return () => {
        a = (a + 0x6D2B79F5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

test("seeded monkey: 2000 random docs -> 'create' only for null; 'unchanged' only for an active, non-owner, same-role doc", () => {
    const rand = rng(20261026);
    const pick = (xs) => xs[Math.floor(rand() * xs.length)];
    const roles = ROLES.concat([undefined, null, "", "viewer", "Owner", 7, {}]);
    const statuses = ["active", "suspended", "removed", undefined, null, "", "ACTIVE", 1, {}];
    let created = 0, unchanged = 0, refused = 0;
    for (let i = 0; i < 2000; i++) {
        const existing = rand() < 0.1 ? null : { role: pick(roles), status: pick(statuses) };
        const want = pick(REQUESTED);
        const d = decideProvision(existing, want);
        if (existing === null) {
            assert.equal(d.action, "create");
            created++;
            continue;
        }
        const wouldBeSafeRepeat = existing.status === "active" && existing.role === want && existing.role !== "owner";
        if (wouldBeSafeRepeat) {
            assert.equal(d.action, "unchanged", JSON.stringify([existing, want]));
            unchanged++;
        } else {
            assert.equal(d.action, "refuse", JSON.stringify([existing, want]));
            assert.ok(["owner", "not-active", "role-differs"].indexOf(d.reason) >= 0, "known reason code");
            refused++;
        }
    }
    // The generator must reach every branch or the run proves nothing.
    assert.ok(created > 0 && unchanged > 0 && refused > 0, [created, unchanged, refused].join("/"));
});
