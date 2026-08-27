"use strict";

// Test harness for functions/index.js's exported HTTPS handlers.
//
// Why this exists: functions/test/*.test.js so far only covers functions/lib/
// *.js -- pure, dependency-injected logic. index.js itself (auth, request
// validation wiring, and critically the translation from a lib/ result
// object into the actual HTTP response body) had ZERO test coverage until
// this file. That untested seam is exactly where Skill 43's bug lived: a
// value (`conflict: true`) was computed correctly one function down, and
// silently dropped when index.js built the response body by hand. This
// harness exists to make that seam testable without needing a live Firebase
// emulator (this sandbox has no network access to one -- see CHECKPOINT.md).
//
// How it works: functions/index.js calls `admin.initializeApp()` and
// `require("./lib/gatewayLogic")` etc. at MODULE LOAD time, and calls
// `admin.auth()` / `getFirestore()` per request. Node's CommonJS require
// cache is keyed by each dependency's resolved absolute file path, so
// installing fake exports into `require.cache` for those exact paths BEFORE
// requiring index.js makes index.js transparently pick up the fakes -- no
// changes to index.js itself needed. `mockState` is left mutable so each
// test can reconfigure auth/Firestore-doc/GatewayLogic-result behavior
// before invoking a handler; index.js itself is only ever required once
// (module-level code, like admin.initializeApp(), only needs to run once).
//
// Deliberately mocks GatewayLogic's *exported functions* (applyMutation,
// applyDelta, etc.) rather than simulating a real Firestore transaction --
// GatewayLogic's own correctness is functions/test/gatewayLogic.test.js's
// job. This harness's job is index.js's own logic: auth, deriveContext,
// and — the one that matters most — building the HTTP response from
// whatever GatewayLogic/BatchMutationLogic hand back.

const httpMocks = require("node-mocks-http");

function resolveFromFunctionsRoot(moduleId) {
    return require.resolve(moduleId, { paths: [__dirname + "/../.."] });
}

function installMocks() {
    const adminPath = resolveFromFunctionsRoot("firebase-admin");
    const firestorePath = resolveFromFunctionsRoot("firebase-admin/firestore");
    const gatewayLogicPath = require.resolve("../../lib/gatewayLogic");
    const batchMutationLogicPath = require.resolve("../../lib/batchMutationLogic");

    const mockState = {
        verifyIdToken: async () => { throw new Error("mockState.verifyIdToken not configured for this test"); },
        docs: {}, // path -> plain data object (undefined/missing = "does not exist")
        applyMutationResult: null,
        applyDeltaResult: null,
        applyMutationsBatchResult: null
    };

    require.cache[adminPath] = {
        id: adminPath, filename: adminPath, loaded: true,
        exports: {
            initializeApp: () => {},
            app: () => ({}),
            auth: () => ({ verifyIdToken: (token) => mockState.verifyIdToken(token) })
        }
    };

    require.cache[firestorePath] = {
        id: firestorePath, filename: firestorePath, loaded: true,
        exports: {
            getFirestore: () => ({
                doc: (docPath) => ({
                    get: async () => {
                        const data = mockState.docs[docPath];
                        return { exists: data !== undefined, data: () => data };
                    }
                })
            }),
            FieldValue: { serverTimestamp: () => "MOCK_SERVER_TIMESTAMP" }
        }
    };

    // Real GatewayLogic/BatchMutationLogic for parseBearerToken/
    // validateMutationRequest/etc (already covered by their own test
    // files) -- only the actual Firestore-writing functions get stubbed.
    const realGatewayLogic = require(gatewayLogicPath);
    require.cache[gatewayLogicPath] = {
        id: gatewayLogicPath, filename: gatewayLogicPath, loaded: true,
        exports: Object.assign({}, realGatewayLogic, {
            applyMutation: async () => mockState.applyMutationResult,
            applyDelta: async () => mockState.applyDeltaResult
        })
    };
    const realBatchMutationLogic = require(batchMutationLogicPath);
    require.cache[batchMutationLogicPath] = {
        id: batchMutationLogicPath, filename: batchMutationLogicPath, loaded: true,
        exports: Object.assign({}, realBatchMutationLogic, {
            applyMutationsBatch: async () => mockState.applyMutationsBatchResult
        })
    };

    const handlers = require("../../index.js");
    return { handlers: handlers, mockState: mockState };
}

// Sets up a realistic "authenticated, active member of an existing tenant"
// baseline. Tests override mockState.docs directly for 403/no-tenant-context
// scenarios, or mockState.verifyIdToken for 401 scenarios.
function seedHappyPathAuth(mockState, opts) {
    const o = opts || {};
    const uid = o.uid || "test-uid";
    const tenantId = o.tenantId || "test-tenant";
    mockState.verifyIdToken = async () => ({ uid: uid });
    mockState.docs["users/" + uid] = { tenantId: tenantId, role: o.role || "owner", name: o.name || "Test User" };
    mockState.docs["tenants/" + tenantId + "/members/" + uid] = { role: o.role || "owner", name: o.name || "Test User", status: "active" };
    mockState.docs["tenants/" + tenantId] = { name: o.tenantName || "Test Co" };
}

function mockReq(overrides) {
    const base = {
        method: "POST",
        headers: { authorization: "Bearer faketoken", origin: "http://localhost" }
    };
    return httpMocks.createRequest(Object.assign(base, overrides || {}));
}

function mockRes() {
    return httpMocks.createResponse();
}

function jsonBody(res) {
    return JSON.parse(res._getData());
}

module.exports = { installMocks: installMocks, seedHappyPathAuth: seedHappyPathAuth, mockReq: mockReq, mockRes: mockRes, jsonBody: jsonBody };
