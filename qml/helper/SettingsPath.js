.pragma library

// Resolves the fileName override Settings (QtCore) needs when
// QCoreApplication's organization identifier hasn't been set -- which is
// always true under qmltestrunner (a generic Qt-provided binary; this app's
// own main.cpp is never entered under it, so FelgoApplication::initialize()
// never runs and never sets Application.organization). Without an override,
// Settings falls back to QSettings' default-constructor resolution, which
// requires that identifier and otherwise logs an "empty key" warning and
// no-ops every property write -- meaning a Settings-backed store's
// persistence goes silently untested by qmltestrunner, every run, always
// has. (Concretely: AuthStore's session and OutboxStore's queue -- the
// entire reason OutboxStore exists is durability across a relaunch.)
//
// Real app builds (Felgo sets Application.organization during
// felgo.initialize(), before Main.qml even loads) always take the untouched
// default-resolution path -- this returns "" for them, identical to leaving
// fileName unset. Real user data's on-disk location is governed entirely by
// whatever Felgo/QCoreApplication already resolves; this function changes
// nothing about it. Only a harness that skips that init path (qmltestrunner,
// or any future headless runner) falls through to the explicit temp-file
// path below.
//
// `orgName`/`tempDir` are passed in rather than queried here so this stays
// pure and unit-testable without a live QCoreApplication/QQmlEngine --
// callers pass Application.organization and
// StandardPaths.writableLocation(StandardPaths.TempLocation).
//
// One shared file, not one per store: mirrors production, where every store
// using this pattern already resolves to the SAME default QSettings file,
// differentiated only by each Settings block's own `category`.
function settingsFileNameOverride(orgName, tempDir) {
    if (orgName && orgName.length > 0) {
        return "" // real app: untouched, defer to normal QSettings resolution
    }
    return tempDir + "/InventoryManagerUI-qmltestrunner-settings.ini"
}
