import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Order-channel editor — bottom sheet. No public signals; mutates
// OrderChannelStore directly. Mirrors ManageCategoriesDialog so users see
// the same affordances (add row, default-pin, remove).
BottomSheet {
    id: root

    sheetTitle: qsTr("Order channels")
    primaryAction: ""
    secondaryAction: qsTr("Done")

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        Text {
            Layout.fillWidth: true
            text: qsTr("Add or remove channels for tagging orders. The default channel pre-fills the picker on every new order.")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            wrapMode: Text.Wrap
        }

        // Add row
        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            AuthTextField {
                id: addField
                Layout.fillWidth: true
                placeholderText: qsTr("New channel name")
                onAccepted: root._addNew()
            }

            PrimaryButton {
                text: qsTr("Add")
                implicitHeight: dp(48)
                implicitWidth: dp(80)
                onClicked: root._addNew()
            }
        }

        Text {
            id: addError
            Layout.fillWidth: true
            visible: text.length > 0
            color: Constants.danger
            font.pixelSize: sp(Constants.fsCaption)
            wrapMode: Text.Wrap
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            Repeater {
                model: OrderChannelStore.channels
                delegate: ListCard {
                    Layout.fillWidth: true
                    title: modelData
                    subtitle: modelData === OrderChannelStore.defaultChannel ? qsTr("Default channel") : ""

                    leading: AvatarBadge {
                        size: "md"
                        label: (modelData || "?").charAt(0).toUpperCase()
                        palette: index % 4 === 0 ? Constants.grad1
                               : index % 4 === 1 ? Constants.grad2
                               : index % 4 === 2 ? Constants.grad3
                               :                   Constants.grad4
                    }

                    RowLayout {
                        spacing: dp(Constants.space2)
                        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight

                        // Promote to default — hidden when this row is already default.
                        QQC.AbstractButton {
                            id: defaultBtn
                            visible: modelData !== OrderChannelStore.defaultChannel
                            implicitHeight: dp(28)
                            implicitWidth: starTxt.implicitWidth + dp(20)
                            padding: 0
                            topPadding: 0; bottomPadding: 0; leftPadding: dp(10); rightPadding: dp(10)
                            background: Rectangle {
                                anchors.fill: parent
                                radius: dp(Constants.radiusPill)
                                color: defaultBtn.pressed ? Constants.borderColor : Constants.subtleBg
                                border.color: Constants.borderColor
                                border.width: 1
                                Behavior on color { ColorAnimation { duration: Constants.durFast } }
                            }
                            contentItem: Row {
                                id: starTxt
                                anchors.centerIn: parent
                                spacing: dp(4)
                                Icon {
                                    name: "star"
                                    size: sp(Constants.fsCaption)
                                    color: Constants.textSecondary
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    text: qsTr("Default")
                                    color: Constants.textSecondary
                                    font.pixelSize: sp(Constants.fsCaption)
                                    font.bold: true
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                            onClicked: OrderChannelStore.setDefault(modelData)
                        }

                        QQC.AbstractButton {
                            id: removeBtn
                            // The picker requires at least one channel to
                            // remain — guard the last entry from removal.
                            enabled: OrderChannelStore.channels.length > 1
                            implicitHeight: dp(28)
                            implicitWidth: removeTxt.implicitWidth + dp(20)
                            padding: 0
                            topPadding: 0; bottomPadding: 0; leftPadding: dp(10); rightPadding: dp(10)
                            background: Rectangle {
                                anchors.fill: parent
                                radius: dp(Constants.radiusPill)
                                color: removeBtn.pressed
                                        ? Qt.rgba(0.93, 0.27, 0.27, 0.20)
                                        : Qt.rgba(0.93, 0.27, 0.27, 0.10)
                                border.color: Qt.rgba(0.93, 0.27, 0.27, 0.25)
                                border.width: 1
                                opacity: removeBtn.enabled ? 1 : 0.5
                                Behavior on color { ColorAnimation { duration: Constants.durFast } }
                            }
                            contentItem: Text {
                                id: removeTxt
                                text: qsTr("Remove")
                                color: Constants.danger
                                font.pixelSize: sp(Constants.fsCaption)
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                            onClicked: root._confirmRemove(modelData)
                        }
                    }
                }
            }
        }
    }

    // Inline confirm — same pattern as ManageCategoriesDialog so the user
    // can cancel an accidental remove. Local instance avoids the layered-
    // popup glitch where the parent sheet hides the global confirmDlg.
    ConfirmDialog { id: removeConfirm }

    function _confirmRemove(name) {
        removeConfirm.ask({
            title: qsTr("Remove channel?"),
            message: qsTr("“%1” will be removed from the channel list. Existing orders that used it keep their tag.").arg(name),
            confirmLabel: qsTr("Remove"),
            onConfirm: function() { OrderChannelStore.removeChannel(name) }
        })
    }

    function _addNew() {
        var name = addField.text
        if (!name || name.trim().length === 0) {
            addError.text = qsTr("Enter a name first")
            return
        }
        if (!OrderChannelStore.addChannel(name)) {
            addError.text = qsTr("Already in the list")
            return
        }
        addError.text = ""
        addField.text = ""
    }
}
