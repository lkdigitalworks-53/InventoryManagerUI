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
// Deliberately mocks each lib/ module's *Firestore-writing exported
// functions* (GatewayLogic.applyMutation/applyDelta, BatchMutationLogic.
// applyMutationsBatch, LockLogic.acquireLock/releaseLock, CutoverLogic.
// deleteCollection/zeroInventoryStock) rather than simulating a real
// Firestore transaction for each -- every one of those lib/ modules'
// Firestore-writing AND pure-validation functions already has its own
// dedicated, passing test file (gatewayLogic.test.js, batchMutationLogic.
// test.js, lockLogic.test.js, cutoverLogic.test.js). Re-deriving their
// correctness here would duplicate coverage without adding any. This
// harness's job is index.js's own logic: auth, deriveContext, request-body
// wiring, and -- the one that matters most -- building the HTTP response
// from whatever a lib/ function hands back. Each lib/ module's *pure*
// functions (validateMutationRequest, validateAcquireRequest,
// validateCutoverRequest, buildCutoverMarker, ...) are left REAL (not
// mocked) for exactly the same reason recordMutation's existing tests
// leave GatewayLogic.validateMutationRequest real: they're cheap to run,
// already correct, and exercising them for real here catches any future
// drift in how index.js calls them.
//
// computeAnalysis and provisionMember are different: their logic
// (readAllPaged's pagination, the product/supplier/order lookup-map
// builders, canAssignRole, findOrCreateAuthUser, the provisioning
// transaction) lives directly in index.js itself, in no lib/ file, and had
// no coverage anywhere before this file. For those two, this harness
// provides a small in-memory Firestore substitute (`collection().get()`
// with real orderBy/limit/startAfter cursor semantics, plus
// `runTransaction`) so that logic is exercised for real rather than
// stubbed out -- there is no lower layer to delegate correctness to.

const httpMocks = require("node-mocks-http");

function resolveFromFunctionsRoot(moduleId) {
    return require.resolve(moduleId, { paths: [__dirname + "/../.."] });
}

