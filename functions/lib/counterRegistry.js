"use strict";

// Server-side mirror of the client's id counters, for the `mint` op of recordOperation.
// Design: docs/superpowers/specs/2026-10-28-r2-mint-engine-design.md (M1-M4).
//
// A counter doc lives at tenants/<t>/counters/<counterName> and holds one number, `value`: the
// last id number handed out. The client mints from the SAME doc over REST
// (FirebaseService.mintCounterValue), so the formats below must match the stores byte for byte;
// test/counterRegistry.guard.test.js reads the QML sources and fails on drift.
//
// Only the counters restock needs are registered (M1). A later consumer adds one entry here and
// one row in the guard test. Pure: no Firebase dependency.

// M3: the app is INR / en-IN throughout, so the year in a batch id is the calendar year in India.
const COUNTER_TIME_ZONE = "Asia/Kolkata";

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

// The number inside `id` when it is exactly prefix + digits, else null. Numeric, never lexical:
// "SUP-1000" is a bigger number than "SUP-999" although it sorts lower as a string.
function numberOf(prefix, id) {
    if (typeof id !== "string" || id.indexOf(prefix) !== 0) return null;
    const tail = id.substring(prefix.length);
    if (!/^[0-9]+$/.test(tail)) return null;
    const n = parseInt(tail, 10);
    return Number.isSafeInteger(n) ? n : null;
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

// A counter doc's `value` is usable only when it is a whole number >= 0. Anything else (a string,
// a float, a negative, missing) is treated as damaged and the counter is re-seeded from the ids.
function usableCount(value) {
    return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

module.exports = { COUNTER_TIME_ZONE, REGISTRY, isKnownCounter, yearFor, describe, formatId,
                   numberOf, maxNumber, usableCount };
