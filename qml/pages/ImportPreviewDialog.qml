import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../model"
import "../helper"
import "../components"

// Generic import preview for products or orders. Caller picks the kind via
// `mode` ("products" | "orders"). On open() we ask the user to pick a file,
// parse it, validate, then show a preview with per-row conflict resolution.
QQC.Dialog {
    id: root
    modal: true
    anchors.centerIn: parent
    padding: 20
    width: Math.min(parent ? parent.width - 32 : 720, 720)
    height: Math.min(parent ? parent.height - 80 : 560, 560)
    title: mode === "products" ? "Import products" : "Import orders"

    property string mode: "products"

    // Internal state
    property var _readyRows: []        // [{ row, _conflictPolicy, _conflictWith, ...fields }]
    property var _issueRows: []        // [{ row, message, raw }]
    property string _fileName: ""

    // Caller (Main.qml) opens its own path-prompt dialog and hands the typed
    // string to importWith(). Keeping the prompt outside this Dialog avoids a
    // QQC.Dialog-inside-QQC.Dialog parenting glitch where the inner one never
    // shows.
    signal pathPromptRequested()

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

    // Auto-prefix file:/// when the user gave us a plain local path. Leave
    // http(s):// and file:// URLs alone.
    function _toFileUrl(raw) {
        var s = String(raw).trim()
        var lower = s.toLowerCase()
        if (lower.indexOf("http://") === 0 || lower.indexOf("https://") === 0) return s
        if (lower.indexOf("file:") === 0) return s
        if (lower.indexOf("content://") === 0) return s   // Android share intent
        // Local path — normalize backslashes and prepend file:///
        var norm = s.replace(/\\/g, "/")
        if (norm.indexOf("/") !== 0) norm = "/" + norm    // Windows "C:/..." -> "/C:/..."
        return "file://" + norm
    }

    background: Rectangle {
        radius: 12
        color: "#ffffff"
        border.color: Constants.borderColor
    }

    contentItem: ColumnLayout {
        spacing: 12

        // Header summary chips
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            QQC.Label {
                text: root._fileName.length > 0 ? "📄  " + root._fileName : "Loading…"
                font.pixelSize: 13
                color: "#111827"
                Layout.fillWidth: true
                elide: Text.ElideMiddle
            }

            Rectangle {
                radius: 12; height: 24
                color: "#dcfce7"; border.color: "#22c55e"
                width: readyChipText.implicitWidth + 16
                Text { id: readyChipText; anchors.centerIn: parent
                    text: root._readyRows.length + " ready"
                    color: "#15803d"; font.pixelSize: 11; font.bold: true }
            }
            Rectangle {
                radius: 12; height: 24
                visible: root._issueRows.length > 0
                color: "#fef3c7"; border.color: "#f59e0b"
                width: issueChipText.implicitWidth + 16
                Text { id: issueChipText; anchors.centerIn: parent
                    text: root._issueRows.length + " issue" + (root._issueRows.length === 1 ? "" : "s")
                    color: "#92400e"; font.pixelSize: 11; font.bold: true }
            }
        }

        // Bulk actions
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: root._readyRows.length > 0

            QQC.Label { text: "Conflicts:"; color: "#6b7280"; font.pixelSize: 12 }
            QQC.Button {
                text: "Skip all"
                onClicked: root._setAllPolicy("skip")
            }
            QQC.Button {
                text: "Overwrite all"
                onClicked: root._setAllPolicy("overwrite")
            }
            QQC.Button {
                text: "Add as new"
                onClicked: root._setAllPolicy("rename")
            }
            Item { Layout.fillWidth: true }
        }

        // Tabbed body — Ready / Issues
        QQC.TabBar {
            id: tabBar
            Layout.fillWidth: true
            QQC.TabButton { text: "Ready (" + root._readyRows.length + ")" }
            QQC.TabButton { text: "Issues (" + root._issueRows.length + ")" }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: tabBar.currentIndex

            // Ready tab
            QQC.ScrollView {
                clip: true
                ColumnLayout {
                    width: root.width - 60
                    spacing: 4
                    Repeater {
                        model: root._readyRows
                        delegate: Rectangle {
                            Layout.fillWidth: true
                            radius: 6
                            color: index % 2 === 0 ? "#ffffff" : "#f9fafb"
                            border.color: Constants.borderColor
                            implicitHeight: rowCol.implicitHeight + 14

                            ColumnLayout {
                                id: rowCol
                                anchors.fill: parent
                                anchors.margins: 8
                                spacing: 4

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    QQC.Label {
                                        text: "Row " + (modelData.row || (index + 2))
                                        color: "#6b7280"
                                        font.pixelSize: 10
                                        Layout.preferredWidth: 50
                                    }
                                    QQC.Label {
                                        text: root.mode === "products"
                                            ? (modelData.name || "(no name)") + (modelData.sku ? "  ·  " + modelData.sku : "")
                                            : (modelData.customer || "(no customer)") + (modelData.orderId ? "  ·  " + modelData.orderId : "")
                                        font.pixelSize: 12
                                        font.bold: true
                                        color: "#111827"
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                    }

                                    // Conflict chip + per-row action
                                    Item {
                                        visible: modelData._conflictWith && modelData._conflictWith.length > 0
                                        Layout.preferredWidth: 220
                                        Layout.preferredHeight: 26
                                        Row {
                                            anchors.fill: parent
                                            spacing: 4
                                            Rectangle {
                                                width: cWith.implicitWidth + 12; height: 22; radius: 11
                                                color: "#fef3c7"; border.color: "#f59e0b"
                                                anchors.verticalCenter: parent.verticalCenter
                                                Text { id: cWith; anchors.centerIn: parent
                                                    text: "conflict"
                                                    color: "#92400e"; font.pixelSize: 10; font.bold: true }
                                            }
                                            QQC.ComboBox {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 140; height: 26
                                                model: ["skip", "overwrite", "rename"]
                                                currentIndex: ["skip", "overwrite", "rename"].indexOf(modelData._conflictPolicy || "skip")
                                                onActivated: root._setRowPolicy(index, currentText)
                                            }
                                        }
                                    }
                                }

                                // Secondary line — quick summary of fields
                                QQC.Label {
                                    Layout.fillWidth: true
                                    visible: text.length > 0
                                    text: root._summarize(modelData)
                                    color: "#6b7280"
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                    Item { Layout.fillWidth: true; Layout.preferredHeight: 4 }
                }
            }

            // Issues tab
            QQC.ScrollView {
                clip: true
                ColumnLayout {
                    width: root.width - 60
                    spacing: 4
                    Repeater {
                        model: root._issueRows
                        delegate: Rectangle {
                            Layout.fillWidth: true
                            radius: 6
                            color: "#fff7ed"
                            border.color: "#fdba74"
                            implicitHeight: issTxt.implicitHeight + 14

                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: 8
                                spacing: 8
                                QQC.Label {
                                    text: "Row " + modelData.row
                                    color: "#9a3412"
                                    font.pixelSize: 10
                                    font.bold: true
                                    Layout.preferredWidth: 50
                                }
                                QQC.Label {
                                    id: issTxt
                                    text: modelData.message
                                    color: "#9a3412"
                                    font.pixelSize: 12
                                    Layout.fillWidth: true
                                    wrapMode: Text.Wrap
                                }
                            }
                        }
                    }
                    QQC.Label {
                        visible: root._issueRows.length === 0
                        text: "No issues — all rows look good."
                        color: "#16a34a"
                        font.pixelSize: 12
                        Layout.fillWidth: true
                        Layout.topMargin: 12
                    }
                }
            }
        }

        // Footer
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            QQC.Button {
                text: "Cancel"
                onClicked: root.close()
            }
            Item { Layout.fillWidth: true }
            QQC.Button {
                text: "Import " + root._effectiveCount() + " row" + (root._effectiveCount() === 1 ? "" : "s")
                enabled: root._effectiveCount() > 0
                background: Rectangle { radius: 8; color: parent.enabled ? Constants.primaryBlue : "#cbd5e1" }
                contentItem: Text {
                    text: parent.text; color: "#ffffff"; font.bold: true; font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                }
                onClicked: root._apply()
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
            var row = k + 2  // header is row 1
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
            // Detect conflict
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

        // Build SKU/name lookup for line-item resolution
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
            // Parse Products cell
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

    signal importCompleted(string message)
}