function installMocks() {
    const adminPath = resolveFromFunctionsRoot("firebase-admin");
    const firestorePath = resolveFromFunctionsRoot("firebase-admin/firestore");
    const gatewayLogicPath = require.resolve("../../lib/gatewayLogic");
    const batchMutationLogicPath = require.resolve("../../lib/batchMutationLogic");
    const lockLogicPath = require.resolve("../../lib/lockLogic");
    const cutoverLogicPath = require.resolve("../../lib/cutoverLogic");

    const mockState = {
        verifyIdToken: async () => { throw new Error("mockState.verifyIdToken not configured for this test"); },
        docs: {}, // path -> plain data object (undefined/missing = "does not exist")
        collections: {}, // path -> [{ id, data }] ordered array, for readAllPaged (computeAnalysis)
        setCalls: [], // { path, data, opts } for every doc.set()/txn.set(), any collection -- assertion aid
        collectionGetCalls: [], // collPath for every collection(...).get() actually executed
        collectionGetError: null, // when set, every collection(...).get() throws this (computeAnalysis 500 path)
        applyMutationResult: null,
        applyDeltaResult: null,
        applyMutationsBatchResult: null,
        acquireLockResult: null,
        acquireLockError: null,
        acquireLockCalls: [],
        releaseLockResult: { ok: true },
        releaseLockError: null,
        releaseLockCalls: [],
        deleteCollectionResult: 0,
        deleteCollectionError: null,
        zeroInventoryStockResult: 0,
        zeroInventoryStockError: null,
        runTransactionError: null, // provisionMember's db.runTransaction() failing
        // admin.auth() extensions needed by provisionMember. Same
        // "throw until configured" default as verifyIdToken above, so a
        // test that forgets to configure one fails loudly, not silently.
        getUserByEmail: async () => { throw Object.assign(new Error("no such user"), { code: "auth/user-not-found" }); },
        getUser: async () => { throw Object.assign(new Error("no such user"), { code: "auth/user-not-found" }); },
        createUser: async () => { throw new Error("mockState.createUser not configured for this test"); }
    };

    function _writeDoc(docPath, data, opts) {
        if (opts && opts.merge && mockState.docs[docPath] !== undefined) {
            mockState.docs[docPath] = Object.assign({}, mockState.docs[docPath], data);
        } else {
            mockState.docs[docPath] = data;
        }
        mockState.setCalls.push({ path: docPath, data: data, opts: opts || null });
    }

    function docRef(docPath) {
        return {
            path: docPath,
            get: async () => {
                const data = mockState.docs[docPath];
                return { exists: data !== undefined, data: () => data };
            },
            set: async (data, opts) => _writeDoc(docPath, data, opts)
        };
    }

    // Minimal query builder covering exactly what readAllPaged (computeAnalysis)
    // needs: .orderBy(...).limit(n) then repeated .startAfter(lastDoc).get()
    // cursor pagination, keyed on doc id (matches readAllPaged's own
    // `lastDoc = snap.docs[snap.docs.length - 1]` / `startAfter(lastDoc)` usage).
    function collectionQuery(collPath, state) {
        return {
            orderBy: () => collectionQuery(collPath, state),
            limit: (n) => collectionQuery(collPath, Object.assign({}, state, { limit: n })),
            startAfter: (afterDoc) => collectionQuery(collPath, Object.assign({}, state, { afterId: afterDoc.id })),
            get: async () => {
                mockState.collectionGetCalls.push(collPath);
                if (mockState.collectionGetError) throw mockState.collectionGetError;
                const all = mockState.collections[collPath] || [];
                let startIdx = 0;
                if (state.afterId !== undefined) {
                    const idx = all.findIndex((d) => d.id === state.afterId);
                    startIdx = idx >= 0 ? idx + 1 : 0;
                }
                const limit = state.limit || all.length;
                const page = all.slice(startIdx, startIdx + limit);
                return {
                    empty: page.length === 0,
                    size: all.length,
                    docs: page.map((d) => ({ id: d.id, data: () => d.data }))
                };
            }
        };
    }

    require.cache[adminPath] = {
        id: adminPath, filename: adminPath, loaded: true,
        exports: {
            initializeApp: () => {},
            app: () => ({}),
            auth: () => ({
                verifyIdToken: (token) => mockState.verifyIdToken(token),
                getUserByEmail: (email) => mockState.getUserByEmail(email),
                getUser: (uid) => mockState.getUser(uid),
                createUser: (opts) => mockState.createUser(opts)
            })
        }
    };

    require.cache[firestorePath] = {
        id: firestorePath, filename: firestorePath, loaded: true,
        exports: {
            getFirestore: () => ({
                doc: docRef,
                collection: (collPath) => collectionQuery(collPath, {}),
                // txn.get/txn.set/txn.delete delegate straight to the same
                // synchronous mockState.docs store docRef() uses -- sufficient
                // for provisionMember's single read-then-write transaction;
                // this mock has no real isolation/rollback semantics.
                runTransaction: async (fn) => {
                    if (mockState.runTransactionError) throw mockState.runTransactionError;
                    const txn = {
                        get: async (ref) => ref.get(),
                        set: (ref, data, opts) => _writeDoc(ref.path, data, opts),
                        delete: (ref) => { delete mockState.docs[ref.path]; }
                    };
                    return fn(txn);
                }
            }),
            FieldValue: { serverTimestamp: () => "MOCK_SERVER_TIMESTAMP" }
        }
    };

    // Real GatewayLogic/BatchMutationLogic/LockLogic/CutoverLogic for their
    // pure validate*/build* exports (already covered by their own test
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
    const realLockLogic = require(lockLogicPath);
    require.cache[lockLogicPath] = {
        id: lockLogicPath, filename: lockLogicPath, loaded: true,
        exports: Object.assign({}, realLockLogic, {
            acquireLock: async (db, params) => {
                mockState.acquireLockCalls.push(params);
                if (mockState.acquireLockError) throw mockState.acquireLockError;
                return mockState.acquireLockResult;
            },
            releaseLock: async (db, params) => {
                mockState.releaseLockCalls.push(params);
                if (mockState.releaseLockError) throw mockState.releaseLockError;
                return mockState.releaseLockResult;
            }
        })
    };
    const realCutoverLogic = require(cutoverLogicPath);
    require.cache[cutoverLogicPath] = {
        id: cutoverLogicPath, filename: cutoverLogicPath, loaded: true,
        exports: Object.assign({}, realCutoverLogic, {
            deleteCollection: async () => {
                if (mockState.deleteCollectionError) throw mockState.deleteCollectionError;
                return mockState.deleteCollectionResult;
            },
            zeroInventoryStock: async () => {
                if (mockState.zeroInventoryStockError) throw mockState.zeroInventoryStockError;
                return mockState.zeroInventoryStockResult;
            }
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
