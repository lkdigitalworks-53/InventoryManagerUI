// PHASE 2 SPIKE PROBE -- run manually, not part of any automated suite.
//
// Question this answers: do Felgo's dp()/sp() and the app's Constants
// singleton resolve correctly when there's no App{} ancestor in scope --
// which is exactly the situation qmltestrunner puts any component in, since
// it never wraps test content in this app's Main.qml/App{} root. This
// gates whether NewOrderDialog.qml/OrderDetailDialog.qml (both use
// dp()/sp()/Constants throughout -- see e.g. NewOrderDialog.qml's
// `spacing: dp(Constants.space3)`) can be headlessly component-tested at
// all, or whether that's a dead end.
//
// Deliberately NOT a pass/fail test: nobody knows the correct outcome yet,
// that's the whole point. It only logs, and always reports as "passed" in
// qmltestrunner's output regardless of what it finds -- the value is
// entirely in the console output below, not in a green/red result. Do not
// interpret a "PASS" here as "dp() works"; read the actual logged lines.
//
// HOW TO RUN (pick whichever works in your setup):
//   qmltestrunner -input scripts/probes -platform offscreen
// or, pointed at a throwaway directory containing only this file, if the
// above also picks up something unexpected from other files nearby:
//   qmltestrunner -input <path-to-just-this-file's-directory> -platform offscreen
//
// Then paste back everything printed between the "=== PROBE OUTPUT ===" and
// "=== END PROBE OUTPUT ===" markers below -- that's all that's needed to
// close out the Phase 2 decision, not the qmltestrunner pass/fail summary.

import QtQuick
import QtTest
import "../../qml/helper" // Constants (singleton, see qml/helper/qmldir)

TestCase {
    id: tc
    name: "Phase2DpSpAppRootProbe"

    function _logResult(label, fn) {
        console.log("PROBE: " + label + " -- attempting...")
        try {
            var value = fn()
            console.log("PROBE: " + label + " -- NO EXCEPTION, value = " + JSON.stringify(value) +
                         ", typeof = " + typeof value)
        } catch (e) {
            console.log("PROBE: " + label + " -- THREW: " + e.toString())
        }
    }

    function test_probe_dp_sp_constants_outside_app_root() {
        console.log("=== PROBE OUTPUT ===")

        // 1. Bare existence check -- is `dp`/`sp` even a name in scope at all,
        //    before worrying about what it returns.
        console.log("PROBE: typeof dp = " + typeof dp)
        console.log("PROBE: typeof sp = " + typeof sp)
        console.log("PROBE: typeof Constants = " + typeof Constants)

        // 2. Imperative calls, wrapped in try/catch -- cleanest signal, since
        //    this runs as plain JS at Component.onCompleted-equivalent time
        //    (TestCase's own function body), not as a declarative binding.
        _logResult("dp(16) imperative", function() { return dp(16) })
        _logResult("sp(16) imperative", function() { return sp(16) })
        _logResult("Constants.space3 imperative", function() { return Constants.space3 })

        // 3. Declarative binding usage -- how the real dialogs actually use
        //    it (e.g. `spacing: dp(Constants.space3)`), on a plain Item with
        //    NO App{} ancestor anywhere in its parent chain. A declarative
        //    binding error surfaces differently than a JS exception (often a
        //    console warning from the engine itself, with the property left
        //    undefined/0 rather than something try/catch here can see) --
        //    that's exactly why this is logged separately from case 2, not
        //    assumed to behave the same way.
        var declarativeProbe = Qt.createQmlObject(
            'import QtQuick 2.15\n' +
            'Item {\n' +
            '    property real probedWidth: dp(16)\n' +
            '    property real probedFontSize: sp(16)\n' +
            '}',
            tc, "DeclarativeProbe")
        if (declarativeProbe) {
            console.log("PROBE: declarative Item created OK")
            console.log("PROBE: declarative probedWidth = " + declarativeProbe.probedWidth)
            console.log("PROBE: declarative probedFontSize = " + declarativeProbe.probedFontSize)
            declarativeProbe.destroy()
        } else {
            console.log("PROBE: declarative Item creation returned null/failed " +
                         "(check stderr above this line for the QML engine's own error -- " +
                         "Qt.createQmlObject failures often log there, not via a JS exception)")
        }

        // 4. Same declarative check again, but via Qt.createComponent +
        //    createObject instead of Qt.createQmlObject's inline string --
        //    a different QML API path, included in case the two report the
        //    scope-resolution failure differently (worth knowing either way,
        //    not assumed to be identical).
        var comp = Qt.createComponent("probe_declarative_helper.qml")
        if (comp.status === Component.Ready) {
            var obj = comp.createObject(tc)
            if (obj) {
                console.log("PROBE: createComponent Item created OK, probedWidth = " + obj.probedWidth)
                obj.destroy()
            } else {
                console.log("PROBE: createComponent createObject() returned null")
            }
        } else {
            console.log("PROBE: createComponent status = " + comp.status +
                         ", errorString = " + comp.errorString())
        }

        console.log("=== END PROBE OUTPUT ===")

        // Always "passes" -- see the header comment. This isn't asserting
        // anything is correct; it's asserting the probe itself ran to
        // completion without qmltestrunner aborting the whole file.
        verify(true)
    }
}
