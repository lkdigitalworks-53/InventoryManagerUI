.pragma library

// Build-time environment resolution. PRODUCT_STAGE (CMake) → app stage string,
// surfaced to QML as the APP_STAGE context property, mapped here to an env and
// the Firestore database id. Pure + headless-testable (tests/tst_EnvConfig.qml).
//
// Mapping:                       fail-safe: unknown/empty stage → "prd" so a
//   dev     → dev   db dev1      misconfigured/unflagged build talks to the real
//   test    → test  db test      production (default) database, never silently to
//   publish → prd   db (default) an empty dev database.
//
// NOTE: the "dev" Firestore database is named "dev1", not "dev" — Firestore
// requires database IDs to be >=4 characters, so the 3-char "dev" is invalid.
// The env name (stage/env string) stays "dev"; only the underlying database
// id differs. See README.md "Environments" section.

function envForStage(stage) {
    var s = (stage === undefined || stage === null) ? "" : String(stage)
    if (s === "dev")     return "dev"
    if (s === "test")    return "test"
    if (s === "publish") return "prd"
    return "prd"
}

function databaseIdForEnv(env) {
    if (env === "prd") return "(default)"
    if (env === "dev") return "dev1"
    return env
}

function databaseIdForStage(stage) {
    return databaseIdForEnv(envForStage(stage))
}
