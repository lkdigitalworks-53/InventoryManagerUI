.pragma library

// Build-time environment resolution. PRODUCT_STAGE (CMake) → app stage string,
// surfaced to QML as the APP_STAGE context property, mapped here to an env and
// the Firestore database id. Pure + headless-testable (tests/tst_EnvConfig.qml).
//
// Mapping:                       fail-safe: unknown/empty stage → "prd" so a
//   dev     → dev   db dev       misconfigured/unflagged build talks to the real
//   test    → test  db test      production (default) database, never silently to
//   publish → prd   db (default) an empty dev database.

function envForStage(stage) {
    var s = (stage === undefined || stage === null) ? "" : String(stage)
    if (s === "dev")     return "dev"
    if (s === "test")    return "test"
    if (s === "publish") return "prd"
    return "prd"
}

function databaseIdForEnv(env) {
    return env === "prd" ? "(default)" : env
}

function databaseIdForStage(stage) {
    return databaseIdForEnv(envForStage(stage))
}
