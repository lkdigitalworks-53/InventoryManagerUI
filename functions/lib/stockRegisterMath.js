"use strict";

// P1 S4a (CGST Rule 56(2)): the stock register read model. Pure module, no Firebase
// dependency. Turns the immutable `stock_movements` ledger into, per product and for one
// period: opening balance, quantity IN and OUT per movement kind, and closing balance.
//
//   opening = sum of signed qty of every row dated BEFORE the period
//   closing = opening + sum of signed qty of the rows INSIDE the period
//   period  = [from, to): `from` inclusive, `to` exclusive, so two back-to-back periods
//             never count one instant twice and never skip one.
//
// The ledger is the source of truth (P1 design D11: every stock change leaves a row, and a
// tenant starts at 0). The register is therefore derived from rows alone; the inventory
// doc's `stock` is only used as a cross-check (`reconciles`), never to compute a balance.
//
// The grouping of kinds into the printed 56(2) columns is deliberately NOT done here: it is
// an open question for the CA (design section 8, S4). This module returns IN and OUT per
// kind and leaves the column layout to the presentation.
//
// Memory is O(products), not O(rows): `createAccumulator` consumes one row at a time so the
// caller can stream the ledger page by page and drop each page.

const Movement = require("./movementLogic");

const EPSILON = 1e-9;
const KINDS = Movement.MOVEMENT_KINDS;
// Roles that may read the register. `staff` is refused: the ledger carries cost values.
const REGISTER_ROLES = ["owner", "admin", "manager"];

// A period bound is either epoch milliseconds or an ISO-8601 instant WITH an offset
// ("2026-04-01T00:00:00+05:30" or "...Z"). An offset-less string is refused on purpose: the
// server would read it as UTC while the phone meant its own local midnight, silently moving
// every boundary by hours.
// Groups: 1 year, 2 month, 3 day, 4 hour, 5 minute, 6 second (optional), 7 zone, 8-9 zone hh:mm.
const ISO_WITH_OFFSET = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,9})?)?(Z|[+-](\d{2}):(\d{2}))$/;
// ECMAScript Date range.
const MAX_MS = 8.64e15;

// Last day of a 1-based month. setUTCFullYear (not Date.UTC) so years 0-99 are not mapped to 19xx.
function daysInMonth(year, month) {
    const d = new Date(0);
    d.setUTCFullYear(year, month, 0);
    return d.getUTCDate();
}

// The shape check above is not enough: Date.parse silently ROLLS an impossible calendar date
// over ("2026-02-30" -> 2 March, "2026-04-31" -> 1 May) and accepts "T24:00:00" as the next
// midnight. For a statutory register a silently moved period boundary is a wrong answer with
// no error, so every field is range-checked and an impossible instant is refused.
function isValidIsoInstant(s) {
    const m = ISO_WITH_OFFSET.exec(s);
    if (!m) return false;
    const year = Number(m[1]);
    const month = Number(m[2]);
    const day = Number(m[3]);
    const second = m[6] === undefined ? 0 : Number(m[6]);
    if (month < 1 || month > 12) return false;
    if (day < 1 || day > daysInMonth(year, month)) return false;
    if (Number(m[4]) > 23 || Number(m[5]) > 59 || second > 59) return false;
    if (m[8] !== undefined && (Number(m[8]) > 23 || Number(m[9]) > 59)) return false;
    return true;
}

function canViewRegister(role) {
    return REGISTER_ROLES.indexOf(role) >= 0;
}

function round9(x) {
    const r = Math.round(x * 1e9) / 1e9;
    return r === 0 ? 0 : r; // normalise -0
}

// Epoch ms from the shapes a stored timestamp can take (Firestore Timestamp, Date, ISO
// string, epoch ms, plain {seconds, nanoseconds} / {_seconds, _nanoseconds}). NaN when the
// value is none of them.
function toMillis(ts) {
    if (ts === null || ts === undefined) return NaN;
    if (typeof ts === "number") return isFinite(ts) ? ts : NaN;
    if (typeof ts === "string") return isValidIsoInstant(ts) ? Date.parse(ts) : NaN;
    if (ts instanceof Date) return ts.getTime();
    if (typeof ts !== "object") return NaN;
    if (typeof ts.toMillis === "function") {
        const ms = ts.toMillis();
        return typeof ms === "number" ? ms : NaN;
    }
    if (typeof ts.toDate === "function") {
        const d = ts.toDate();
        return d instanceof Date ? d.getTime() : NaN;
    }
    const sec = typeof ts.seconds === "number" ? ts.seconds : ts._seconds;
    const nano = typeof ts.nanoseconds === "number" ? ts.nanoseconds : ts._nanoseconds;
    if (typeof sec === "number" && isFinite(sec)) {
        return sec * 1000 + Math.floor((typeof nano === "number" && isFinite(nano) ? nano : 0) / 1e6);
    }
    return NaN;
}

// One period bound from a request. Returns epoch ms or NaN.
function parseBound(value) {
    if (typeof value === "number") {
        return (isFinite(value) && Math.abs(value) <= MAX_MS) ? value : NaN;
    }
    if (typeof value === "string") {
        const ms = toMillis(value);
        return (isFinite(ms) && Math.abs(ms) <= MAX_MS) ? ms : NaN;
    }
    return NaN;
}

// { ok: true, fromMs, toMs } or { ok: false, error: "invalid-window" }. `from` must be before `to`.
function parseWindow(from, to) {
    const fromMs = parseBound(from);
    const toMs = parseBound(to);
    if (!isFinite(fromMs) || !isFinite(toMs) || fromMs >= toMs) return { ok: false, error: "invalid-window" };
    return { ok: true, fromMs: fromMs, toMs: toMs };
}

