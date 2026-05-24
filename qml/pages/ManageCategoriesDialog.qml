import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../model"
import "../helper"

QQC.Dialog {
    id: root
    modal: true
    title: "Manage Categories"
    anchors.centerIn: parent
    padding: 20
    width: Math.min(parent ? parent.width - 40 : 460, 460)

    background: Rectangle {
        radius: 12
        color: "#ffffff"
        border.color: Constants.borderColor
    }

    contentItem: ColumnLayout {
        spacing: 12

        QQC.Label {
            Layout.fillWidth: true
            text: "Add or remove product categories. Categories you add are saved on this device for next time."
            color: "#6b7280"
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            QQC.TextField {
                id: addField
                Layout.fillWidth: true
                placeholderText: "New category name"
                onAccepted: root._addNew()
            }
            QQC.Button {
                text: "Add"
                background: Rectangle { radius: 6; color: Constants.primaryBlue }
                contentItem: Text {
                    text: "Add"; color: "#ffffff"; font.bold: true; font.pixelSize: 12
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                }
                onClicked: root._addNew()
            }
        }

        QQC.Label {
            id: addError
            Layout.fillWidth: true
            visible: text.length > 0
            color: "#b91c1c"
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 240
            radius: 8
            color: "#f9fafb"
            border.color: "#e5e7eb"

            Flickable {
                anchors.fill: parent
                anchors.margins: 6
                clip: true
                contentHeight: catCol.height

                Column {
                    id: catCol
                    width: parent.width
                    spacing: 4
                    Repeater {
                        model: CategoryStore.categories
                        delegate: Rectangle {
                            width: catCol.width
                            height: 36
                            radius: 6
                            color: "#ffffff"
                            border.color: "#e5e7eb"

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                anchors.rightMargin: 6
                                spacing: 6

                                Text {
                                    Layout.fillWidth: true
                                    text: modelData
                                    color: "#111827"
                                    font.pixelSize: 13
                                    elide: Text.ElideRight
                                    verticalAlignment: Text.AlignVCenter
                                }
                                Text {
                                    visible: modelData === CategoryStore.lastUsed
                                    text: "default"
                                    color: "#16a34a"
                                    font.pixelSize: 10
                                    font.bold: true
                                }
                                QQC.Button {
                                    text: "Set default"
                                    height: 26
                                    visible: modelData !== CategoryStore.lastUsed
                                    onClicked: CategoryStore.setLastUsed(modelData)
                                    contentItem: Text { text: "Set default"; color: "#374151"; font.pixelSize: 10
                                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                    background: Rectangle { radius: 4; color: "#ffffff"; border.color: "#d1d5db" }
                                }
                                QQC.Button {
                                    text: "Remove"
                                    height: 26
                                    enabled: CategoryStore.categories.length > 1
                                    onClicked: CategoryStore.removeCategory(modelData)
                                    contentItem: Text { text: "Remove"; color: "#dc2626"; font.pixelSize: 10
                                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                    background: Rectangle { radius: 4; color: "#fef2f2"; border.color: "#fecaca" }
                                }
                            }
                        }
                    }
                }
            }
        }

        QQC.Button {
            Layout.alignment: Qt.AlignRight
            text: "Done"
            onClicked: root.close()
        }
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
