import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"
import "../helper/StockRegisterPage.js" as Glue

// Stock register (CGST Rule 56(2)): opening, in, out and closing per product for a chosen period. P1 S4b-2.
// PAINTING ONLY. Every decision lives in qml/helper/StockRegisterPage.js (this page) and StockRegisterModel.js
// (the engine), both tested headless (Skill 161 rule 1); this file cannot be loaded by qmltestrunner (Felgo), so
// its wiring is pinned by .github/scripts/__tests__/stockRegisterPageWiring.test.js and checked on a device
// (test plan 2026-11-20-p1-s4b2-register-page-test-plan.md).
// Design: docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md sections 5 and 8.
//
// Rules this file keeps:
//  * ON DEMAND ONLY (D9): a tap on the load button is the only thing that reads the ledger. A chip tap shows the
//    service's remembered answer for that period when it has one, and nothing otherwise.
//  * The service's own `loading` flag is the single latch (Skill 155 rule 1): no second flag here.
//  * The page keeps its state when it is closed and reopened (a running load keeps running, its answer is
//    remembered); it resets, cancelling a running load, when the workspace or the role changes.
Item {
    id: root

    signal backRequested()

    // Main passes app.isOnline (the same value GlassHeader reads).
    property bool isOnline: true

    // ---- state the page owns (design section 5) -----------------------------------------------------------
    property int chipIndex: 0
    property string fromText: ""
    property string toText: ""
    property bool showAll: false
    property string expandedId: ""

    // The page state (Glue.initialState shape), copied into properties so bindings are simple.
    property string status: "idle"            // idle | ok | error
    property string errorText: ""
    property bool errorRetryable: true
    property var summary: null
    property var shownWin: null               // the window the shown answer is for (null unless status is ok)
    property var _body: null
    property var _warnings: []
    property real _nowMs: Date.now()

    readonly property bool _busy: StockRegisterService.loading
    readonly property var _resolved: Glue.resolveWindow(chipIndex, fromText, toText, _nowMs)

    // Rows of the shown answer. Flat roles equal to Glue.ROW_KEYS (the delegate below declares the same names).
    ListModel { id: regModel }

    // ---- state changes: each one is one function (Skill 156 rule 4) ---------------------------------------

    // Copies a Glue state into the page and rebuilds the list. The ListModel is rebuilt, so a new answer or a
    // switch of "Show all" starts at the top (the rows differ); expanding a row never comes through here.
    function _applyState(st) {
        status = st.status
        errorText = st.text
        errorRetryable = st.retryable
        summary = st.summary
        shownWin = st.win
        _body = st.body
        _warnings = Glue.warningLines(st.summary)
        expandedId = ""
        regModel.clear()
        for (var i = 0; i < st.rows.length; ++i) regModel.append(st.rows[i])
    }

    function _refreshNow() { _nowMs = Date.now() }

    // The period the chips point at changed (chip or custom text): show the remembered answer for it, or nothing.
    function _periodChanged() {
        _refreshNow()
        var r = Glue.resolveWindow(chipIndex, fromText, toText, _nowMs)
        if (r.ok) _applyState(Glue.stateFromCache(StockRegisterService.cached(r.win), r.win, showAll))
        else _applyState(Glue.initialState())
    }

    function _chipPicked(index) {
        chipIndex = index
        _periodChanged()
    }

    function _showAllToggled(checked) {
        showAll = checked
        _applyState(Glue.stateFromBody(_body, shownWin, showAll))
    }

    function _toggleRow(productId) {
        expandedId = Glue.nextExpanded(expandedId, productId)
    }

    // The one tap that reads the ledger. Inputs are read ONCE here (Skill 156 rule 6): the window is resolved
    // from the chips at the tap, and the answer is checked against that same window by the service.
    function _loadTapped() {
        _refreshNow()
        var resolved = Glue.resolveWindow(chipIndex, fromText, toText, _nowMs)
        var d = Glue.tapDecision({ loading: StockRegisterService.loading, online: isOnline,
                                   role: AuthStore.role, resolved: resolved })
        if (!d.go) {
            var refusal = Glue.stateFromRefusal(d)
            if (refusal !== null) _applyState(refusal)
            return
        }
        var win = resolved.win
        try {
            StockRegisterService.load(win, function(result) { root._answered(result, win) })
        } catch (e) {
            // load() answers its callback exactly once on every path it controls; a throw means it never got that far.
            console.warn("[StockRegisterPage] load threw:", e)
            _applyState(Glue.stateFromResult({ ok: false, kind: "unknown", message: "", retryable: true }, win, showAll))
        }
    }

    // The service's answer, applied in exactly one place. null = leave the page as it is (cancelled, or busy).
    function _answered(result, win) {
        var st = Glue.stateFromResult(result, win, showAll)
        if (st !== null) _applyState(st)
    }

    function _cancelTapped() { StockRegisterService.cancel() }

    // Workspace or role changed: stop waiting, forget the memory (a register is a whole ledger in memory), start over.
    function _resetAll() {
        StockRegisterService.cancel()
        StockRegisterService.clear()
        chipIndex = 0
        fromText = ""
        toText = ""
        showAll = false
        _refreshNow()
        _applyState(Glue.initialState())
    }

    Connections {
        target: AuthStore
        function onTenantIdChanged() { root._resetAll() }
        function onRoleChanged() { root._resetAll() }
    }

    Rectangle { anchors.fill: parent; color: Constants.appBg }

    GlassHeader {
        id: header
        topInset: SafeArea.top
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Stock register")
        subtitle: qsTr("Opening, in, out and closing stock")

        leading: QQC.AbstractButton {
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: dp(40); implicitHeight: dp(40)
            padding: 0
            Accessible.name: qsTr("Back")
            background: Rectangle { color: parent.pressed ? Qt.rgba(0,0,0,0.04) : "transparent"; radius: dp(12) }
            contentItem: Item {
                Icon { anchors.centerIn: parent; name: "back"; color: Constants.textPrimary; size: sp(22) }
            }
            onClicked: root.backRequested()
        }
    }

    ListView {
        id: list
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        spacing: dp(Constants.space2)
        boundsBehavior: Flickable.StopAtBounds
        model: regModel
        // A big register keeps only what is on screen (and a little more) alive.
        cacheBuffer: dp(400)

        header: ColumnLayout {
            width: list.width
            spacing: dp(Constants.space3)

            Item { Layout.preferredHeight: dp(Constants.space2); Layout.fillWidth: true }

            // Period chips. Disabled while a load runs: the answer belongs to the period that was sent.
            ChipScroller {
                Layout.fillWidth: true
                enabled: !root._busy
                opacity: root._busy ? 0.5 : 1
                model: Glue.chipLabels()
                selected: root.chipIndex
                onChipSelected: function(index, label) { root._chipPicked(index) }
            }

            // Custom range: two typed days, both inclusive (a date picker is a follow-up, KNOWN-ISSUES).
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space3)
                visible: root.chipIndex === Glue.CUSTOM_INDEX
                enabled: !root._busy

                AuthTextField {
                    Layout.fillWidth: true
                    label: qsTr("From")
                    placeholderText: qsTr("YYYY-MM-DD")
                    maximumLength: 10
                    inputMethodHints: Qt.ImhPreferNumbers | Qt.ImhNoPredictiveText
                    text: root.fromText
                    onTextChanged: { if (root.fromText !== text) { root.fromText = text; root._periodChanged() } }
                }
                AuthTextField {
                    Layout.fillWidth: true
                    label: qsTr("To")
                    placeholderText: qsTr("YYYY-MM-DD")
                    maximumLength: 10
                    inputMethodHints: Qt.ImhPreferNumbers | Qt.ImhNoPredictiveText
                    text: root.toText
                    onTextChanged: { if (root.toText !== text) { root.toText = text; root._periodChanged() } }
                }
            }

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: text.length > 0
                text: Glue.inlineError(root.chipIndex, root.fromText, root.toText, root._resolved)
                color: Constants.danger
                font.pixelSize: sp(Constants.fsSmall)
                wrapMode: Text.WordWrap
            }

            // The period, and when the numbers were read.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(2)
                visible: periodText.text.length > 0

                Text {
                    id: periodText
                    Layout.fillWidth: true
                    text: Glue.captionText(root.shownWin, root._resolved)
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                    wrapMode: Text.WordWrap
                }
                Text {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: Glue.summaryAsOf(root.summary)
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsSmall)
                }
            }

            // The load button never fires by itself; Cancel appears while a load runs.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)

                PrimaryButton {
                    Layout.fillWidth: true
                    text: Glue.loadLabel(root.status, root.errorRetryable)
                    loading: root._busy
                    enabled: !root._busy && root._resolved.ok
                    onClicked: root._loadTapped()
                }
                GhostButton {
                    Layout.fillWidth: true
                    visible: root._busy
                    text: qsTr("Cancel")
                    onClicked: root._cancelTapped()
                }
                Text {
                    Layout.fillWidth: true
                    visible: root._busy
                    text: Glue.LOADING_TEXT
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsSmall)
                    wrapMode: Text.WordWrap
                }
                Text {
                    Layout.fillWidth: true
                    visible: root.status === "idle" && !root._busy
                    text: Glue.IDLE_TEXT
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsSmall)
                    wrapMode: Text.WordWrap
                }
            }

            // An error: words from the engine, no stale numbers behind it.
            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: root.status === "error"
                radius: dp(Constants.radius)
                color: Constants.cardBg
                border.color: Constants.danger
                border.width: 1
                implicitHeight: errorLabel.implicitHeight + dp(Constants.space4) * 2
                Accessible.role: Accessible.AlertMessage
                Accessible.name: root.errorText

                Text {
                    id: errorLabel
                    anchors.fill: parent
                    anchors.margins: dp(Constants.space4)
                    text: root.errorText
                    color: Constants.danger
                    font.pixelSize: sp(Constants.fsBody)
                    wrapMode: Text.WordWrap
                }
            }

            // Things the person must know before trusting the numbers (Skill 163 rule 5).
            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: root._warnings.length > 0
                radius: dp(Constants.radius)
                color: Constants.cardBg
                border.color: Constants.warn
                border.width: 1
                implicitHeight: warnColumn.implicitHeight + dp(Constants.space4) * 2

                ColumnLayout {
                    id: warnColumn
                    anchors.fill: parent
                    anchors.margins: dp(Constants.space4)
                    spacing: dp(Constants.space1)

                    Text {
                        text: qsTr("Check these numbers")
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsBody)
                        font.bold: true
                    }
                    Repeater {
                        model: root._warnings
                        delegate: Text {
                            required property string modelData
                            Layout.fillWidth: true
                            text: modelData
                            color: Constants.textSecondary
                            font.pixelSize: sp(Constants.fsSmall)
                            wrapMode: Text.WordWrap
                        }
                    }
                }
            }

            // Summary line and the switch for products with no stock history.
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: root.status === "ok"
                spacing: dp(Constants.space3)

                Text {
                    Layout.fillWidth: true
                    text: Glue.summaryText(root.summary)
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsSmall)
                    wrapMode: Text.WordWrap
                }
                Text {
                    text: qsTr("Show all products")
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsSmall)
                }
                // QQC.Switch's default style is bulky: constrain its footprint like OrdersPage does.
                Item {
                    Layout.preferredWidth: dp(48)
                    Layout.preferredHeight: dp(28)
                    QQC.Switch {
                        anchors.centerIn: parent
                        scale: 0.75
                        checked: root.showAll
                        Accessible.name: qsTr("Show all products")
                        onToggled: root._showAllToggled(checked)
                    }
                }
            }

            // An answer with nothing to list says why.
            Text {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: root.status === "ok" && regModel.count === 0
                text: Glue.emptyText(root.summary)
                color: Constants.textSecondary
                font.pixelSize: sp(Constants.fsBody)
                wrapMode: Text.WordWrap
            }
        }

        footer: Item { width: list.width; height: dp(Constants.space6) + SafeArea.bottom }

        delegate: StockRegisterRow {
            width: list.width - dp(Constants.space4) * 2
            x: dp(Constants.space4)
            open: root.expandedId === productId
            detail: Glue.detailRows(root._body, root.expandedId, productId)
            onToggled: function(id) { root._toggleRow(id) }
        }
    }
}
