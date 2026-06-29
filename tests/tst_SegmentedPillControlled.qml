import QtQuick
import QtTest

// DECISIVE EXPERIMENT for "swiping Analysis reports changes the view but the
// header highlight stays stuck on the old segment".
//
// SalesPage binds the SegmentedPill's highlight to backing state:
//     SegmentedPill { selected: root._viewMode; onSegmentSelected: root._viewMode = idx }
// A swipe steps root._viewMode WITHOUT touching the pill (the "external change"
// path). A tap goes through onSegmentSelected, which also updates _viewMode.
//
// The bug: the old SegmentedPill did `root.selected = index` in its MouseArea
// onClicked. That imperative self-write DESTROYS the parent's `selected:` binding
// the first time anything is tapped, freezing `selected` as a plain value. After
// that, swiping moves _viewMode but `selected` no longer tracks it → highlight
// stuck. Taps still moved it (direct write), which is exactly the asymmetry seen.
//
// The fix makes SegmentedPill a pure CONTROLLED component: its MouseArea only
// emits segmentSelected; the parent owns `selected`. This test reproduces both
// the buggy self-write and the fixed emit-only contract on the same backing state.
TestCase {
    id: tc
    name: "SegmentedPillControlled"

    property int viewMode: 0   // stand-in for SalesPage.root._viewMode

    // Stand-in pill: `selected` is bound to tc.viewMode (the real SalesPage
    // construct). `buggySelfWrite` toggles the historic clobbering behaviour.
    Component {
        id: pillComp
        Item {
            property bool buggySelfWrite: false
            property int selected: tc.viewMode           // the parent's binding
            signal segmentSelected(int index)
            // Tap handler — mirrors SegmentedPill's MouseArea onClicked.
            function tap(index) {
                if (buggySelfWrite) selected = index     // OLD: breaks the binding
                segmentSelected(index)
            }
            onSegmentSelected: function(index) { tc.viewMode = index }
        }
    }

    // The FIXED component: emit-only. A swipe (external viewMode change) must
    // still move the highlight even after the user has tapped a segment.
    function test_controlled_pill_tracks_swipe_after_tap() {
        tc.viewMode = 0
        var pill = pillComp.createObject(tc, { buggySelfWrite: false })
        compare(pill.selected, 0, "starts on segment 0")

        pill.tap(4)                       // user taps "Sold"
        compare(tc.viewMode, 4, "tap updates backing state")
        compare(pill.selected, 4, "highlight follows the tap")

        tc.viewMode = 3                   // SWIPE to "Revenue" — external change
        compare(pill.selected, 3,
                "highlight MUST follow a swipe even after a prior tap")
        pill.destroy()
    }

    // Guards the root cause: an imperative self-write freezes the highlight, so a
    // later swipe is ignored. If someone reintroduces `selected = index`, this
    // documents why it breaks.
    function test_self_write_breaks_external_tracking() {
        tc.viewMode = 0
        var pill = pillComp.createObject(tc, { buggySelfWrite: true })

        pill.tap(4)                       // self-write clobbers the binding here
        compare(pill.selected, 4, "tap still moves it (direct write)")

        tc.viewMode = 3                   // swipe — binding is dead now
        compare(pill.selected, 4,
                "self-write froze the highlight: swipe is ignored (the bug)")
        pill.destroy()
    }
}
