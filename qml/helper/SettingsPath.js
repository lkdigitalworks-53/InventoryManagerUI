.pragma library

// Resolves the `location` override the QtCore `Settings` type needs when
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
// CORRECTED 2026-08-18: this originally targeted a property called
// `fileName` (string). That property belongs to the OLD, deprecated
// `Qt.labs.settings` Settings type -- this app imports `QtCore`'s Settings
// (Qt 6.5+), whose equivalent property is `location` (url), not `fileName`.
// Confirmed via a real qmltestrunner run (Qt 6.8.3): "Cannot assign to
// non-existent property 'fileName'" at PartyStore.qml, which cascaded into
// 14 failing test files, since one QML singleton failing to compile breaks
// the whole qmldir module for everything that transitively imports it. This
// was the exact assumption flagged as unverified needing a real build to
// confirm -- now confirmed wrong, and fixed for real. See SKILLS Skill 41.
//
// Real app builds (Felgo sets Application.organization during
// felgo.initialize(), before Main.qml even loads) always take the untouched
// default-resolution path -- this returns "" for them, identical to leaving
// `location` unset (per QtCore's own docs: "If this property is empty (the
// default), then QSettings::defaultFormat() will be used."). Real user
// data's on-disk location is governed entirely by whatever Felgo/
// QCoreApplication already resolves; this function changes nothing about
// it. Only a harness that skips that init path (qmltestrunner, or any
// future headless runner) falls through to the explicit temp-file path
// below.
//
// `orgName`/`tempDir` are passed in rather than queried here so this stays
// pure and unit-testable without a live QCoreApplication/QQmlEngine --
// callers pass Application.organization and
// StandardPaths.writableLocation(StandardPaths.TempLocation) (already a
// `url`, per QtCore's StandardPaths -- string concatenation below coerces
// it via toString(), producing another valid URL string, which QML accepts
// for a url-typed property the same way it accepts a plain string for one).
//
// One shared file, not one per store: mirrors production, where every store
// using this pattern already resolves to the SAME default QSettings file,
// differentiated only by each Settings block's own `category`.
function settingsLocationOverride(orgName, tempDir) {
    if (orgName && orgName.length > 0) {
        return "" // real app: untouched, defer to normal QSettings resolution
    }
    return tempDir + "/InventoryManagerUI-qmltestrunner-settings.ini"
}
