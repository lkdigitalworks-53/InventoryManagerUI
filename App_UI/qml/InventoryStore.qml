pragma Singleton
import QtQuick 6.5
import QtCore

QtObject {
    id: root

    readonly property var _seedProducts: [
        { productId: "PRD-001", name: "Wireless Mouse",       sku: "WM-2024-001", category: "Electronics",  stock: 45, minStock: 20, price: 2499,  unit: "pcs", description: "" },
        { productId: "PRD-002", name: "USB-C Cable",          sku: "UC-2024-002", category: "Accessories",  stock: 12, minStock: 25, price: 1249,  unit: "pcs", description: "" },
        { productId: "PRD-003", name: "Laptop Stand",         sku: "LS-2024-003", category: "Accessories",  stock: 67, minStock: 15, price: 4166,  unit: "pcs", description: "" },
        { productId: "PRD-004", name: "Mechanical Keyboard",  sku: "MK-2024-004", category: "Electronics",  stock: 8,  minStock: 20, price: 7499,  unit: "pcs", description: "" },
        { productId: "PRD-005", name: "Desk Lamp",            sku: "DL-2024-005", category: "Office",       stock: 34, minStock: 10, price: 2916,  unit: "pcs", description: "" },
        { productId: "PRD-006", name: "Monitor",              sku: "MN-2024-006", category: "Electronics",  stock: 23, minStock: 10, price: 24999, unit: "pcs", description: "" }
    ]

    property var products: []

    property Settings _settings: Settings {
        category: "InventoryStore"
        property string productsJson: ""
    }

    Component.onCompleted: _load()

    function _load() {
        if (_settings.productsJson && _settings.productsJson.length > 2) {
            try { products = JSON.parse(_settings.productsJson); } catch(e) { products = _seedProducts.slice(); }
        } else {
            products = _seedProducts.slice();
        }
    }

    function _save() {
        _settings.productsJson = JSON.stringify(products);
    }

    function _commit(arr) {
        products = arr;
        _save();
    }

    function _clone() {
        var a = [];
        for (var i = 0; i < products.length; ++i) {
            var p = products[i];
            a.push({ productId: p.productId, name: p.name, sku: p.sku, category: p.category,
                      stock: p.stock, minStock: p.minStock, price: p.price, unit: p.unit, description: p.description });
        }
        return a;
    }

    function totalProducts() { return products.length; }

    function lowStockCount() {
        var c = 0;
        for (var i = 0; i < products.length; ++i)
            if (products[i].stock <= products[i].minStock) c++;
        return c;
    }

    function totalItems() {
        var c = 0;
        for (var i = 0; i < products.length; ++i)
            c += products[i].stock;
        return c;
    }

    function totalValue() {
        var v = 0;
        for (var i = 0; i < products.length; ++i)
            v += products[i].stock * products[i].price;
        return v;
    }

    function formatCurrency(val) {
        var n = typeof val === 'number' ? val : parseFloat(String(val).replace(/[^0-9.]/g, ''));
        if (isNaN(n)) n = 0;
        try { return new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 }).format(n); }
        catch(e) { return '₹' + Math.round(n).toString(); }
    }

    function nextProductId() {
        var max = 0;
        for (var i = 0; i < products.length; ++i) {
            var num = parseInt(String(products[i].productId).split('-')[1]);
            if (!isNaN(num) && num > max) max = num;
        }
        return 'PRD-' + String(max + 1).padStart(3, '0');
    }

    function generateSku(name) {
        if (!name || name.length < 2) return "";
        var words = name.trim().split(/\s+/);
        var prefix = "";
        for (var i = 0; i < Math.min(words.length, 2); ++i)
            prefix += words[i].charAt(0).toUpperCase();
        var year = new Date().getFullYear();
        var num = String(products.length + 1).padStart(3, '0');
        return prefix + "-" + year + "-" + num;
    }

    function addProduct(name, sku, category, description, price, unit, stock, minStock) {
        var id = nextProductId();
        var arr = _clone();
        arr.push({ productId: id, name: name, sku: sku, category: category,
                   stock: stock, minStock: minStock, price: price, unit: unit, description: description || "" });
        _commit(arr);
    }

    function restock(productId, amount) {
        var arr = _clone();
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].productId === productId) {
                arr[i].stock += (amount || 10);
                break;
            }
        }
        _commit(arr);
    }

    function stockStatus(p) {
        return p.stock <= p.minStock ? "Low Stock" : "In Stock";
    }

    function stockPercent(p) {
        var maxStock = Math.max(p.minStock * 3, 100);
        return Math.min(1.0, p.stock / maxStock);
    }

    function deductStock(productId, qty) {
        var arr = _clone();
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].productId === productId) {
                arr[i].stock = Math.max(0, arr[i].stock - qty);
                break;
            }
        }
        _commit(arr);
    }

    function findByName(name) {
        for (var i = 0; i < products.length; ++i)
            if (products[i].name === name) return products[i];
        return null;
    }

    function getById(productId) {
        for (var i = 0; i < products.length; ++i)
            if (products[i].productId === productId) return products[i];
        return null;
    }
}
