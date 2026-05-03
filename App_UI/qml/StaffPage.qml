import QtQuick 6.5
import QtQuick.Controls 6.5
import QtQuick.Layouts 6.5
import BusinessApp 1.0

Item {
    id: root
    property bool compact: false

    signal addStaffClicked()

    Flickable {
        anchors.fill: parent
        contentHeight: col.height
        clip: true
        flickableDirection: Flickable.VerticalFlick
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
            id: col
            width: root.width
            spacing: 16

            // ── Title + Add Staff ──
            RowLayout {
                width: col.width; spacing: 8
                Column { spacing: 4; Layout.fillWidth: true
                    Label { text: "Staff Management"; color: "#111827"; font.bold: true; font.pixelSize: 18 }
                    Label { text: "Manage team members and roles"; color: "#6b7280"; font.pixelSize: 12 }
                }
                Button {
                    id: addBtn; text: "+  Add Staff Member"
                    onClicked: root.addStaffClicked()
                    background: Rectangle { radius: 8; color: "#8b5cf6" }
                    contentItem: Text { text: addBtn.text; color: "white"; font.bold: true; font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
            }

            // ── KPI Cards ──
            Row {
                width: col.width; spacing: 12
                Rectangle {
                    width: (col.width - 36) / 4; height: 110; radius: 12; color: "#ffffff"; border.color: "#e5e7eb"
                    Column { x: 16; y: 14; spacing: 4
                        Label { text: "Total Staff"; font.pixelSize: 13; font.bold: true; color: "#3b82f6" }
                        Label { text: "All employees"; font.pixelSize: 11; color: "#6b7280" }
                        Item { width: 1; height: 8 }
                        Label { text: String(StaffStore.totalStaff()); font.pixelSize: 22; font.bold: true; color: "#3b82f6" }
                    }
                }
                Rectangle {
                    width: (col.width - 36) / 4; height: 110; radius: 12; color: "#ffffff"; border.color: "#e5e7eb"
                    Column { x: 16; y: 14; spacing: 4
                        Label { text: "Active"; font.pixelSize: 13; font.bold: true; color: "#22c55e" }
                        Label { text: "Currently working"; font.pixelSize: 11; color: "#6b7280" }
                        Item { width: 1; height: 8 }
                        Label { text: String(StaffStore.activeCount()); font.pixelSize: 22; font.bold: true; color: "#22c55e" }
                    }
                }
                Rectangle {
                    width: (col.width - 36) / 4; height: 110; radius: 12; color: "#fefce8"; border.color: "#fde047"
                    Column { x: 16; y: 14; spacing: 4
                        Label { text: "On Leave"; font.pixelSize: 13; font.bold: true; color: "#ca8a04" }
                        Label { text: "Temporarily away"; font.pixelSize: 11; color: "#6b7280" }
                        Item { width: 1; height: 8 }
                        Label { text: String(StaffStore.onLeaveCount()); font.pixelSize: 22; font.bold: true; color: "#ca8a04" }
                    }
                }
                Rectangle {
                    width: (col.width - 36) / 4; height: 110; radius: 12; color: "#ffffff"; border.color: "#e5e7eb"
                    Column { x: 16; y: 14; spacing: 4
                        Label { text: "Departments"; font.pixelSize: 13; font.bold: true; color: "#3b82f6" }
                        Label { text: "Total departments"; font.pixelSize: 11; color: "#6b7280" }
                        Item { width: 1; height: 8 }
                        Label { text: String(StaffStore.departmentCount()); font.pixelSize: 22; font.bold: true; color: "#3b82f6" }
                    }
                }
            }

            // ── Team Members ──
            Rectangle {
                width: col.width; height: membersCol.height + 32; radius: 12
                color: "#ffffff"; border.color: "#e5e7eb"
                Column {
                    id: membersCol; x: 16; y: 16; width: parent.width - 32; spacing: 12

                    Column { spacing: 2
                        Label { text: "Team Members"; font.pixelSize: 14; font.bold: true; color: "#111827" }
                        Label { text: "All staff members and their details"; font.pixelSize: 11; color: "#6b7280" }
                    }

                    TextField {
                        id: search; width: membersCol.width
                        placeholderText: "🔍  Search staff..."
                        font.pixelSize: 12
                        background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#e5e7eb" }
                    }

                    // Staff cards
                    Repeater {
                        model: StaffStore.staff
                        Rectangle {
                            width: membersCol.width; radius: 12
                            color: "#ffffff"; border.color: "#e5e7eb"
                            visible: search.text === "" || (modelData.name + modelData.role + modelData.department + modelData.email).toLowerCase().indexOf(search.text.toLowerCase()) >= 0
                            height: visible ? 90 : 0

                            Row {
                                x: 16; anchors.verticalCenter: parent.verticalCenter; spacing: 14; width: parent.width - 32

                                // Avatar
                                Rectangle {
                                    width: 44; height: 44; radius: 22; color: "#ede9fe"
                                    Text { text: StaffStore.initials(modelData.name); color: "#7c3aed"; font.pixelSize: 16; font.bold: true; anchors.centerIn: parent }
                                }

                                // Info
                                Column {
                                    spacing: 3; width: parent.width - 400; anchors.verticalCenter: parent.verticalCenter
                                    Row { spacing: 8
                                        Label { text: modelData.name; font.pixelSize: 14; font.bold: true; color: "#111827" }
                                        Rectangle {
                                            width: statusLabel.implicitWidth + 12; height: 20; radius: 10
                                            color: modelData.status === "active" ? "#dcfce7" : "#fef9c3"
                                            border.color: modelData.status === "active" ? "#22c55e" : "#eab308"
                                            Text { id: statusLabel; text: modelData.status === "active" ? "active" : "on leave"; font.pixelSize: 10; font.bold: true
                                                color: modelData.status === "active" ? "#16a34a" : "#ca8a04"; anchors.centerIn: parent }
                                        }
                                    }
                                    Label { text: modelData.role + " • " + modelData.department; font.pixelSize: 11; color: "#6b7280" }
                                    Row { spacing: 16
                                        Label { text: "✉ " + modelData.email; font.pixelSize: 11; color: "#6b7280" }
                                        Label { text: "📞 " + modelData.phone; font.pixelSize: 11; color: "#6b7280" }
                                    }
                                }

                                Item { width: 1; height: 1; Layout.fillWidth: true }

                                // Joined + Actions
                                Column {
                                    spacing: 2; anchors.verticalCenter: parent.verticalCenter
                                    Label { text: "Joined"; font.pixelSize: 10; color: "#9ca3af"; horizontalAlignment: Text.AlignRight; width: implicitWidth }
                                    Label { text: modelData.joinDate; font.pixelSize: 12; font.bold: true; color: "#374151" }
                                }

                                Row {
                                    spacing: 8; anchors.verticalCenter: parent.verticalCenter
                                    Button {
                                        text: "View Profile"; height: 32; padding: 8
                                        background: Rectangle { radius: 6; color: "#ffffff"; border.color: "#d1d5db" }
                                        contentItem: Text { text: "View Profile"; font.pixelSize: 11; color: "#374151"
                                            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                    }
                                    Button {
                                        text: "Edit"; height: 32; padding: 8
                                        background: Rectangle { radius: 6; color: "#ffffff"; border.color: "#d1d5db" }
                                        contentItem: Text { text: "Edit"; font.pixelSize: 11; color: "#374151"
                                            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ── Bottom Row: Department Distribution + Recent Activities ──
            Row {
                width: col.width; spacing: 16

                // Department Distribution
                Rectangle {
                    width: (col.width - 16) / 2; height: deptCol.height + 32; radius: 12
                    color: "#ffffff"; border.color: "#e5e7eb"
                    Column {
                        id: deptCol; x: 16; y: 16; width: parent.width - 32; spacing: 12
                        Label { text: "Department Distribution"; font.pixelSize: 14; font.bold: true; color: "#111827" }
                        Label { text: "Staff by department"; font.pixelSize: 11; color: "#6b7280" }
                        Repeater {
                            model: StaffStore.departmentList()
                            Column {
                                width: deptCol.width; spacing: 6
                                RowLayout {
                                    width: deptCol.width
                                    Label { text: modelData.name; font.pixelSize: 12; color: "#374151"; Layout.fillWidth: true }
                                    Label { text: modelData.count + " staff"; font.pixelSize: 12; color: "#6b7280" }
                                }
                                Rectangle {
                                    width: deptCol.width; height: 8; radius: 4; color: "#e5e7eb"
                                    Rectangle {
                                        width: parent.width * (modelData.count / StaffStore.totalStaff())
                                        height: 8; radius: 4; color: "#8b5cf6"
                                    }
                                }
                            }
                        }
                    }
                }

                // Recent Activities
                Rectangle {
                    width: (col.width - 16) / 2; height: actCol.height + 32; radius: 12
                    color: "#ffffff"; border.color: "#e5e7eb"
                    Column {
                        id: actCol; x: 16; y: 16; width: parent.width - 32; spacing: 12
                        Label { text: "Recent Activities"; font.pixelSize: 14; font.bold: true; color: "#111827" }
                        Label { text: "Latest staff updates"; font.pixelSize: 11; color: "#6b7280" }
                        Repeater {
                            model: StaffStore.activities
                            Row {
                                spacing: 12; width: actCol.width; height: 40
                                Rectangle { width: 10; height: 10; radius: 5; color: modelData.color; anchors.verticalCenter: parent.verticalCenter }
                                Column { spacing: 2; anchors.verticalCenter: parent.verticalCenter
                                    Label { text: modelData.text; font.pixelSize: 12; color: "#111827" }
                                    Label { text: modelData.time; font.pixelSize: 11; color: "#9ca3af" }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
