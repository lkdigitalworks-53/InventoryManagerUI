"use strict";

// Server-side mirror of the client's id counters, for the `mint` op of recordOperation.
// Design: docs/superpowers/specs/2026-10-28-r2-mint-engine-design.md (M1-M4).
//
// A counter doc lives at tenants/<t>/counters/<counterName> and holds one number, `value`: the
// last id number handed out. The client mints from the SAME doc over REST
// (FirebaseService.mintCounterValue), so the formats below must match the stores byte for byte;
// test/counterRegistry.guard.test.js reads the QML sources and fails on drift.
//
// Only the counters a consumer needs are registered (M1): restock (supplier, stock_batch), add product (product).
// A later consumer adds one entry here and one row in the guard test. Pure: no Firebase dependency.

// M3: the app is INR / en-IN throughout, so the year in a batch id is the calendar year in India.
const COUNTER_TIME_ZONE = "Asia/Kolkata";

// M16: the largest id number the server will trust or hand out. Nine digits is far beyond any real tenant
// and far below 2^53, where `n + 1 === n` and a parsed id is no longer the id that was written: a counter
// hand-set to 2^53 - 1 (the client may write `counters`) minted one id, then the same "next" id for ever
// (409 mint-exhausted on every restock of that tenant, and the heal could not see ids it cannot parse).
// A value or an id above this is treated as damaged / not a counter id, so the counter re-seeds from sane ids.
const MAX_COUNTER = 999999999;

// registry key (what a client sends as `counter`) -> where the id lives and how it is written.
const REGISTRY = {
    supplier: {
        entity: "supplier",
        collection: "suppliers",
        counterName: function () { return "suppliers"; },
        prefix: function () { return "SUP-"; }
    },
    stock_batch: {
        entity: "stock_batch",
        collection: "stock_batches",
        counterName: function (year) { return "stockBatches-" + year; },
        prefix: function (year) { return "BAT-" + year + "-"; }
    },
    // AP1 (design 2026-11-13-add-product-atomic-operation-design.md D-AP-3): InventoryStore.nextProductId mints
    // `counters/products` and writes 'PRD-' + the number padded to 3 digits. The id is the inventory doc id.
    product: {
        entity: "inventory",
        collection: "inventory",
        counterName: function () { return "products"; },
        prefix: function () { return "PRD-"; }
    }
};

function isKnownCounter(key) {
    return typeof key === "string" && Object.prototype.hasOwnProperty.call(REGISTRY, key);
}

// Calendar year (4 digits, as a string) of `date` in COUNTER_TIME_ZONE.
function yearFor(date) {
    const y = new Intl.DateTimeFormat("en-CA", { timeZone: COUNTER_TIME_ZONE, year: "numeric" }).format(date);
    if (!/^[0-9]{4}$/.test(y)) throw new Error("counterRegistry: unexpected year " + y);
    return y;
}

// { key, entity, collection, counterName, prefix } for a registry key and a year, or null.
function describe(key, year) {
    if (!isKnownCounter(key)) return null;
    const r = REGISTRY[key];
    return { key: key, entity: r.entity, collection: r.collection,
             counterName: r.counterName(year), prefix: r.prefix(year) };
}

// Same as the stores: prefix + the number left-padded to 3 digits. padStart never truncates, so
// 1000 gives "SUP-1000", exactly like `String(value).padStart(3, '0')` in QML.
function formatId(prefix, n) {
    return prefix + String(n).padStart(3, "0");
}

// The number inside `id` when it is exactly prefix + digits and at most MAX_COUNTER, else null. Numeric,
// never lexical: "SUP-1000" is a bigger number than "SUP-999" although it sorts lower as a string.
function numberOf(prefix, id) {
    if (typeof id !== "string" || id.indexOf(prefix) !== 0) return null;
    const tail = id.substring(prefix.length);
    if (!/^[0-9]+$/.test(tail)) return null;
    const n = parseInt(tail, 10);
    return n <= MAX_COUNTER ? n : null;
}

// Highest number among `ids` for `prefix` (0 when none): the seed for a counter that has no doc.
function maxNumber(prefix, ids) {
    let max = 0;
    for (const id of ids) {
        const n = numberOf(prefix, id);
        if (n !== null && n > max) max = n;
    }
    return max;
}

// A counter doc's `value` is usable only when it is a whole number from 0 to MAX_COUNTER. Anything else
// (a string, a float, a negative, missing, above the ceiling) is treated as damaged and the counter is
// re-seeded from the ids.
function usableCount(value) {
    return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= MAX_COUNTER;
}

module.exports = { COUNTER_TIME_ZONE, MAX_COUNTER, isKnownCounter, yearFor, describe, formatId,
                   numberOf, maxNumber, usableCount };
