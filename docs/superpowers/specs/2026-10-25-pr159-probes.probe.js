"use strict";

// PR #159 sweep probes (2026-10-25). CHARACTERIZATION ONLY: these print what the code does today, they
// assert nothing about "correct", so they never fail CI. File name does not end in .test.js, so no
// runner picks it up. Run:  cd functions && node --test ../docs/superpowers/specs/2026-10-25-pr159-probes.probe.js
// Prints lines starting with "P1".."P5". Findings they back: sweep report items 1 (P1), 6 (P2, P3), 9 (P5);
// P4 backs the "checked, not a finding" note on tenantId types.
// State: written against head 8c7eff7. On the fixed #159 head P1 prints 403 for every invalid role (the fix);
// P2, P3 (provisionMember, own slice) and P5 (finding 9, not done) still show the open behaviour.

const test = require("node:test");
const assert = require("node:assert/strict");
const { installMocks, seedHappyPathAuth, mockReq, mockRes, jsonBody } = require("../../../functions/test/testSupport/handlerHarness");
const { handlers, mockState } = installMocks();

const UID = "u1", T = "home";
function reset() {
  mockState.docs = {}; mockState.setCalls = [];
  mockState.applyMutationResult = { ok: true }; mockState.applyDeltaResult = { ok: true };
  mockState.applyOperationResult = { ok: true, results: [] };
  mockState.acquireLockResult = { ok: true, acquiredAt: 1, expiresAt: 2 };
}
const opBody = { env: "test", requestId: "completeOrder:o1:1", opType: "completeOrder", clientTimestamp: 1, ops: [{ kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -1 }, floors: { stock: 0 } }] };

for (const role of ["", "viewer", "Owner", undefined, 7, {}]) {
  test("P1 role=" + JSON.stringify(role) + " on recordOperation + acquireLock", async () => {
    reset(); seedHappyPathAuth(mockState, { uid: UID, tenantId: T, role: "staff" });
    const m = "tenants/" + T + "/members/" + UID;
    if (role === undefined) delete mockState.docs[m].role; else mockState.docs[m].role = role;
    const out = {};
    let res = mockRes(); await handlers.recordOperation(mockReq({ body: opBody }), res); out.recordOperation = res.statusCode + " " + (jsonBody(res).error || "ok");
    res = mockRes(); await handlers.acquireLock(mockReq({ body: { env: "test", entity: "order", entityId: "O1", requestId: "r" } }), res); out.acquireLock = res.statusCode + " " + (jsonBody(res).error || "ok");
    console.log("   P1", JSON.stringify(role), JSON.stringify(out));
  });
}

test("P2 admin re-provisions the OWNER via uid -> owner member doc role overwritten?", async () => {
  reset(); seedHappyPathAuth(mockState, { uid: UID, tenantId: T, role: "admin" });
  mockState.docs["tenants/" + T + "/members/owner1"] = { uid: "owner1", role: "owner", status: "active" };
  mockState.getUser = async () => ({ email: "owner@x.com" });
  const res = mockRes();
  await handlers.provisionMember(mockReq({ body: { env: "test", uid: "owner1", role: "staff" } }), res);
  const w = mockState.setCalls.filter((c) => c.path === "tenants/" + T + "/members/owner1");
  console.log("   P2 status", res.statusCode, JSON.stringify(jsonBody(res)), "member writes:", JSON.stringify(w.map((c) => ({ role: c.data.role, status: c.data.status, opts: c.opts }))));
});

test("P3 admin re-provisions a SUSPENDED member -> status flips to active?", async () => {
  reset(); seedHappyPathAuth(mockState, { uid: UID, tenantId: T, role: "owner" });
  mockState.docs["tenants/" + T + "/members/s1"] = { uid: "s1", role: "staff", status: "suspended" };
  mockState.getUser = async () => ({ email: "s@x.com" });
  const res = mockRes();
  await handlers.provisionMember(mockReq({ body: { env: "test", uid: "s1", role: "staff" } }), res);
  const w = mockState.setCalls.filter((c) => c.path === "tenants/" + T + "/members/s1");
  console.log("   P3 status", res.statusCode, "member writes:", JSON.stringify(w.map((c) => ({ role: c.data.role, status: c.data.status }))));
});

test("P4 non-string / oversize tenantId", async () => {
  for (const bad of [123, true, {}, [], "x".repeat(65), "tênant", "a.b", "t\n1"]) {
    reset(); mockState.verifyIdToken = async () => ({ uid: UID });
    mockState.docs["users/" + UID] = { tenantId: bad, role: "owner" };
    const res = mockRes();
    await handlers.acquireLock(mockReq({ body: { env: "test", entity: "order", entityId: "O1", requestId: "r" } }), res);
    console.log("   P4", JSON.stringify(bad).slice(0, 20), res.statusCode, jsonBody(res).error);
  }
});

// ---- P5: a Firestore read that throws inside deriveContext ----

test("P5 Firestore read throws inside deriveContext", async () => {
  mockState.docs = {}; mockState.setCalls = [];
  seedHappyPathAuth(mockState, { uid: "u1", tenantId: "home", role: "owner" });
  const real = mockState.docs;
  mockState.docs = new Proxy(real, { get(t, k) { if (typeof k === "string" && k.startsWith("tenants/home/members")) throw Object.assign(new Error("UNAVAILABLE"), { code: 14 }); return t[k]; } });
  const res = mockRes();
  let threw = null;
  try { await handlers.acquireLock(mockReq({ body: { env: "test", entity: "order", entityId: "O1", requestId: "r" } }), res); } catch (e) { threw = e.message; }
  console.log("   P5 threw:", threw, "| status:", res.statusCode, "| body:", String(res._getData ? res._getData() : "").slice(0, 80), "| ctype:", res.getHeader && res.getHeader("content-type"));
});