function emptyKinds() {
    const out = {};
    for (const k of KINDS) out[k] = { in: 0, out: 0 };
    return out;
}

function emptyProduct() {
    // nameAt/name: the name on the LATEST row (by time) that carries one; equal times keep the greater name
    // so the answer never depends on the order the ledger pages arrive in.
    return { opening: 0, windowNet: 0, ledger: 0, count: 0, kinds: emptyKinds(), nameAt: -Infinity, name: null };
}

// win: { fromMs, toMs } from parseWindow. Feed every ledger row to add(); call finish() once
// with the inventory docs. Rows that cannot be classified are skipped, counted in
// `skipped` and never silently folded into a balance.
function createAccumulator(win) {
    const perProduct = Object.create(null);
    const skipped = { noProduct: 0, badKind: 0, badQty: 0, badTime: 0 };
    let rowsSeen = 0;
    let rowsInWindow = 0;

    function add(row) {
        rowsSeen += 1;
        if (!row || typeof row !== "object" || typeof row.productId !== "string" || row.productId === "") {
            skipped.noProduct += 1;
            return;
        }
        if (KINDS.indexOf(row.kind) < 0) { skipped.badKind += 1; return; }
        const qty = row.qty;
        if (typeof qty !== "number" || !isFinite(qty) || qty === 0) { skipped.badQty += 1; return; }
        // The server never writes a row against its kind's direction (D4). One found here is
        // corruption: leave it out of every balance and let the cross-check expose the gap.
        const direction = Movement.KIND_DIRECTION[row.kind];
        if (direction !== 0 && Math.sign(qty) !== direction) { skipped.badQty += 1; return; }
        const t = toMillis(row.serverTimestamp);
        if (!isFinite(t)) { skipped.badTime += 1; return; }

        let acc = perProduct[row.productId];
        if (!acc) { acc = emptyProduct(); perProduct[row.productId] = acc; }
        acc.ledger += qty;
        acc.count += 1;
        const rowName = Movement.cleanProductName(row.productName);
        if (rowName !== undefined && (t > acc.nameAt || (t === acc.nameAt && rowName > acc.name))) {
            acc.nameAt = t;
            acc.name = rowName;
        }
        if (t < win.fromMs) {
            acc.opening += qty;
        } else if (t < win.toMs) {
            acc.windowNet += qty;
            rowsInWindow += 1;
            const bucket = acc.kinds[row.kind];
            if (qty > 0) bucket.in += qty; else bucket.out += -qty;
        }
        // t >= toMs: only the ledger total (for the cross-check) moves.
    }

    // products: inventory docs ({ productId, name, stock, ... }); duplicates keep the first.
    function finish(products) {
        const inv = Object.create(null);
        for (const p of (products || [])) {
            if (p && typeof p.productId === "string" && p.productId !== "" && !inv[p.productId]) inv[p.productId] = p;
        }

        const ids = Object.create(null);
        for (const id of Object.keys(perProduct)) ids[id] = true;
        // A product that holds stock but has no ledger row at all must show up: it is exactly
        // the kind of hole a register exists to expose.
        for (const id of Object.keys(inv)) {
            if (Math.abs(Movement.stockOf(inv[id])) > EPSILON) ids[id] = true;
        }

        const rows = [];
        let mismatches = 0;
        for (const id of Object.keys(ids)) {
            const acc = perProduct[id] || emptyProduct();
            const doc = inv[id];
            const currentStock = doc ? Movement.stockOf(doc) : 0;
            const reconciles = Math.abs(acc.ledger - currentStock) <= EPSILON * Math.max(1, acc.count);
            if (!reconciles) mismatches += 1;

            let inTotal = 0;
            let outTotal = 0;
            const kinds = {};
            for (const k of KINDS) {
                kinds[k] = { in: round9(acc.kinds[k].in), out: round9(acc.kinds[k].out) };
                inTotal += acc.kinds[k].in;
                outTotal += acc.kinds[k].out;
            }
            rows.push({
                productId: id,
                name: (doc && typeof doc.name === "string") ? doc.name : acc.name,
                deleted: !doc,
                opening: round9(acc.opening),
                kinds: kinds,
                inTotal: round9(inTotal),
                outTotal: round9(outTotal),
                closing: round9(acc.opening + acc.windowNet),
                currentStock: round9(currentStock),
                ledgerStock: round9(acc.ledger),
                reconciles: reconciles,
                movementCount: acc.count
            });
        }

        rows.sort(function (a, b) {
            // Named products first (case-insensitive), deleted ones after, id as the tie-break.
            if ((a.name === null) !== (b.name === null)) return a.name === null ? 1 : -1;
            const an = (a.name || "").toLowerCase();
            const bn = (b.name || "").toLowerCase();
            if (an !== bn) return an < bn ? -1 : 1;
            return a.productId < b.productId ? -1 : (a.productId > b.productId ? 1 : 0);
        });

        return {
            kinds: KINDS.slice(),
            products: rows,
            counts: {
                products: rows.length,
                rowsSeen: rowsSeen,
                rowsInWindow: rowsInWindow,
                mismatches: mismatches,
                skipped: Object.assign({}, skipped)
            }
        };
    }

    return { add: add, finish: finish };
}

// Convenience for tests and small inputs: the whole ledger in memory.
function buildRegister(movements, products, win) {
    const acc = createAccumulator(win);
    for (const m of (movements || [])) acc.add(m);
    return acc.finish(products);
}

module.exports = {
    REGISTER_ROLES, KINDS, EPSILON,
    canViewRegister, toMillis, parseWindow, createAccumulator, buildRegister, round9
};
