import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

QQC.Dialog {
    id: root

    signal roleUpdateRequested(string uid, string role)
    signal statusUpdateRequested(string uid, string status)
    signal removeMemberRequested(string uid)
    signal refreshRequested()

    property var members: []
    property bool busy: false
    property string errorMessage: ""
    property string searchText: ""
    property string filterRole: "all"

    property string confirmAction: ""
    property string confirmUid: ""
    property string confirmRole: ""
    property string confirmStatus: ""
    property string confirmMessage: ""

    function _matchesFilter(m) {
        var q = (searchText || "").toLowerCase()
        var text = ((m.displayName || "") + " " + (m.email || "") + " " + (m.uid || "")).toLowerCase()
        var roleOk = filterRole === "all" || (m.role || "staff") === filterRole
        var queryOk = q.length === 0 || text.indexOf(q) >= 0
        return roleOk && queryOk
    }

    function _openConfirm(action, uid, role, status) {
        confirmAction = action
        confirmUid = uid || ""
        confirmRole = role || ""
        confirmStatus = status || ""
        if (action === "role")
            confirmMessage = "Set role for " + confirmUid + " to '" + confirmRole + "'?"
        else if (action === "status")
            confirmMessage = "Change status for " + confirmUid + " to '" + confirmStatus + "'?"
        else
            confirmMessage = "Remove member " + confirmUid + " from this tenant?"
        confirmDlg.open()
    }

    modal: true
    title: "Manage Members"
    anchors.centerIn: parent
    width: 760
    height: 520
    standardButtons: QQC.Dialog.Close

    ColumnLayout {
        anchors.fill: parent
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            QQC.TextField {
                Layout.fillWidth: true
                placeholderText: "Search by name, email, or UID"
                text: root.searchText
                onTextChanged: root.searchText = text
            }
            QQC.ComboBox {
                Layout.preferredWidth: 130
                model: ["all", "owner", "admin", "manager", "staff"]
                currentIndex: 0
                onCurrentTextChanged: root.filterRole = currentText
            }
            Text {
                text: "Tenant membership and roles"
                font.pixelSize: 12
                color: "#6b7280"
            }
            QQC.Button {
                text: busy ? "Loading..." : "Refresh"
                enabled: !busy
                onClicked: refreshRequested()
            }
        }

        Text {
            visible: errorMessage.length > 0
            text: errorMessage
            color: "#b91c1c"
            font.pixelSize: 12
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: 10
            border.color: "#e5e7eb"
            color: "#ffffff"

            Flickable {
                anchors.fill: parent
                clip: true
                contentHeight: membersCol.implicitHeight + 16

                Column {
                    id: membersCol
                    width: parent.width
                    spacing: 6
                    anchors.margins: 8

                    Repeater {
                        model: root.members
                        delegate: Rectangle {
                            visible: root._matchesFilter(modelData)
                            width: membersCol.width - 16
                            x: 8
                            height: visible ? 78 : 0
                            radius: 8
                            color: "#f9fafb"
                            border.color: "#e5e7eb"

                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: 10
                                spacing: 10

                                Column {
                                    Layout.preferredWidth: 220
                                    spacing: 3
                                    Text { text: modelData.displayName || "(No Name)"; color: "#111827"; font.bold: true; font.pixelSize: 13 }
                                    Text { text: modelData.email || ""; color: "#6b7280"; font.pixelSize: 11 }
                                    Text { text: "UID: " + (modelData.uid || ""); color: "#6b7280"; font.pixelSize: 10 }
                                }

                                QQC.ComboBox {
                                    id: roleBox
                                    Layout.preferredWidth: 120
                                    model: ["owner", "admin", "manager", "staff"]
                                    currentIndex: {
                                        var r = modelData.role || "staff"
                                        if (r === "owner") return 0
                                        if (r === "admin") return 1
                                        if (r === "manager") return 2
                                        return 3
                                    }
                                }

                                QQC.Button {
                                    text: "Set Role"
                                    enabled: !root.busy
                                    onClicked: root._openConfirm("role", modelData.uid || "", roleBox.currentText, "")
                                }

                                QQC.Button {
                                    text: (modelData.status === "suspended") ? "Activate" : "Suspend"
                                    enabled: !root.busy
                                    onClicked: root._openConfirm("status", modelData.uid || "", "", modelData.status === "suspended" ? "active" : "suspended")
                                }

                                QQC.Button {
                                    text: "Remove"
                                    enabled: !root.busy
                                    onClicked: root._openConfirm("remove", modelData.uid || "", "", "")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    QQC.Dialog {
        id: confirmDlg
        modal: true
        title: "Confirm Action"
        anchors.centerIn: parent
        width: 420
        standardButtons: QQC.Dialog.Yes | QQC.Dialog.No
        onAccepted: {
            if (root.confirmAction === "role")
                root.roleUpdateRequested(root.confirmUid, root.confirmRole)
            else if (root.confirmAction === "status")
                root.statusUpdateRequested(root.confirmUid, root.confirmStatus)
            else if (root.confirmAction === "remove")
                root.removeMemberRequested(root.confirmUid)
        }

        contentItem: Text {
            text: root.confirmMessage
            wrapMode: Text.Wrap
            color: "#111827"
            font.pixelSize: 12
            padding: 10
        }
    }
}
