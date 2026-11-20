.pragma library

// The app's Android Back router for the dialog stack (Main.qml _handleBack), as a pure function so the order of
// its rules is testable headless (Skill 83; Main.qml cannot be loaded by qmltestrunner). Picker v2, slice S5c.
// Tests: functions/test/backRouter.test.js, tests/tst_BackRouter.qml.
//
// `dialogs` is the Back list, in Back-press order; entries may be null. The first OPEN one decides:
//   busy                         -> "swallowed" (a request is in flight; nothing else may react to Back)
//   it has consumeBack() -> true -> "consumed"  (it holds a guarded child, for example the product picker sheet
//                                   with a draft, and handled Back itself; the dialog stays open)
//   otherwise                    -> close() it, "closed" (exactly the old behaviour)
// No entry open -> "none": the caller carries on (overlays, tabs, double-tap exit).
//
// consumeBack is optional. If it throws, or answers anything but true, the dialog is closed as before: a broken
// hook must never leave the person with a Back key that does nothing.
function route(dialogs) {
    var list = Array.isArray(dialogs) ? dialogs : []
    for (var i = 0; i < list.length; ++i) {
        var d = list[i]
        if (!d || !d.opened) continue
        if (d.busy) return "swallowed"
        if (typeof d.consumeBack === "function") {
            var consumed = false
            try { consumed = d.consumeBack() === true } catch (e) { consumed = false }
            if (consumed) return "consumed"
        }
        d.close()
        return "closed"
    }
    return "none"
}
