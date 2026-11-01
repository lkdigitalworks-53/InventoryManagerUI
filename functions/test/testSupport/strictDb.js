"use strict";

// Strict in-memory Firestore fake for transaction tests (same rules as the one in
// movementStrict.test.js, shared here for the S1b tests): throws on an `undefined`
// field value, on a document path with an odd segment count or an empty segment, and
// on a read after a write inside a transaction. `TS` stands in for serverTimestamp().

const TS = { __transform: "serverTimestamp" };

function findUndefined(value, path) {
    if (value === undefined) return path;
    if (value === null || typeof value !== "object" || value === TS) return null;
    for (const k of Object.keys(value)) {
        const hit = findUndefined(value[k], path + "." + k);
        if (hit) return hit;
    }
    return null;
}

function strictDb(docs) {
    const store = Object.assign({}, docs || {});
    const writes = [];
    const listCalls = [];
    return {
        store, writes, listCalls,
        // Admin SDK CollectionReference#listDocuments(): the direct children (ids only) of a collection.
        collection(path) {
            return {
                async listDocuments() {
                    listCalls.push(path);
                    return Object.keys(store)
                        .filter((k) => k.indexOf(path + "/") === 0 && k.indexOf("/", path.length + 1) < 0)
                        .map((k) => ({ id: k.substring(path.length + 1), path: k }));
                }
            };
        },
        doc(path) {
            const seg = path.split("/");
            if (seg.length % 2 !== 0 || seg.some((s) => s === "")) throw new Error("bad document path: " + path);
            return { path };
        },
        async runTransaction(fn) {
            let wrote = false;
            return fn({
                async get(ref) {
                    if (wrote) throw new Error("read after write: " + ref.path);
                    const has = Object.prototype.hasOwnProperty.call(store, ref.path);
                    return { exists: has, data: () => (has ? store[ref.path] : undefined) };
                },
                set(ref, data) {
                    const bad = findUndefined(data, "");
                    if (bad) throw new Error("undefined field value at " + ref.path + bad);
                    wrote = true;
                    writes.push({ path: ref.path, data });
                    store[ref.path] = data;
                },
                delete(ref) { wrote = true; writes.push({ path: ref.path, deleted: true }); delete store[ref.path]; }
            });
        }
    };
}

// Pessimistic count: every doc is one write, plus one more per serverTimestamp sentinel.
function pessimisticWrites(writes) {
    let n = 0;
    for (const w of writes) {
        n += 1;
        if (w.data) for (const k of Object.keys(w.data)) if (w.data[k] === TS) n += 1;
    }
    return n;
}

const rowsOf = (db) => db.writes.filter((w) => w.path.indexOf("/stock_movements/") >= 0);

module.exports = { TS, strictDb, pessimisticWrites, rowsOf };
