import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Generic import preview — bottom sheet. Caller picks the kind via `mode`
// ("products" | "orders"). Stage 1: file summary + Ready/Issues tabs with
// per-row conflict resolution. Public contract preserved:
//   property string mode
//   property var _readyRows, _issueRows
//   property string _fileName
//   signal pathPromptRequested()
//   signal importCompleted(message)
//   function pickAndStart(), importFromUserPath(rawPath)
BottomSheet {
    id: root

    sheetTitle: mode === "products" ? "Import products" : "Import orders"
    primaryAction: "Import " + _effectiveCount() + " row" + (_effectiveCount() === 1 ? "" : "s")
    primaryEnabled: _effectiveCount() > 0
    secondaryAction: "Cancel"

    property string mode: "products"

    // Internal state
    property var _readyRows: []
    property var _issueRows: []
    property string _fileName: ""

    signal pathPromptRequested()
    signal importCompleted(string message)

    function pickAndStart() {
        _readyRows = []; _issueRows = []; _fileName = ""
        pathPromptRequested()
    }

    function importFromUserPath(rawPath) {
        if (!rawPath || rawPath.length === 0) return
        var url = _toFileUrl(rawPath)
        open()
        _loadFile(url)
    }

    function _toFileUrl(raw) {
        var s = String(raw).trim()
        var lower = s.toLowerCase()
        if (lower.indexOf("http://") === 0 || lower.indexOf("https://") === 0) return s
        if (lower.indexOf("file:") === 0) return s
        if (lower.indexOf("content://") === 0) return s
        var norm = s.replace(/\\/g, "/")
        if (norm.indexOf("/") !== 0) norm = "/" + norm
        return "file://" + norm
    }

    onPrimaryClicked: _apply()

    property int _activeTab: 0   // 0 = Ready, 1 = Issues

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        // File header + summary chips
        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            Text {
                text: root._fileName.length > 0 ? "📄  " + root._fileName : "Loading…"
                font.pixelSize: sp(Constants.fsBody)
                color: Constants.textPrimary
                Layout.fillWidth: true
                elide: Text.ElideMiddle
            }
            StatusPill {
                status: "completed"
                label: root._readyRows.length + " ready"
            }
            StatusPill {
                visible: root._issueRows.length > 0
                status: "pending"
                label: root._issueRows.length + " issue" + (root._issueRows.length === 1 ? "" : "s")
            }
        }

        // Bulk-resolution chips for conflicts
        ColumnLayout {
            Layout.fillWidth: true
            visible: root._readyRows.length > 0
            spacing: dp(Constants.space2)

            Text {
                text: "Conflicts"
                color: Constants.textSecondary
                font.pixelSize: sp(Constants.fsSmall)
                font.bold: true
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: dp(Constants.space2)

                GhostButton {
                    Layout.fillWidth: true
                    implicitHeight: dp(36)
                    text: "Skip all"
                    onClicked: root._setAllPolicy("skip")
                }
                GhostButton {
                    Layout.fillWidth: true
                    implicitHeight: dp(36)
                    text: "Overwrite all"
                    onClicked: root._setAllPolicy("overwrite")
                }
                GhostButton {
                    Layout.fillWidth: true
                    implicitHeight: dp(36)
                    text: "Add as new"
                    onClicked: root._setAllPolicy("rename")
                }
            }
        }

        // Tab segmented pill
        SegmentedPill {
            Layout.fillWidth: true
            model: ["Ready (" + root._readyRows.length + ")", "Issues (" + root._issueRows.length + ")"]
            selected: root._activeTab
            onSegmentSelected: function(idx, label) { root._activeTab = idx }
        }

        // Tab body
        StackLayout {
            Layout.fillWidth: true
            currentIndex: root._activeTab

            // Ready tab
            ColumnLayout {
                Layout.fillWidth: true
                spacing: dp(Constants.space2)

                Repeater {
                    model: root._readyRows
                    delegate: Rectangle {
                        Layout.fillWidth: true
                        radius: dp(Constants.radius)
                        color: Constants.cardBg
                        border.color: Constants.borderColor
                        border.width: 1
                        Layout.preferredHeight: rowCol.implicitHeight + dp(Constants.space3 * 2)

                        ColumnLayout {
                            id: rowCol
                            anchors.fill: parent
                            anchors.margins: dp(Constants.space3)
                            spacing: dp(4)

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: dp(Constants.space2)

                                Text {
                                    text: "Row " + (modelData.row || (index + 2))
                                    color: Constants.textMuted
                                    font.pixelSize: sp(Constants.fsCaption)
                                    Layout.preferredWidth: dp(50)
                                }
                                Text {
                                    text: root.mode === "products"
                                        ? (modelData.name || "(no name)") + (modelData.sku ? "  ·  " + modelData.sku : "")
                                        : (modelData.customer || "(no customer)") + (modelData.orderId ? "  ·  " + modelData.orderId : "")
                                    font.pixelSize: sp(Constants.fsBody)
                                    font.bold: true
                                    color: Constants.textPrimary
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }
                            }

                            // Conflict resolution row
                            RowLayout {
                                Layout.fillWidth: true
                                visible: modelData._conflictWith && modelData._conflictWith.length > 0
                                spacing: dp(Constants.space2)

                                StatusPill {
                                    status: "pending"
                                    label: "Conflict"
                                }
                                Text {
                                    text: "→ " + (modelData._conflictWith || "")
                                    color: Constants.textSecondary
                                    font.pixelSize: sp(Constants.fsCaption)
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }
                                AppComboBox {
                                    Layout.preferredWidth: dp(140)
                                    model: ["skip", "overwrite", "rename"]
                                    currentIndex: ["skip", "overwrite", "rename"].indexOf(modelData._conflictPolicy || "skip")
                                    font.pixelSize: sp(Constants.fsCaption)
                                    onActivated: root._setRowPolicy(index, currentText)
                                }
                            }

                            // Summary line
                            Text {
                                Layout.fillWidth: true
                                text: root._summarize(modelData)
                                color: Constants.textSecondary
                                font.pixelSize: sp(Constants.fsCaption)
                                elide: Text.ElideRight
                            }
                        }
                    }
                }

                Text {
                    visible: root._readyRows.length === 0
                    text: "No rows to import."
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsBody)
                    Layout.fillWidth: true
                    Layout.topMargin: dp(Constants.space3)
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            // Issues tab
            ColumnLayout {
                Layout.fillWidth: true
                spacing: dp(Constants.space2)

                Repeater {
                    model: root._issueRows
                    delegate: Rectangle {
                        Layout.fillWidth: true
                        radius: dp(Constants.radius)
                        color: Constants.pendingFill
                        border.color: Qt.rgba(0.96, 0.62, 0.04, 0.35)
                        border.width: 1
                        Layout.preferredHeight: issTxt.implicitHeight + dp(Constants.space3 * 2)

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: dp(Constants.space3)
                            spacing: dp(Constants.space2)

                            Text {
                                text: "Row " + modelData.row
                                color: Constants.pendingText
                                font.pixelSize: sp(Constants.fsCaption)
                                font.bold: true
                                Layout.preferredWidth: dp(50)
                            }
                            Text {
                                id: issTxt
                                text: modelData.message
                                color: Constants.pendingText
                                font.pixelSize: sp(Constants.fsBody)
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                            }
                        }
                    }
                }

                Text {
                    visible: root._issueRows.length === 0
                    text: "No issues — all rows look good."
                    color: Constants.success
                    font.pixelSize: sp(Constants.fsBody)
                    Layout.fillWidth: true
                    Layout.topMargin: dp(Constants.space3)
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }
    }

    // ─── Internals ───

    function _loadFile(fileUrl) {
        var url = String(fileUrl)
        var raw = XlsxService.readWorkbook(url)
        _fileName = url.substring(url.lastIndexOf("/") + 1)

        var rows = (mode === "products") ? (raw.products || []) : (raw.orders || [])
        if ((!rows || rows.length === 0) && raw.errors && raw.errors.length > 0) {
            _issueRows = [{ row: 0, message: raw.errors.join("; ") }]
            _readyRows = []
            return
        }

        if (mode === "products")
            _validateProductRows(rows)
        else
            _validateOrderRows(rows)
    }

    function _validateProductRows(rows) {
        var ready = []
        var issues = []
        var existingBySku = {}
        var existingById = {}
        for (var i = 0; i < InventoryStore.products.length; ++i) {
            var ep = InventoryStore.products[i]
            existingById[ep.productId] = ep
            if (ep.sku) existingBySku[ep.sku.toLowerCase()] = ep
        }

        for (var k = 0; k < rows.length; ++k) {
            var r = rows[k]
            var row = k + 2
            var name = (r["Name"] || "").toString().trim()
            if (!name || name.length < 2) {
                issues.push({ row: row, message: "Missing or too-short Name" })
                continue
            }
            var sellRaw = r["Selling Price"]
            var sell = parseFloat(sellRaw)
            if (isNaN(sell) || sell <= 0) {
                issues.push({ row: row, message: "Invalid or missing Selling Price (got '" + sellRaw + "')" })
                continue
            }
            var costRaw = r["Cost Price"]
            var cost = parseFloat(costRaw)
            if (isNaN(cost) || cost < 0) cost = 0
            if (sell < cost) {
                issues.push({ row: row, message: "Selling Price < Cost Price" })
                continue
            }
            var rec = {
                row: row,
                productId: (r["Product ID"] || "").toString().trim(),
                name: name,
                sku: (r["SKU"] || "").toString().trim(),
                category: (r["Category"] || "").toString().trim(),
                unit: (r["Unit"] || "").toString().trim() || "Units (pcs)",
                description: (r["Description"] || "").toString(),
                price: cost,
                sellingPrice: sell,
                stock: parseInt(r["Stock"]) || 0,
                minStock: parseInt(r["Min Stock"]) || 0,
                photoUrl: (r["Photo URL"] || "").toString().trim(),
                _conflictPolicy: "skip"
            }
            var hit = null
            if (rec.productId && existingById[rec.productId]) hit = existingById[rec.productId]
            else if (rec.sku && existingBySku[rec.sku.toLowerCase()]) hit = existingBySku[rec.sku.toLowerCase()]
            rec._conflictWith = hit ? (hit.productId + (hit.sku ? "/" + hit.sku : "")) : ""
            ready.push(rec)
        }
        _readyRows = ready
        _issueRows = issues
    }

    function _validateOrderRows(rows) {
        var ready = []
        var issues = []
        var existingById = {}
        for (var i = 0; i < OrdersStore.orders.length; ++i)
            existingById[OrdersStore.orders[i].orderId] = OrdersStore.orders[i]

        var skuToProduct = {}
        for (var ip = 0; ip < InventoryStore.products.length; ++ip) {
            var p = InventoryStore.products[ip]
            if (p.sku) skuToProduct[p.sku.toLowerCase()] = p
        }

        for (var k = 0; k < rows.length; ++k) {
            var r = rows[k]
            var row = k + 2
            var customer = (r["Customer"] || "").toString().trim()
            if (!customer) {
                issues.push({ row: row, message: "Missing Customer" })
                continue
            }
            var status = (r["Status"] || "").toString().trim().toLowerCase() || "pending"
            var allowed = ["pending", "processing", "completed", "out of stock"]
            if (allowed.indexOf(status) < 0) {
                issues.push({ row: row, message: "Invalid Status: " + status })
                continue
            }
            var prods = []
            var raw = (r["Products"] || "").toString()
            if (raw.length > 0) {
                var parts = raw.split("|")
                var unresolved = []
                for (var pi = 0; pi < parts.length; ++pi) {
                    var seg = parts[pi].trim()
                    if (!seg) continue
                    var bits = seg.split(":")
                    var tag = bits[0].trim()
                    var qty = parseInt(bits[1]) || 0
                    var price = bits.length > 2 ? parseFloat(bits[2]) : NaN
                    var inv = skuToProduct[tag.toLowerCase()] || null
                    if (!inv && tag.indexOf("PRD-") === 0) {
                        for (var ip2 = 0; ip2 < InventoryStore.products.length; ++ip2)
                            if (InventoryStore.products[ip2].productId === tag) { inv = InventoryStore.products[ip2]; break }
                    }
                    if (!inv) { unresolved.push(tag); continue }
                    prods.push({
                        productId: inv.productId,
                        name: inv.name,
                        price: !isNaN(price) ? price : (inv.sellingPrice || inv.price || 0),
                        quantity: qty
                    })
                }
                if (unresolved.length > 0) {
                    issues.push({ row: row, message: "Unknown product SKUs: " + unresolved.join(", ") })
                    continue
                }
            }

            var rec = {
                row: row,
                orderId: (r["Order ID"] || "").toString().trim(),
                customer: customer,
                email: (r["Email"] || "").toString().trim(),
                phone: (r["Phone"] || "").toString().trim(),
                status: status,
                date: (r["Date"] || "").toString().trim(),
                items: parseInt(r["Items"]) || 0,
                total: parseFloat(r["Total"]) || 0,
                notes: (r["Notes"] || "").toString(),
                products: prods,
                _conflictPolicy: "skip"
            }
            rec._conflictWith = (rec.orderId && existingById[rec.orderId]) ? rec.orderId : ""
            ready.push(rec)
        }
        _readyRows = ready
        _issueRows = issues
    }

    function _summarize(rec) {
        if (mode === "products")
            return "Sell ₹" + rec.sellingPrice + "  ·  Stock " + rec.stock + (rec.category ? "  ·  " + rec.category : "")
        return rec.status + "  ·  " + (rec.products ? rec.products.length : 0) + " line item"
            + (rec.products && rec.products.length === 1 ? "" : "s")
            + (rec.date ? "  ·  " + rec.date : "")
    }

    function _setAllPolicy(policy) {
        var next = []
        for (var i = 0; i < _readyRows.length; ++i) {
            var r = _readyRows[i]
            if (r._conflictWith && r._conflictWith.length > 0)
                r._conflictPolicy = policy
            next.push(r)
        }
        _readyRows = next
    }

    function _setRowPolicy(idx, policy) {
        if (idx < 0 || idx >= _readyRows.length) return
        var next = _readyRows.slice()
        next[idx]._conflictPolicy = policy
        _readyRows = next
    }

    function _effectiveCount() {
        var n = 0
        for (var i = 0; i < _readyRows.length; ++i) {
            var r = _readyRows[i]
            if (!r._conflictWith || r._conflictPolicy !== "skip") n++
        }
        return n
    }

    function _apply() {
        var counts
        if (mode === "products")
            counts = InventoryStore.upsertMany(_readyRows)
        else
            counts = OrdersStore.upsertMany(_readyRows)

        var msg = "✓ Imported " + (counts.added + counts.updated)
            + " row" + ((counts.added + counts.updated) === 1 ? "" : "s")
        if (counts.skipped > 0) msg += " · " + counts.skipped + " skipped"
        importCompleted(msg)
        close()
    }
}
