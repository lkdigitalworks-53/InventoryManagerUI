"use strict";

// Maps an exception thrown by a Firestore write to the `error` string the client
// reads. The HTTP status stays 500 on purpose: Gateway's delta and operation
// senders treat ANY 4xx with an ok:false body as a definitive decision and drop
// the write, so a 4xx here would make the client drop. Only the body differs.
//
//   write-rejected     retrying the same write can never succeed (rules, bad
//                      payload, missing index, missing/existing doc)
//   write-unavailable  worth retrying (outage, timeout, quota, contention)
//   write-failed       anything else (unknown, non-Firestore) -- the old value
//
// Admin SDK errors carry the gRPC status as a number; some paths use the string
// form, so both are matched. Design:
// docs/superpowers/specs/2026-09-28-gateway-write-error-classification-design.md

const REJECTED = "write-rejected";
const UNAVAILABLE = "write-unavailable";
const UNKNOWN = "write-failed";

// gRPC numeric codes -> Firestore string codes
//   terminal:  3 invalid-argument, 5 not-found, 6 already-exists,
//              7 permission-denied, 9 failed-precondition
//   transient: 4 deadline-exceeded, 8 resource-exhausted, 10 aborted,
//              13 internal, 14 unavailable
const TERMINAL = new Set([3, 5, 6, 7, 9, "invalid-argument", "not-found", "already-exists", "permission-denied", "failed-precondition"]);
const TRANSIENT = new Set([4, 8, 10, 13, 14, "deadline-exceeded", "resource-exhausted", "aborted", "internal", "unavailable"]);

function classifyWriteError(e) {
    const code = e && e.code;
    if (TERMINAL.has(code)) return REJECTED;
    if (TRANSIENT.has(code)) return UNAVAILABLE;
    return UNKNOWN;
}

module.exports = { classifyWriteError, REJECTED, UNAVAILABLE, UNKNOWN };
