"use strict";

// CORS-tagged JSON response helper for the P0 compliance gateway's HTTPS
// handlers. Zero Firebase SDK dependency of its own — `res` is passed in by
// the caller (index.js), same extraction pattern as cutoverLogic.js /
// gatewayLogic.js, done specifically so the try/catch below (added in the
// E2E testing phase 2 followup, thirteenth-round session) has direct unit
// coverage instead of only being reachable through a live HTTPS request.
//
// The try/catch is a safety net, not a proven fix for any specific bug:
// res.json() calls JSON.stringify() internally, completely unguarded before
// this existed. If a response body ever contains something JSON.stringify
// can't handle (a circular reference, a BigInt, etc.), that throws
// synchronously inside this function. Uncaught, that could leave the
// connection in a half-sent state (headers already written, body never
// finished) — something a client-side XHR could plausibly report as a bare
// connection failure. This turns that into a logged, diagnosable 500
// instead.
function send(res, status, body) {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
    try {
        res.status(status).json(body);
    } catch (e) {
        console.error("send() failed to serialize response body", { status: status, error: String(e), bodyKeys: body ? Object.keys(body) : null });
        if (!res.headersSent) {
            res.status(500).json({ ok: false, error: "response-serialization-failed" });
        }
    }
}

module.exports = { send };
