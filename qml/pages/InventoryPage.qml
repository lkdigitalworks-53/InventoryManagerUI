import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Mobile inventory view — glass header, category chips, product cards with
// stock progress + low-stock chips, FAB. All actions preserved.
Item {
    id: root

    property bool compact: false
    property bool canManageInventory: true

    signal addProductClicked()
    signal restockClicked(string productId)
    signal viewProductClicked(string productId)
    signal editProductClicked(string productId)
    signal deleteProductClicked(string productId)
    signal exportRequested()
    signal importRequested()

    property string _searchText: ""
    property string _categoryFilter: "All"

    // Filtered list rebuilt as a real property so list reflows immediately
    // when InventoryStore mutates (instead of waiting for a tab switch).
    property var _list: []
    property int _inventoryWatcher: InventoryStore.revision
    on_InventoryWatcherChanged: _rebuildList()
    on_SearchTextChanged: _rebuildList()
    on_CategoryFilterChanged: _rebuildList()
    Component.onCompleted: _rebuildList()

    function _rebuildList() { _list = _filteredProducts() }

    Rectangle { anchors.fill: parent; color: Constants.appBg }

    GlassHeader {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        title: "Inventory"
        subtitle: "Track and manage products"

        actions: [
            IconActionButton {
                variant: "glass"
                iconName: "import"
                onClicked: root.importRequested()
            },
            IconActionButton {
                variant: "glass"
                iconName: "export"
                onClicked: root.exportRequested()
            }
        ]
    }

    QQC.ScrollView {
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff

        ColumnLayout {
            id: stack
            width: root.width
            spacing: dp(Constants.space3)

            // Top KPI grid — 2×2 to match the prototype phone layout. Three
            // wide cards on a phone row are too cramped for the value to read
            // at a glance.
            GridLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                Layout.topMargin: dp(Constants.space3)
                columns: 2
                columnSpacing: dp(Constants.space2 + 2)
                rowSpacing: dp(Constants.space2 + 2)

                GradientKpiCard {
                    Layout.fillWidth: true
                    Layout.preferredHeight: dp(110)
                    label: "Products"
                    value: String(InventoryStore.totalProducts())
                    trend: InventoryStore.totalItems() + " items"
                    palette: Constants.grad1
                }
                GradientKpiCard {
                    Layout.fillWidth: true
                    Layout.preferredHeight: dp(110)
                    label: "Low stock"
                    value: String(InventoryStore.lowStockCount())
                    trend: "needs reorder"
                    trendVariant: InventoryStore.lowStockCount() > 0 ? "down" : "muted"
                    palette: Constants.grad3
                }
                GradientKpiCard {
                    Layout.fillWidth: true
                    Layout.preferredHeight: dp(110)
                    label: "Total items"
                    value: String(InventoryStore.totalItems())
                    trend: "in stock"
                    palette: Constants.grad4
                }
                GradientKpiCard {
                    Layout.fillWidth: true
                    Layout.preferredHeight: dp(110)
                    label: "Avg markup"
                    value: InventoryStore.averageMarkupPercent() + "%"
                    trend: "above cost"
                    palette: Constants.grad2
                }
            }

            SearchField {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                placeholder: "Search products, SKUs, categories…"
                onTextChanged: root._searchText = text
            }

            ChipScroller {
                Layout.fillWidth: true
                model: _categoryChips()
                onChipSelected: function(idx, label) {
                    root._categoryFilter = label
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)

                Repeater {
                    model: root._list
                    delegate: ProductCard {
                        Layout.fillWidth: true
                        product: modelData
                        canManage: root.canManageInventory
                        onViewClicked:    root.viewProductClicked(modelData.productId)
                        onEditClicked:    root.editProductClicked(modelData.productId)
                        onRestockClicked: root.restockClicked(modelData.productId)
                        onDeleteClicked:  root.deleteProductClicked(modelData.productId)
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: root._list.length === 0
                radius: dp(Constants.radius)
                color: Constants.cardBg
                border.color: Constants.borderColor
                border.width: 1
                Layout.preferredHeight: dp(140)

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: dp(6)
                    Icon { name: "box"; size: sp(32); color: Constants.textMuted; Layout.alignment: Qt.AlignHCenter }
                    Text {
                        text: root._searchText.length > 0 ? "No matches" : "No products yet"
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsBodyLg)
                        font.bold: true
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Text {
                        text: root._searchText.length > 0
                            ? "Try a different search or category."
                            : "Tap + to add your first product."
                        color: Constants.textSecondary
                        font.pixelSize: sp(Constants.fsSmall)
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
            }

            Item { Layout.preferredHeight: dp(Constants.tabbarClearance) + SafeArea.bottom; Layout.fillWidth: true }
        }
    }

    FloatingActionButton {
        visible: root.canManageInventory
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: dp(Constants.space5)
        anchors.bottomMargin: dp(96)
        onClicked: root.addProductClicked()
    }

    // Per-row card — extracted so the card layout stays tidy.
    component ProductCard: ListCard {
        id: card
        property var product
        property bool canManage: true

        signal viewClicked()
        signal editClicked()
        signal restockClicked()
        signal deleteClicked()

        title: product ? product.name : ""
        subtitle: product
            ? (product.sku ? product.sku + " · " : "") +
              InventoryStore.formatCurrency(product.sellingPrice !== undefined ? product.sellingPrice : product.price)
            : ""
        implicitHeight: dp(84)
        onClicked: card.viewClicked()

        leading: AvatarBadge {
            imageSource: card.product && card.product.photoUrl ? card.product.photoUrl : ""
            label: card.product && card.product.name && card.product.name.length > 0
                ? card.product.name.charAt(0).toUpperCase() : "?"
            palette: card.product && card.product.stock <= card.product.minStock
                    ? Constants.grad3 : Constants.grad4
        }

        // Trailing column — stock counter on top, progress bar below, then a
        // "Restock" button when the user can manage inventory. Width bumped
        // to fit the inline button without crowding the card.
        ColumnLayout {
            spacing: dp(4)
            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
            Layout.preferredWidth: dp(96)

            Text {
                Layout.alignment: Qt.AlignRight
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                text: card.product
                        ? card.product.stock + " " + (card.product.unit || "pcs")
                        : "0"
                color: card.product && card.product.stock <= card.product.minStock
                        ? Constants.danger
                        : Constants.textSecondary
                font.pixelSize: sp(Constants.fsCaption)
                font.bold: card.product && card.product.stock <= card.product.minStock
            }
            StockProgressBar {
                Layout.alignment: Qt.AlignRight
                Layout.preferredWidth: dp(72)
                barWidth: dp(72)
                value: card.product ? Math.min(1, card.product.stock / Math.max(1, card.product.minStock * 3)) : 0
                low: card.product && card.product.stock <= card.product.minStock
            }
            StatusPill {
                Layout.alignment: Qt.AlignRight
                visible: card.product && card.product.stock <= card.product.minStock
                status: "low"
                label: "Low"
            }
            // Pill-shaped restock affordance. We deliberately use a Rectangle
            // + MouseArea instead of nesting another AbstractButton inside
            // the parent ListCard — when AbstractButtons are nested, both
            // outer (view) and inner (restock) `clicked` handlers can fire,
            // which manifested as the dialog never opening (or opening the
            // detail dialog instead).
            Rectangle {
                id: restockBtn
                Layout.alignment: Qt.AlignRight
                Layout.preferredHeight: dp(28)
                Layout.preferredWidth: restockLbl.implicitWidth + dp(20)
                visible: card.canManage
                radius: dp(Constants.radiusPill)
                color: restockArea.pressed
                        ? Qt.rgba(0.06, 0.72, 0.51, 0.22)
                        : Qt.rgba(0.06, 0.72, 0.51, 0.10)
                border.color: Qt.rgba(0.06, 0.72, 0.51, 0.35)
                border.width: 1
                Behavior on color { ColorAnimation { duration: Constants.durFast } }

                Text {
                    id: restockLbl
                    anchors.centerIn: parent
                    text: qsTr("Restock")
                    color: Constants.success
                    font.pixelSize: sp(Constants.fsCaption)
                    font.bold: true
                }
                MouseArea {
                    id: restockArea
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    // Accept the tap explicitly so it doesn't bubble up to
                    // the outer ListCard (which would also fire viewClicked).
                    onClicked: function(mouse) {
                        mouse.accepted = true
                        card.restockClicked()
                    }
                }
            }
        }
    }

    function _categoryChips() {
        var seen = {}
        var arr = ["All"]
        var products = InventoryStore.products || []
        for (var i = 0; i < products.length; ++i) {
            var c = products[i].category
            if (c && !seen[c]) { seen[c] = true; arr.push(c) }
        }
        arr.push("Low stock · " + InventoryStore.lowStockCount())
        return arr
    }

    function _filteredProducts() {
        var products = (InventoryStore.products || []).slice()
        var q = (root._searchText || "").toLowerCase().trim()
        var cat = root._categoryFilter
        return products.filter(function(p) {
            if (cat === "All") {
                /* no-op */
            } else if (cat.indexOf("Low stock") === 0) {
                if (!(p.stock <= p.minStock)) return false
            } else {
                if ((p.category || "") !== cat) return false
            }
            if (q.length === 0) return true
            var hay = ((p.name || "") + " " + (p.sku || "") + " " + (p.category || "")).toLowerCase()
            return hay.indexOf(q) >= 0
        })
    }
}
