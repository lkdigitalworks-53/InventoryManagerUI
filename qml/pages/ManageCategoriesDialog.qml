import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Categories editor — bottom sheet. No public signals; mutates CategoryStore
// directly. Opened from AddProductDialog → "Manage categories".
BottomSheet {
    id: root

    sheetTitle: "Categories"
    primaryAction: ""
    secondaryAction: "Done"

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        Text {
            Layout.fillWidth: true
            text: "Add or remove product categories. Categories you add are saved on this device for next time."
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
                placeholderText: "New category name"
                onAccepted: root._addNew()
            }

            PrimaryButton {
                text: "Add"
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

        // Existing categories
        ColumnLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            Repeater {
                model: CategoryStore.categories
                delegate: ListCard {
                    Layout.fillWidth: true
                    title: modelData
                    subtitle: modelData === CategoryStore.lastUsed ? "Default category" : ""

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

                        QQC.AbstractButton {
                            visible: modelData !== CategoryStore.lastUsed
                            implicitHeight: dp(28)
                            implicitWidth: starTxt.implicitWidth + dp(20)
                            background: Rectangle {
                                radius: dp(Constants.radiusPill)
                                color: Constants.subtleBg
                                border.color: Constants.borderColor
                                border.width: 1
                            }
                            contentItem: Item {
                                Row {
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
                            }
                            onClicked: CategoryStore.setLastUsed(modelData)
                        }

                        QQC.AbstractButton {
                            enabled: CategoryStore.categories.length > 1
                            implicitHeight: dp(28)
                            implicitWidth: removeTxt.implicitWidth + dp(20)
                            background: Rectangle {
                                radius: dp(Constants.radiusPill)
                                color: Qt.rgba(0.93, 0.27, 0.27, 0.10)
                                border.color: Qt.rgba(0.93, 0.27, 0.27, 0.25)
                                border.width: 1
                            }
                            contentItem: Item {
                                Text {
                                    id: removeTxt
                                    anchors.centerIn: parent
                                    text: "Remove"
                                    color: Constants.danger
                                    font.pixelSize: sp(Constants.fsCaption)
                                    font.bold: true
                                }
                            }
                            onClicked: root._confirmRemove(modelData)
                        }
                    }
                }
            }
        }
    }

    // Inline confirm dialog so removal is reversible (= cancellable). The
    // global confirmDlg in Main.qml is reachable but using a local one
    // avoids a layered-popup glitch where the outer sheet hides the modal.
    ConfirmDialog { id: removeConfirm }

    function _confirmRemove(name) {
        removeConfirm.ask({
            title: "Remove category?",
            message: "“" + name + "” will be removed from the category list. Existing products keep their assignment but new products won't be able to use it.",
            confirmLabel: "Remove",
            onConfirm: function() { CategoryStore.removeCategory(name) }
        })
    }

    function _addNew() {
        var name = addField.text
        if (!name || name.trim().length === 0) {
            addError.text = "Enter a name first"
            return
        }
        if (!CategoryStore.addCategory(name)) {
            addError.text = "Already in the list"
            return
        }
        addError.text = ""
        addField.text = ""
    }
}
