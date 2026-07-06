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
//   signal filePickRequested()
//   signal importCompleted(message)
//   function pickAndStart(), importFromUserPath(rawPath)
BottomSheet {
    id: root

    sheetTitle: mode === "products" ? "Import products" : "Import orders"
    primaryAction: "Import " + _effectiveCount() + " row" + (_effectiveCount() === 1 ? "" : "s")
    primaryEnabled: _effectiveCount() > 0
    secondaryAction: "Cancel"

    property string mode: "products"
    property var dataModelRef: null

    // Internal state
    property var _readyRows: []
    property var _issueRows: []
    property var _warnRows: []
    property string _fileName: ""

    signal filePickRequested()
    signal importCompleted(string message)

    function pickAndStart() {
        _readyRows = []; _issueRows = []; _warnRows = []; _fileName = ""
        filePickRequested()
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
        if (lower.indexOf("content://") === 0) return s
        // Normalize a file: URL down to its bare path so we can rebuild a VALID
        // one. The desktop picker returns a malformed 2-slash "file://C:/…",
        // where "C:" is parsed as the URL HOST and the path becomes "//c/…" →
        // QFile can't find it ("File not found"). Stripping "file:" + leading
        // slashes here, then re-applying the drive-letter rule below, turns
        // "file://C:/…", "file:///C:/…", and a raw "C:\…" all into a correct
        // "file:///C:/…". (content:// already returned above; on Android a
        // copied cache path has no scheme and flows straight through.)
        if (lower.indexOf("file:") === 0)
            s = s.substring(5).replace(/^\/+/, "")
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

            Icon {
                name: "file"
                size: sp(Constants.fsBody)
                color: Constants.textPrimary
                Layout.alignment: Qt.AlignVCenter
                visible: root._fileName.length > 0
            }
            Text {
                text: root._fileName.length > 0 ? root._fileName : qsTr("Loading…")
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
            StatusPill {
                visible: root._warnRows.length > 0
                status: "processing"
                label: root._warnRows.length + " warning" + (root._warnRows.length === 1 ? "" : "s")
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
                        id: readyRowDelegate

                        property int readyRowIndex: index

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
                                    onActivated: root._setRowPolicy(readyRowDelegate.readyRowIndex, currentText)
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

                // Warnings section (distinct from hard-reject issues)
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: dp(Constants.space3)
                    visible: root._warnRows.length > 0
                    spacing: dp(Constants.space2)

                    Text {
                        text: "Imported with warnings — these reduce report accuracy"
                        color: Constants.textSecondary
                        font.pixelSize: sp(Constants.fsSmall)
                        font.bold: true
                    }

                    Repeater {
                        model: root._warnRows
                        delegate: Rectangle {
                            Layout.fillWidth: true
                            radius: dp(Constants.radius)
                            color: Qt.rgba(1.0, 0.95, 0.8, 1.0)  // amber/warning bg
                            border.color: Qt.rgba(0.9, 0.7, 0.3, 0.5)
                            border.width: 1
                            Layout.preferredHeight: warnTxt.implicitHeight + dp(Constants.space3 * 2)

                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: dp(Constants.space3)
                                spacing: dp(Constants.space2)

                                Text {
                                    text: "Row " + modelData.row
                                    color: Qt.rgba(0.6, 0.4, 0.0, 1.0)  // dark amber
                                    font.pixelSize: sp(Constants.fsCaption)
                                    font.bold: true
                                    Layout.preferredWidth: dp(50)
                                }
                                Text {
                                    id: warnTxt
                                    text: modelData.message
                                    color: Qt.rgba(0.6, 0.4, 0.0, 1.0)
                                    font.pixelSize: sp(Constants.fsBody)
                                    Layout.fillWidth: true
                                    wrapMode: Text.Wrap
                                }
                            }
                        }
                    }
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
        var warns = []
        var existingById = {}
        for (var i = 0; i < InventoryStore.products.length; ++i) {
            var ep = InventoryStore.products[i]
            existingById[ep.productId] = ep
        }

        for (var k = 0; k < rows.length; ++k) {
            var r = rows[k]
            var row = k + 2
            var pid = (r["Product ID"] || "").toString().trim()
            var sku = (r["SKU"] || "").toString().trim()

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

            // HARD-REJECT: missing Cost Price
            var costRaw = r["Cost Price"]
            var cost = parseFloat(costRaw)
            if (isNaN(cost)) {
                issues.push({ row: row, message: "Missing Cost Price (required for value/profit reports)" })
                continue
            }
            if (cost < 0) cost = 0

            if (sell < cost) {
                issues.push({ row: row, message: "Selling Price < Cost Price" })
                continue
            }

            // DEFAULT+WARN: missing Unit
            var unit = (r["Unit"] || "").toString().trim()
            if (!unit) {
                unit = "Units (pcs)"
                warns.push({ row: row, message: name + ": Unit defaulted to 'Units (pcs)'" })
            }

            // DEFAULT+WARN: missing SKU
            if (!sku) {
                warns.push({ row: row, message: name + ": SKU will be auto-generated" })
            }

            // DEFAULT+WARN: missing PID
            if (!pid) {
                warns.push({ row: row, message: name + ": PID will be auto-generated" })
            }

            // To-Do: There are no tax information getting exported.
            // We need to export tax information as well with the product details.
            var rec = {
                row: row,
                productId: pid,
                name: name,
                sku: sku,
                category: (r["Category"] || "").toString().trim(),
                unit: unit,
                description: (r["Description"] || "").toString(),
                price: cost,
                sellingPrice: sell,
                stock: parseInt(r["Stock"]) || 0,
                minStock: parseInt(r["Min Stock"]) || 0,
                photoUrl: (r["Photo URL"] || "").toString().trim(),
                supplier: (r["Supplier"] || "").toString().trim(),
                _conflictPolicy: "skip"
            }
            var hit = null
            if (rec.productId && existingById[rec.productId]) hit = existingById[rec.productId]
            rec._conflictWith = hit ? (hit.productId + (hit.sku ? "/" + hit.sku : "")) : ""
            ready.push(rec)
        }
        _readyRows = ready
        _issueRows = issues
        _warnRows = warns
    }

    function _validateOrderRows(rows) {
        var ready = []
        var issues = []
        var warns = []
        var existingById = {}
        for (var i = 0; i < OrdersStore.orders.length; ++i)
            existingById[OrdersStore.orders[i].orderId] = OrdersStore.orders[i]

        var skuToProduct = {}
        var idToProduct = {}
        for (var ip = 0; ip < InventoryStore.products.length; ++ip) {
            var p = InventoryStore.products[ip]
            if (p.sku) skuToProduct[p.sku.toLowerCase()] = p
            idToProduct[p.productId] = p
        }

        // Group consecutive rows by Order ID. Rows missing an Order ID are
        // grouped with the previous row's order, so a multi-line order can
        // safely leave the order-header columns blank on continuation lines.
        var groups = []
        var currentKey = null
        for (var k = 0; k < rows.length; ++k) {
            var rRaw = rows[k]
            var rowNum = k + 2
            var oid = (rRaw["Order ID"] || "").toString().trim()
            // Synthetic key for orders without an ID — falls back to row index
            // so each unkeyed row becomes its own order.
            var key = oid || (currentKey && (rRaw["Customer"] || "").toString().trim() === ""
                              ? currentKey
                              : "_anon_" + rowNum)
            if (!groups.length || groups[groups.length - 1].key !== key) {
                groups.push({ key: key, rows: [], firstRow: rowNum })
            }
            groups[groups.length - 1].rows.push({ row: rowNum, raw: rRaw })
            currentKey = key
        }

        var allowed = ["pending", "processing", "completed", "out of stock"]
        for (var g = 0; g < groups.length; ++g) {
            var grp = groups[g]
            // The first row of a group carries the order-level columns. Later
            // rows may leave them blank — fall back to the first row.
            var head = grp.rows[0].raw
            var customer = (head["Customer"] || "").toString().trim()
            if (!customer) {
                issues.push({ row: grp.firstRow, message: "Missing Customer" })
                continue
            }
            var status = (head["Status"] || "").toString().trim().toLowerCase() || "pending"
            if (allowed.indexOf(status) < 0) {
                issues.push({ row: grp.firstRow, message: "Invalid Status: " + status })
                continue
            }

            // DEFAULT+WARN: missing Date
            var orderDate = (head["Date"] || "").toString().trim()
            if (!orderDate) {
                warns.push({ row: grp.firstRow, message: customer + ": Date defaulted to import day (skews time-series)" })
            }

            var prods = []
            var unresolved = []
            for (var rr = 0; rr < grp.rows.length; ++rr) {
                var lineSrc = grp.rows[rr].raw
                var lineRow = grp.rows[rr].row
                var pid = (lineSrc["Product ID"] || "").toString().trim()
                var sku = (lineSrc["SKU"] || "").toString().trim()
                var qtyRaw = lineSrc["Quantity"]
                var hasQty = qtyRaw !== undefined && qtyRaw !== null && String(qtyRaw).trim() !== ""
                var qty = parseInt(qtyRaw) || 0

                // Empty continuation line
                if (!pid && !sku && !hasQty) continue

                // HARD-REJECT LINE: has data but no identifier
                if (!pid && !sku) {
                    unresolved.push("row " + lineRow + ": missing Product ID/SKU")
                    continue
                }

                var inv = null
                if (pid && idToProduct[pid]) inv = idToProduct[pid]
                else if (sku && skuToProduct[sku.toLowerCase()]) inv = skuToProduct[sku.toLowerCase()]
                if (!inv) {
                    unresolved.push("row " + lineRow + ": " + (pid || sku || "(no id)"))
                    continue
                }

                // REJECT LINE + WARN: missing/invalid quantity
                if (!hasQty || qty <= 0) {
                    warns.push({ row: lineRow, message: inv.name + ": line skipped — missing Quantity" })
                    continue
                }

                // DEFAULT+WARN: missing Unit Price
                var unitPriceRaw = lineSrc["Unit Price"]
                var unitPrice = parseFloat(unitPriceRaw)
                if (isNaN(unitPrice)) {
                    unitPrice = inv.sellingPrice || inv.price || 0
                    warns.push({ row: lineRow, message: inv.name + ": Unit Price defaulted to current selling price (may differ from sale price)" })
                }

                var taxPctRaw = lineSrc["Tax %"]
                var taxPct = parseFloat(taxPctRaw)
                if (isNaN(taxPct)) taxPct = inv.taxable ? Number(inv.taxPercent || 0) : 0
                var taxable = taxPct > 0 || !!inv.taxable

                // Per-line discount (from LINE cells, not order-level)
                var lnDt = (lineSrc["Discount Type"] || "flat").toString().trim().toLowerCase()
                if (lnDt !== "percent") lnDt = "flat"
                var lnDv = parseFloat(lineSrc["Discount Value"])
                if (isNaN(lnDv)) lnDv = 0

                prods.push({
                    productId: inv.productId,
                    name: inv.name,
                    price: unitPrice,
                    quantity: qty,
                    taxable: taxable,
                    taxPercent: taxPct,
                    discountType: lnDt,
                    discountValue: lnDv
                })
            }
            if (unresolved.length > 0) {
                issues.push({ row: grp.firstRow, message: "Unknown product(s): " + unresolved.join("; ") })
                continue
            }

            var rec = {
                row: grp.firstRow,
                orderId: grp.key.indexOf("_anon_") === 0 ? "" : grp.key,
                customer: customer,
                email: (head["Email"] || "").toString().trim(),
                phone: (head["Phone"] || "").toString().trim(),
                status: status,
                date: orderDate,
                notes: (head["Notes"] || "").toString(),
                products: prods,
                _conflictPolicy: "skip"
            }
            rec._conflictWith = (rec.orderId && existingById[rec.orderId]) ? rec.orderId : ""
            ready.push(rec)
        }
        _readyRows = ready
        _issueRows = issues
        _warnRows = warns
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
        var counts, understocked = 0
        if (mode === "products") {
            counts = InventoryStore.upsertMany(_readyRows)
            var updatedProducts = counts.updatedProducts || []
            for (var i = 0; i < updatedProducts.length; ++i) {
                logic.updateProduct(updatedProducts[i].productId, updatedProducts[i].fields)
            }
        } else {
            counts = OrdersStore.upsertMany(_readyRows)
            // Book every newly-added COMPLETED order (anon orders got ids inside
            // upsertMany — use the returned addedIds so we don't miss them).
            var addedIds = counts.addedIds || []
            var updateOrders = counts.updatedOrders || []
            // Map added orders back to their source records to check status.
            // Newly-added records are those not skipped; match by resulting order.
            for (var i = 0; i < addedIds.length; ++i) {
                var o = OrdersStore.getById(addedIds[i])
                if (!o || o.status !== "completed") continue
                if (dataModelRef) {
                    var res = dataModelRef.completeImportedOrder(addedIds[i])
                    if (res && res.understocked) understocked++
                }
            }
            for (var j = 0; j < updateOrders.length; ++j) {
                logic.adjustOrder(updateOrders[j].orderId, updateOrders[j].products, "import orders", "", "Import conflict: Overwrite with conflicted data")
            }
        }

        var n = counts.added + counts.updated
        var msg = "Imported " + n + " row" + (n === 1 ? "" : "s")
        if (counts.skipped > 0) msg += " · " + counts.skipped + " skipped"
        if (understocked > 0) msg += " · " + understocked + " completed with insufficient stock"
        if (_warnRows.length > 0) msg += " · " + _warnRows.length + " warning(s)"

        ActivityLog.record("import",
            (mode === "products" ? "Imported products" : "Imported orders"),
            msg, "")

        importCompleted(msg)
        close()
    }
}
