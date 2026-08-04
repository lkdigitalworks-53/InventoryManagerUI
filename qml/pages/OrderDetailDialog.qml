import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../helper/OrderMath.js" as OrderMath
import "../model"

// Order detail / edit — bottom sheet. Live product table with qty editing,
// totals (subtotal / GST 18% / total), product picker. Public contract:
// signal orderUpdated(orderId)
// function openFor(id)
// property string orderId, int orderIndex
BottomSheet {
    id: dlg

    sheetTitle: "Edit order " + (orderId.length > 0 ? "#" + orderId : "")
    primaryAction: "Save changes"
    secondaryAction: "Close"

    signal orderUpdated(string orderId)

    // Emitted when a COMPLETED order's lines changed — Main.qml shows the
    // confirm-on-save sheet (reason + condition) and routes to logic.adjustOrder.
    // newLines each carry their own per-line discountType/discountValue.
    signal adjustRequested(string orderId, var newLines, var originalLines)
    property string _orderStatus: ""
    property var _originalLines: []

    property string orderId: ""
    property int orderIndex: -1

    // Component 2 (async-write-sequencing design §4/§7.1): a lock is
    // acquired in the background as soon as the dialog opens (viewing is
    // never gated — only _save() checks this) and released whenever the
    // dialog closes, however it closes (onClosed already covers Save,
    // Cancel, and tap-outside uniformly). "pending" is the brief window
    // before the acquire call's response comes back; _save() treats it as
    // not-yet-safe-to-save rather than silently proceeding OR falsely
    // reporting someone else holds it. "error" (added 2026-07-29, found via
    // a real bug report) is distinct from "denied" — it means we couldn't
    // get a real answer at all (network issue, endpoint not deployed),
    // not that someone else genuinely has it. Conflating the two showed a
    // lone tester "someone else is editing this" when nobody else was.
    property string _lockState: "pending" // "pending" | "granted" | "denied" | "error"
    property var _lockHolder: null

    property var catalog: []
    property var catalogNames: []

    ListModel { id: products }

    // Mirror of StaffStore for the picker (filtered to active members).
    // Index 0 is the empty "(no staff)" row.
    property var _staffIds: [""]
    property var _staffLabels: [qsTr("Sold by (none)")]
    function _refreshStaff(preferredId) {
        var ids = [""]
        var labels = [qsTr("Sold by (none)")]
        var src = StaffStore.staff || []
        for (var i = 0; i < src.length; ++i) {
            var s = src[i]
            if (s.status && s.status !== "active") continue
            ids.push(s.staffId || s.id || "")
            labels.push(s.name || qsTr("(unnamed)"))
        }
        _staffIds = ids
        _staffLabels = labels
        if (typeof staffCombo !== "undefined") {
            staffCombo.model = labels
            staffCombo.currentIndex = preferredId ? Math.max(0, ids.indexOf(preferredId)) : 0
        }
    }

    property real _subtotal: 0
    property real _discount: 0
    property real _tax: 0
    property var _taxBreakdown: []
    property real _total: 0

    function _lineItemArray() {
        var arr = []
        for (var i = 0; i < products.count; ++i) {
            var pr = products.get(i)
            arr.push({ productId: pr.productId, name: pr.name, price: pr.price,
                         quantity: pr.quantity,
                         discountType: pr.discountType === "percent" ? "percent" : "flat",
                         discountValue: pr.discountValue || 0,
                         taxable: !!pr.taxable, taxPercent: pr.taxPercent || 0 })
        }
        return arr
    }

    // Normalized {id, q, p, dt, dv} per line for change detection (qty, price, or
    // per-line discount changed, line added or removed).
    function _lineKeys(lines) {
        var out = []
        for (var i = 0; i < lines.length; ++i)
            out.push({ id: lines[i].productId || lines[i].name, q: lines[i].quantity,
                         p: lines[i].price,
                         dt: lines[i].discountType === "percent" ? "percent" : "flat",
                         dv: lines[i].discountValue || 0 })
        return out
    }

    // Find a line in the captured original-order snapshot (_originalLines) by
    // productId. Used by the completed-order stock guard to know how many
    // units a line already held before this edit. productId-only: names can
    // duplicate across distinct products, so a name-based fallback here would
    // risk matching the wrong line's booked quantity/tax.
    function _findOriginalLine(productId) {
        var src = _originalLines || []
        if (!productId) return null
        for (var i = 0; i < src.length; ++i) {
            if (src[i].productId === productId) return src[i]
        }
        return null
    }

    function recomputeSubtotal() {
        var lineArr = _lineItemArray()
        var t = OrdersStore.computeOrderTotals(lineArr)
        _subtotal = t.subtotal
        _discount = t.discount
        _tax = t.tax
        // Force reference change so the Repeater rebuilds even when
        // computeOrderTotals returns a structurally-equal array.
        _taxBreakdown = []
        _taxBreakdown = t.taxBreakdown.slice()
        _total = t.total
        // Completed order: forecast mixed-vintage tax — units present at
        // completion keep their BOOKED rate (time-of-supply); units added in this
        // edit are taxed at the product's CURRENT rate. The re-added line stores
        // the BOOKED rate, so the current rate is resolved from inventory and
        // passed explicitly. This matches what the ledger books on Save (and what
        // the Analysis reports show). Pending orders keep the single-rate total.
        if (_orderStatus === "completed") {
            var vintageTax = 0
            var dominantRate = 0   // the rate the user most recently applied (for the row label)
            for (var i = 0; i < lineArr.length; ++i) {
                var ln = lineArr[i]
                var booked = _findOriginalLine(ln.productId)
                var inv = ln.productId ? InventoryStore.getById(ln.productId) : null
                var curRate = (inv && inv.taxable) ? (inv.taxPercent || 0) : 0
                vintageTax += OrderMath.lineTax(ln, {
                        originalQty: booked ? (booked.quantity || 0) : 0,
                        bookedRate: (booked && booked.taxable) ? (booked.taxPercent || 0) : 0,
                        currentRate: curRate })
                if (curRate > dominantRate) dominantRate = curRate
            }
            vintageTax = Math.round(vintageTax * 100) / 100
            _tax = vintageTax
            // One combined Tax row (per design): the forecast figure, labelled
            // with the dominant current rate; hidden when zero.
            _taxBreakdown = vintageTax > 0 ? [{ rate: dominantRate, amount: vintageTax }] : []
            _total = Math.round((t.subtotal - t.discount + vintageTax) * 100) / 100
        }
        var savedIdx = productCombo.currentIndex
        _rebuildCatalog()
        productCombo.currentIndex = savedIdx
    }

    function _rebuildCatalog() {
        var cat = []
        var names = []
        for (var i = 0; i < InventoryStore.products.length; ++i) {
            var p = InventoryStore.products[i]
            var avail = _availableStock(p.productId)
            var sellPrice = p.sellingPrice !== undefined ? p.sellingPrice : p.price
            cat.push({ name: p.name, price: sellPrice, productId: p.productId,
                         taxable: !!p.taxable, taxPercent: p.taxPercent || 0 })
            var productId = p.productId ? "[" + p.productId + "] " : ""
            names.push(productId + p.name + " — " + InventoryStore.formatCurrency(sellPrice) + " · avail " + avail)
        }
        catalog = cat
        catalogNames = names
    }

    function _availableStock(productId) {
        var inv = InventoryStore.getById(productId)
        if (!inv) return 0
        // Current qty for this product in the edit form.
        var used = 0
        for (var i = 0; i < products.count; ++i)
            if (products.get(i).productId === productId)
                used = products.get(i).quantity
        if (_orderStatus === "completed") {
            // Completed orders already deducted their ORIGINAL units from
            // inv.stock at completion. Available = on-hand + units freed by
            // reducing below the original qty (and − units pulled by adding
            // above it). So reducing a line raises the count, adding lowers it,
            // and at the unchanged baseline available == true on-hand.
            var orig = _findOriginalLine(productId)
            var origQty = orig ? (orig.quantity || 0) : 0
            return Math.max(0, inv.stock + (origQty - used))
        }
        // Pending/processing: units not deducted yet — subtract the cart qty.
        return Math.max(0, inv.stock - used)
    }

    function openFor(id) {
        orderId = id

        var allOrders = OrdersStore.orders
        var o = null
        for (var i = 0; i < allOrders.length; ++i)
            if (allOrders[i].orderId === id) { o = allOrders[i]; break }
        if (!o) return

        // Seed status + the original-lines snapshot BEFORE any catalog build,
        // because _availableStock (used by _rebuildCatalog) reads BOTH
        // _orderStatus and _originalLines. Doing the first _rebuildCatalog
        // before these were set meant it ran against the PREVIOUS order's
        // leftover state — so opening order B showed order A's available count.
        _orderStatus = String(o.status || "")
        _originalLines = (o.products || []).map(function(lp) {
            return { productId: lp.productId || "", name: lp.name, price: lp.price,
                quantity: lp.quantity,
                discountType: lp.discountType === "percent" ? "percent" : "flat",
                discountValue: parseFloat(lp.discountValue) || 0,
                // Booked tax — used to re-seed a re-added line on a COMPLETED
                // order at its time-of-supply rate, not the product's current one.
                taxable: !!lp.taxable,
                taxPercent: lp.taxPercent || 0,
                consumption: lp.consumption || [] }
        })
        _rebuildCatalog()

        customerField.text = o.customer
        emailField.text = o.email || ""
        phoneField.text = o.phone || ""
        statusCombo.currentIndex = ["pending","processing","completed"].indexOf(String(o.status))
        if (statusCombo.currentIndex < 0) statusCombo.currentIndex = 0

        // Channel + staff: pre-fill from the existing order. The channel
        // string is matched against the configured list — when the order
        // referenced a channel that's since been removed, the picker falls
        // back to the default index so save doesn't accidentally clear the
        // value.
        // Keep channelCombo's declarative `model: OrderChannelStore.channels`
        // binding intact (don't reassign .model) so the dropdown reflects
        // add/remove changes live. Only set the selected index.
        var chIdx = OrderChannelStore.channels.indexOf(o.orderChannel || "")
        channelCombo.currentIndex = chIdx >= 0 ? chIdx : OrderChannelStore.indexOfDefault()
        dlg._refreshStaff(o.staffId || "")

        products.clear()
        // An order that HAS a products array (even empty, e.g. after a full
        // return) shows exactly those lines. The synthesis fallback below is
        // ONLY for legacy orders that never stored a products array at all.
        if (Array.isArray(o.products)) {
            for (var j = 0; j < o.products.length; ++j) {
                var lp = o.products[j]
                var inv = lp.productId ? InventoryStore.getById(lp.productId) : null
                var taxable = lp.taxable !== undefined ? !!lp.taxable : (inv ? !!inv.taxable : false)
                var taxPercent = lp.taxPercent !== undefined && lp.taxPercent !== null
                        ? Number(lp.taxPercent)
                        : (inv && taxable ? Number(inv.taxPercent || 0) : 0)
                products.append({
                                    productId: lp.productId || "",
                                    name: lp.name,
                                    price: lp.price,
                                    quantity: lp.quantity,
                                    discountType: lp.discountType === "percent" ? "percent" : "flat",
                                    discountValue: parseFloat(lp.discountValue) || 0,
                                    taxable: taxable,
                                    taxPercent: isNaN(taxPercent) ? 0 : taxPercent
                                })
            }
        } else {
            var itemCount = o.items
            if (catalog.length >= 2 && itemCount >= 2) {
                var qty1 = Math.ceil(itemCount / 2)
                var qty2 = itemCount - qty1
                products.append({ productId: catalog[0].productId, name: catalog[0].name, price: catalog[0].price, quantity: qty1,
                                    discountType: "flat", discountValue: 0,
                                    taxable: catalog[0].taxable, taxPercent: catalog[0].taxPercent })
                if (qty2 > 0) products.append({ productId: catalog[1].productId, name: catalog[1].name, price: catalog[1].price, quantity: qty2,
                                                  discountType: "flat", discountValue: 0,
                                                  taxable: catalog[1].taxable, taxPercent: catalog[1].taxPercent })
            } else if (catalog.length > 0) {
                products.append({ productId: catalog[0].productId, name: catalog[0].name, price: catalog[0].price, quantity: Math.max(1, itemCount),
                                    discountType: "flat", discountValue: 0,
                                    taxable: catalog[0].taxable, taxPercent: catalog[0].taxPercent })
            }
        }
        recomputeSubtotal()
        productCombo.currentIndex = 0
        stockErrorLabel.text = ""

        // Acquire in the background — the dialog opens and shows the order
        // immediately either way (reads are never gated). Only _save()
        // actually checks _lockState; a denial here just means Save will
        // report it when the user gets there, not that viewing is blocked.
        _lockState = "pending"
        _lockHolder = null
        var openedOrderId = id
        LockManager.acquire("order", id, function(result) {
            if (dlg.orderId !== openedOrderId) return // dialog moved on to a different order
            _lockState = result.granted ? "granted" : result.reason // "denied" or "error"
            _lockHolder = result.holder
        })

        open()
    }

    // Clear all per-order edit state when the dialog closes (Save, Cancel, or
    // tap-outside) so a cancelled edit never bleeds into the next order opened —
    // notably the available-stock count, which derives from products +
    // _originalLines + _orderStatus.
    onClosed: {
        LockManager.release("order", orderId)
        _lockState = "pending"
        _lockHolder = null
        products.clear()
        _originalLines = []
        _orderStatus = ""
        stockErrorLabel.text = ""
    }

    onPrimaryClicked: _save()

    function _save() {
        if (_lockState !== "granted") {
            if (_lockState === "denied") {
                stockErrorLabel.text = _lockHolder && _lockHolder.name
                    ? qsTr("%1 is currently updating this order — try again shortly").arg(_lockHolder.name)
                    : qsTr("This order is currently being updated elsewhere — try again shortly")
            } else if (_lockState === "error") {
                stockErrorLabel.text = qsTr("Couldn't confirm this order is free to edit (connection issue) — try again")
            } else {
                stockErrorLabel.text = qsTr("Still confirming this order is free to edit — try again in a moment")
            }
            return
        }
        var itemCount = 0
        var prods = []
        var stockErrors = []
        for (var i = 0; i < products.count; ++i) {
            var p = products.get(i)
            itemCount += p.quantity
            // Keep the line's tax as the order booked it. For a COMPLETED order,
            // units added after a product tax change are taxed at the CURRENT
            // rate — but that's booked on a SEPARATE sale event in
            // DataModel._tryAdjustOrder (the original units must stay at their
            // booked tax). Re-seeding the whole line here would retroactively
            // re-tax the originals, which is wrong; so the order line keeps its
            // existing tax flags. (Pending orders: lines carry the tax picked at
            // creation, refreshed via the catalog when a product is added.)
            var taxable = !!p.taxable, taxPercent = p.taxPercent || 0
            prods.push({ productId: p.productId || "", name: p.name, price: p.price,
                           quantity: p.quantity,
                           discountType: p.discountType === "percent" ? "percent" : "flat",
                           discountValue: p.discountValue || 0,
                           taxable: taxable, taxPercent: taxPercent })
            var inv = InventoryStore.getById(p.productId)
            // Stock check is only about units that must come OUT of on-hand
            // stock on save. For a pending order that's the whole line. For a
            // COMPLETED order the original units were already deducted at
            // completion, so only the qty ADDED beyond the original line needs
            // to be available — a return/reduction (qty <= original) never
            // trips the guard even when on-hand is now low.
            var needFromStock = p.quantity
            if (_orderStatus === "completed") {
                var origLine = _findOriginalLine(p.productId)
                var origQty = origLine ? (origLine.quantity || 0) : 0
                needFromStock = Math.max(0, p.quantity - origQty)
            }
            if (inv && needFromStock > inv.stock)
                stockErrors.push(p.name + ": only " + inv.stock + " in stock, need " + needFromStock + " more")
        }
        if (stockErrors.length > 0) {
            stockErrorLabel.text = stockErrors.join("\n")
            return
        }
        stockErrorLabel.text = ""

        // A completed order's line edits are returns/exchanges/modifications —
        // route through the confirm-on-save sheet (Main.qml) instead of a plain
        // update, so stock + sale ledger get reversed correctly. Only when the
        // lines actually changed; other field edits (customer, channel) on a
        // completed order still use the normal update path below.
        if (_orderStatus === "completed") {
            // _lineKeys now folds per-line discount (dt/dv) into the comparison,
            // so a discount-only edit on a surviving line is detected here too and
            // routed through the adjust/ledger path (per-line discount event).
            var linesChanged = JSON.stringify(_lineKeys(prods)) !== JSON.stringify(_lineKeys(_originalLines))
            if (linesChanged) {
                dlg.adjustRequested(dlg.orderId, prods, dlg._originalLines)
                dlg.close()
                return
            }
        }

        var statuses = ["pending","processing","completed"]
        var chIdx = channelCombo.currentIndex
        var channel = (chIdx >= 0 && chIdx < OrderChannelStore.channels.length)
                ? OrderChannelStore.channels[chIdx]
                : ""
        var staffId = staffCombo.currentIndex > 0
                ? dlg._staffIds[staffCombo.currentIndex]
                : ""
        logic.updateOrder(dlg.orderId, {
                              customer: customerField.text,
                              email: emailField.text,
                              phone: phoneField.text,
                              status: statuses[Math.max(0, statusCombo.currentIndex)] || "pending",
                              items: itemCount,
                              products: prods,
                              orderChannel: channel,
                              staffId: staffId
                          })
        dlg.orderUpdated(dlg.orderId)
        dlg.close()
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        // Customer block
        Text {
            text: "Customer"
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
        }

        AuthTextField {
            id: customerField
            Layout.fillWidth: true
            label: "Name"
            placeholderText: "Customer name"
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            AuthTextField {
                id: emailField
                Layout.fillWidth: true
                label: "Email"
                placeholderText: "name@example.com"
                inputMethodHints: Qt.ImhEmailCharactersOnly
            }
            AuthTextField {
                id: phoneField
                Layout.fillWidth: true
                label: "Phone"
                placeholderText: "+91 98765 43210"
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: dp(4)
            Text {
                text: "Status"
                color: Constants.textSecondary
                font.pixelSize: sp(Constants.fsSmall)
                font.bold: true
            }
            AppComboBox {
                id: statusCombo
                Layout.fillWidth: true
                model: ["pending", "processing", "completed"]
                font.pixelSize: sp(Constants.fsBody)
            }
        }

        // Order channel + staff (sold-by). Read-only fields would normally
        // sit in a banner, but the dialog is a single edit form so the
        // pickers live alongside Status. A `dlg.staffId` getter feeds _save.
        Text {
            text: qsTr("Channel & sold by")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            AppComboBox {
                id: channelCombo
                Layout.fillWidth: true
                model: OrderChannelStore.channels
                font.pixelSize: sp(Constants.fsBody)
            }
            AppComboBox {
                id: staffCombo
                Layout.fillWidth: true
                model: dlg._staffLabels
                font.pixelSize: sp(Constants.fsBody)
                // Staff can't reassign who sold an order — matches the lock in
                // NewOrderDialog so the attribution can't be changed after the
                // fact from a staff account.
                enabled: !AuthStore.isStaffRole
                displayText: currentIndex > 0
                             ? currentText
                             : qsTr("Sold by (none)")
            }
        }

        // Products block
        Text {
            text: "Items"
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }

        // Picker
        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            AppComboBox {
                id: productCombo
                Layout.fillWidth: true
                model: dlg.catalogNames
                font.pixelSize: sp(Constants.fsBody)
            }
            IconActionButton {
                variant: "default"
                iconName: "add"
                onClicked: {
                    var idx = productCombo.currentIndex
                    if (idx < 0 || idx >= dlg.catalog.length) return
                    var p = dlg.catalog[idx]
                    var avail = dlg._availableStock(p.productId)
                    if (avail <= 0) return
                    // Match the existing cart row by productId, not name — two
                    // distinct products can legitimately share a display name,
                    // and matching by name here would silently bump the WRONG
                    // product's quantity (and its price/tax) instead of adding
                    // this one as its own line.
                    for (var i = 0; i < products.count; ++i) {
                        if (products.get(i).productId === p.productId) {
                            products.setProperty(i, "quantity", products.get(i).quantity + 1)
                            dlg.recomputeSubtotal()
                            return
                        }
                    }
                    // On a COMPLETED order, a product that was on the order at
                    // completion is re-added at its BOOKED tax (time-of-supply),
                    // NOT the product's current rate — re-taxing already-supplied
                    // units would diverge from the immutable sale ledger and
                    // overstate the total. Genuinely new products (no booked line)
                    // and pending orders use the current catalog rate.
                    var booked = dlg._orderStatus === "completed"
                            ? dlg._findOriginalLine(p.productId) : null
                    var addTaxable = booked ? !!booked.taxable : !!p.taxable
                    var addTaxPercent = booked ? (booked.taxPercent || 0) : (p.taxPercent || 0)
                    products.append({ productId: p.productId, name: p.name, price: p.price, quantity: 1,
                                        discountType: "flat", discountValue: 0,
                                        taxable: addTaxable, taxPercent: addTaxPercent })
                    dlg.recomputeSubtotal()
                }
            }
        }

        // Line items as cards (Repeater, not ListView, to avoid nested-scroll
        // conflicts with the BottomSheet's outer ScrollView).
        ColumnLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            Repeater {
                model: products
                delegate: ColumnLayout {
                    id: row
                    property int rowIdx: index
                    // Capture the delegate model's discount fields here so the
                    // per-line SegmentedPill (whose own `model` property shadows
                    // the delegate `model`) can still read them.
                    property string lineDiscType: model.discountType === "percent" ? "percent" : "flat"
                    property real lineDiscValue: model.discountValue || 0
                    Layout.fillWidth: true
                    spacing: dp(4)

                  ListCard {
                    Layout.fillWidth: true
                    title: model.name
                    subtitle: {
                        var inv = model.productId ? InventoryStore.getById(model.productId) : null
                        var sku = inv && inv.sku ? inv.sku + " · " : ""
                        return model.productId + " | " + sku + OrdersStore.formatCurrency(model.price) + " × " + model.quantity
                                + " = " + OrdersStore.formatCurrency(model.price * model.quantity)
                    }

                    leading: AvatarBadge {
                        label: (model.name || "?").charAt(0).toUpperCase()
                        palette: index % 4 === 0 ? Constants.grad1
                                                 : index % 4 === 1 ? Constants.grad2
                                                                   : index % 4 === 2 ? Constants.grad3
                                                                                     : Constants.grad4
                    }

                    RowLayout {
                        spacing: dp(4)
                        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight

                        // Editable per-line unit price. Commits on focus-loss /
                        // accept (never per-keystroke) so the subtitle's
                        // model.price binding and this field don't form a loop.
                        // Shows a plain number while focused for easy typing,
                        // formatted currency otherwise. The delegate is rebuilt
                        // per row, so seeding `text` from model.price is safe.
                        QQC.TextField {
                            id: priceField
                            Layout.preferredWidth: dp(64)
                            Layout.alignment: Qt.AlignVCenter
                            text: OrdersStore.formatCurrency(model.price)
                            inputMethodHints: Qt.ImhFormattedNumbersOnly
                            font.pixelSize: sp(Constants.fsBody)
                            horizontalAlignment: Text.AlignRight
                            selectByMouse: true
                            padding: 0
                            leftPadding: dp(6)
                            rightPadding: dp(6)
                            topPadding: dp(6)
                            bottomPadding: dp(6)
                            background: Rectangle {
                                radius: dp(8)
                                color: priceField.enabled ? Constants.cardBg : Constants.subtleBg
                                border.color: priceField.activeFocus ? Constants.primaryBlue : Constants.borderColor
                                border.width: priceField.activeFocus ? 2 : 1
                            }
                            onActiveFocusChanged: {
                                if (activeFocus) {
                                    text = String(model.price)
                                    selectAll()
                                } else {
                                    text = OrdersStore.formatCurrency(model.price)
                                }
                            }
                            function _commitPrice() {
                                var v = parseFloat(String(text).replace(/[^0-9.]/g, ""))
                                if (!isNaN(v) && v >= 0) {
                                    products.setProperty(row.rowIdx, "price", v)
                                    dlg.recomputeSubtotal()
                                }
                                // Re-sync the field to whatever actually committed
                                // (rejects empty/NaN/negative by keeping old price).
                                var cur = products.get(row.rowIdx)
                                text = OrdersStore.formatCurrency(cur ? cur.price : model.price)
                            }
                            onEditingFinished: _commitPrice()
                            onAccepted: _commitPrice()
                        }

                        QQC.AbstractButton {
                            Layout.preferredWidth: dp(28); Layout.preferredHeight: dp(28)
                            implicitWidth: dp(28); implicitHeight: dp(28)
                            padding: 0
                            background: Rectangle { radius: dp(8); border.color: Constants.borderColor; border.width: 1; color: "transparent" }
                            contentItem: Item {
                                Icon { anchors.centerIn: parent; name: "remove"; size: sp(16); color: Constants.textPrimary }
                            }
                            onClicked: {
                                var q = model.quantity - 1
                                if (q <= 0) {
                                    Qt.callLater(dlg.recomputeSubtotal)
                                    // Removing the row destroys THIS delegate (and
                                    // its JS context), so a recompute called inline
                                    // right after may not run — defer it to the event
                                    // loop where it executes in the dialog's context.
                                    products.remove(row.rowIdx)
                                } else {
                                    products.setProperty(row.rowIdx, "quantity", q)
                                    dlg.recomputeSubtotal()
                                }
                            }
                        }
                        Text {
                            text: String(model.quantity)
                            color: Constants.textPrimary
                            font.pixelSize: sp(Constants.fsBody)
                            font.bold: true
                            Layout.preferredWidth: dp(22)
                            horizontalAlignment: Text.AlignHCenter
                        }
                        QQC.AbstractButton {
                            Layout.preferredWidth: dp(28); Layout.preferredHeight: dp(28)
                            implicitWidth: dp(28); implicitHeight: dp(28)
                            padding: 0
                            background: Rectangle { radius: dp(8); border.color: Constants.borderColor; border.width: 1; color: "transparent" }
                            contentItem: Item {
                                Icon { anchors.centerIn: parent; name: "add"; size: sp(16); color: Constants.textPrimary }
                            }
                            onClicked: {
                                // Ceiling for this line's qty:
                                // • pending/processing: raw on-hand (units not
                                // deducted yet, so can't exceed stock).
                                // • completed: this order's units are ALREADY out
                                // of stock, so the ceiling is the original line
                                // qty PLUS whatever remains on hand
                                // (inv.stock + origQty). Capping at inv.stock
                                // alone would wrongly snap qty DOWN when the
                                // line already exceeds depleted on-hand.
                                var inv = model.productId ? InventoryStore.getById(model.productId) : null
                                var onHand = inv ? inv.stock : model.quantity + 1
                                var maxQ = onHand
                                if (dlg._orderStatus === "completed") {
                                    var orig = dlg._findOriginalLine(model.productId)
                                    maxQ = onHand + (orig ? (orig.quantity || 0) : 0)
                                }
                                var q = Math.min(maxQ, model.quantity + 1)
                                // Never let the cap pull qty below the current
                                // value (defensive: a stale/low cap shouldn't
                                // reduce on a "+").
                                if (q < model.quantity) q = model.quantity
                                products.setProperty(row.rowIdx, "quantity", q)
                                dlg.recomputeSubtotal()
                            }
                        }
                        QQC.AbstractButton {
                            Layout.preferredWidth: dp(28); Layout.preferredHeight: dp(28)
                            implicitWidth: dp(28); implicitHeight: dp(28)
                            padding: 0
                            background: Rectangle { radius: dp(8); color: "transparent" }
                            contentItem: Item {
                                Icon { anchors.centerIn: parent; name: "close"; size: sp(14); color: Constants.danger }
                            }
                            // Defer recompute: products.remove destroys this
                            // delegate's context, so run it on the event loop.
                            onClicked: { Qt.callLater(dlg.recomputeSubtotal); products.remove(row.rowIdx) }
                        }
                    }
                  }

                  // ── Per-line discount (₹ / %) ───────────────────────────
                  // Edits this working line's discountType/discountValue.
                  // Mirrors how qty/price commit back into the products model;
                  // recompute keeps the summed totals (dlg._discount) in sync.
                  RowLayout {
                      Layout.fillWidth: true
                      Layout.leftMargin: dp(14)
                      Layout.rightMargin: dp(14)
                      Layout.bottomMargin: dp(Constants.space2)
                      spacing: dp(Constants.space2)

                      Text {
                          text: qsTr("Discount")
                          color: Constants.textSecondary
                          font.pixelSize: sp(Constants.fsSmall)
                          font.bold: true
                      }
                      SegmentedPill {
                          id: lineDiscountTypeToggle
                          Layout.preferredWidth: dp(72)
                          model: ["₹", "%"]
                          selected: row.lineDiscType === "percent" ? 1 : 0
                          onSegmentSelected: function(idx, label) {
                              products.setProperty(row.rowIdx, "discountType",
                                                   idx === 1 ? "percent" : "flat")
                              dlg.recomputeSubtotal()
                          }
                      }
                      QQC.TextField {
                          id: lineDiscountField
                          Layout.fillWidth: true
                          text: String(row.lineDiscValue || 0)
                          inputMethodHints: Qt.ImhFormattedNumbersOnly
                          font.pixelSize: sp(Constants.fsBody)
                          horizontalAlignment: Text.AlignRight
                          selectByMouse: true
                          padding: 0
                          leftPadding: dp(6); rightPadding: dp(6)
                          topPadding: dp(6); bottomPadding: dp(6)
                          background: Rectangle {
                              radius: dp(8)
                              color: lineDiscountField.enabled ? Constants.cardBg : Constants.subtleBg
                              border.color: lineDiscountField.activeFocus ? Constants.primaryBlue : Constants.borderColor
                              border.width: lineDiscountField.activeFocus ? 2 : 1
                          }
                          function _commitDiscount() {
                              var v = parseFloat(String(text).replace(/[^0-9.]/g, ""))
                              if (isNaN(v) || v < 0) v = 0
                              products.setProperty(row.rowIdx, "discountValue", v)
                              dlg.recomputeSubtotal()
                              var cur = products.get(row.rowIdx)
                              text = String(cur ? (cur.discountValue || 0) : v)
                          }
                          onEditingFinished: _commitDiscount()
                          onAccepted: _commitDiscount()
                      }
                  }
                }
            }
        }

        // Stock errors
        Text {
            id: stockErrorLabel
            Layout.fillWidth: true
            visible: text.length > 0
            text: ""
            color: Constants.danger
            font.pixelSize: sp(Constants.fsSmall)
            wrapMode: Text.Wrap
        }

        // Totals strip
        // Per-line discounts are edited on each line row above; the summed
        // discount (dlg._discount) shows in the Discount total below.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: totalsCol.implicitHeight + dp(Constants.space4 * 2)
            radius: dp(Constants.radius)
            color: Constants.subtleBg
            border.color: Constants.borderColor
            border.width: 1

            ColumnLayout {
                id: totalsCol
                anchors.fill: parent
                anchors.margins: dp(Constants.space4)
                spacing: dp(4)

                RowLayout {
                    Layout.fillWidth: true
                    Text { text: qsTr("Subtotal"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsBody); Layout.fillWidth: true }
                    Text { text: OrdersStore.formatCurrency(dlg._subtotal); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsBody) }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: dlg._discount > 0
                    Text { text: qsTr("Discount"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsBody); Layout.fillWidth: true }
                    Text { text: "− " + OrdersStore.formatCurrency(dlg._discount); color: Constants.success; font.pixelSize: sp(Constants.fsBody) }
                }
                Repeater {
                    model: dlg._taxBreakdown
                    delegate: RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: qsTr("Tax (%1%)").arg(modelData.rate)
                            color: Constants.textSecondary
                            font.pixelSize: sp(Constants.fsBody)
                            Layout.fillWidth: true
                        }
                        Text {
                            text: OrdersStore.formatCurrency(modelData.amount)
                            color: Constants.textPrimary
                            font.pixelSize: sp(Constants.fsBody)
                        }
                    }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: Constants.borderColor }
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: qsTr("Total"); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsBodyLg); font.bold: true; Layout.fillWidth: true }
                    Text { text: OrdersStore.formatCurrency(dlg._total); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsBodyLg); font.bold: true }
                }
            }
        }

        // ── Order history / timeline (bug 18) ───────────────────────────
        // The sell-cycle events for THIS order: original sale lines, plus
        // returns / exchanges / price modifies / discount adjustments /
        // reopen reversals. Previously this lived only in the product
        // dialog; the order is the natural place to audit an order's life.
        Text {
            text: qsTr("Order history")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
            visible: orderHistory._events.length > 0
        }
        ColumnLayout {
            id: orderHistory
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            visible: _events.length > 0

            // Binding (re-evaluates on revision bump or order switch).
            property var _events: {
                var w = TransactionStore.revision // refresh dependency
                return dlg.orderId.length > 0
                        ? TransactionStore.forOrder(dlg.orderId)
                        : []
            }

            function _iconFor(e) {
                if (e.kind === "sale") return "sale"
                if (e.kind === "return") return "sale"
                return "field_change" // price_adjust / discount
            }

            function _titleFor(e) {
                if (e.kind === "sale")
                    return qsTr("Sold %1 × %2").arg(e.quantity || 0).arg(e.productName || qsTr("item"))
                if (e.kind === "return") {
                    var q = Math.abs(e.quantity || 0)
                    var verb = e.reason === "exchange" ? qsTr("Exchanged")
                                                       : e.reason === "modify" ? qsTr("Modified")
                                                                               : e.reason === "reopened" ? qsTr("Reversed")
                                                                                                         : e.reason === "other" ? qsTr("Adjusted")
                                                                                                                                : qsTr("Returned")
                    var head = verb + qsTr(" %1 × %2").arg(q).arg(e.productName || qsTr("item"))
                    if (e.condition === "damaged") head += qsTr(" · damaged")
                    return head
                }
                // price_adjust: discount edit (productName "Discount") or a
                // per-line price modify.
                if (e.reason === "discount")
                    return qsTr("Discount changed")
                return qsTr("Price adjusted · %1").arg(e.productName || qsTr("item"))
            }

            function _detailFor(e) {
                var parts = []
                if (e.kind === "price_adjust" || e.kind === "return") {
                    if (e.reason)
                        parts.push(e.reason.charAt(0).toUpperCase() + e.reason.slice(1))
                }
                if (e.note && e.note.length > 0) parts.push(e.note)
                return parts.join(" · ")
            }

            Repeater {
                model: orderHistory._events
                delegate: Rectangle {
                    id: ohRow
                    Layout.fillWidth: true
                    radius: dp(Constants.radius)
                    color: Constants.cardBg
                    border.color: Constants.borderColor
                    border.width: 1
                    Layout.preferredHeight: ohCol.implicitHeight + dp(Constants.space3 * 2)

                    readonly property string _detail: orderHistory._detailFor(modelData)
                    readonly property string _sku: {
                        if (!modelData.productId) return ""
                        var inv = InventoryStore.getById(modelData.productId)
                        return inv && inv.sku ? inv.sku : ""
                    }

                    ColumnLayout {
                        id: ohCol
                        anchors.fill: parent
                        anchors.margins: dp(Constants.space3)
                        spacing: dp(2)

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: dp(Constants.space2)
                            Icon {
                                name: orderHistory._iconFor(modelData)
                                size: sp(16)
                                color: Constants.textSecondary
                            }
                            Text {
                                Layout.fillWidth: true
                                text: orderHistory._titleFor(modelData)
                                color: Constants.textPrimary
                                font.pixelSize: sp(Constants.fsBody)
                                font.bold: true
                                elide: Text.ElideRight
                                wrapMode: Text.Wrap
                            }
                            Text {
                                text: ActivityLog.timeAgo(modelData.timestamp)
                                color: Constants.textMuted
                                font.pixelSize: sp(Constants.fsCaption)
                            }
                        }
                        Text {
                            visible: ohRow._sku.length > 0
                            text: qsTr("%1 | SKU: %2 | ₹%3").arg(modelData.productId).arg(ohRow._sku).arg(modelData.unitPrice)
                            color: Constants.textSecondary
                            font.pixelSize: sp(Constants.fsCaption)
                        }
                        Text {
                            visible: ohRow._detail.length > 0
                            text: ohRow._detail
                            color: Constants.textSecondary
                            font.pixelSize: sp(Constants.fsCaption)
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                        }
                    }
                }
            }
        }
    }
}
