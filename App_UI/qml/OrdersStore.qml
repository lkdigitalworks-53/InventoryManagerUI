
pragma Singleton
import QtQuick 6.5

ListModel {
    id: store
    property string currentSortRole: "date"
    property bool currentSortAscending: false

    ListElement { orderId: "ORD-001"; customer: "John Smith"; items: 5; total: 20495; status: "pending";   date: "2025-11-28"; notes: "" }
    ListElement { orderId: "ORD-002"; customer: "Sarah Johnson"; items: 3; total: 15791; status: "completed"; date: "2025-11-28"; notes: "" }
    ListElement { orderId: "ORD-003"; customer: "Michael Brown"; items: 7; total: 47303; status: "processing"; date: "2025-11-29"; notes: "" }
    ListElement { orderId: "ORD-004"; customer: "Anita Rao"; items: 2; total: 8250;  status: "pending";   date: "2025-11-30"; notes: "" }
    ListElement { orderId: "ORD-005"; customer: "Alex Chen"; items: 4; total: 18960; status: "completed"; date: "2025-12-01"; notes: "" }

    function pendingCount() { var c = 0; for (var i=0;i<store.count;++i) if (store.get(i).status === "pending") c++; return c; }
    function completedThisMonth() {
        var now = new Date(); var m = now.getMonth(); var y = now.getFullYear(); var c = 0;
        for (var i=0;i<store.count;++i) { var d = new Date(store.get(i).date); if (store.get(i).status === "completed" && d.getMonth()===m && d.getFullYear()===y) c++; }
        return c;
    }

    function nextOrderId() { var max=0; for (var i=0;i<store.count;++i) { var num=parseInt(String(store.get(i).orderId).split('-')[1]); if (!isNaN(num) && num>max) max=num; } return 'ORD-'+String(max+1).padStart(3,'0'); }
    function parseCurrency(str) { if (typeof str==='number') return str; if (!str) return 0; var s=String(str).replace(/[^0-9.]/g,''); var n=parseFloat(s); return isNaN(n)?0:n; }
    function formatCurrency(val) { var n=parseCurrency(val); try { return new Intl.NumberFormat('en-IN',{style:'currency',currency:'INR',maximumFractionDigits:0}).format(n); } catch(e){ return 'INR '+Math.round(n).toString(); } }

    function addOrder(customer, items, total, status, date) {
        var id = nextOrderId(); var iso = Qt.formatDate(date, 'yyyy-MM-dd');
        store.append({ orderId: id, customer: customer, items: items, total: total, status: status, date: iso, notes: "" });
        sortBy(currentSortRole, currentSortAscending);
    }

    function findIndexById(orderId) { for (var i=0;i<store.count;++i) if (store.get(i).orderId===orderId) return i; return -1; }
    function getById(orderId) { var idx = findIndexById(orderId); return idx>=0 ? store.get(idx) : null; }

    function updateOrder(orderId, fields) {
        var idx = findIndexById(orderId); if (idx<0) return; var obj = store.get(idx);
        for (var k in fields) obj[k] = (k==='total') ? formatCurrency(fields[k]) : fields[k];
        store.set(idx, obj); sortBy(currentSortRole, currentSortAscending);
    }

    function comparator(role) {
        if (role==='items') return function(a,b){ return a.items-b.items; };
        if (role==='total') return function(a,b){ return parseCurrency(a.total)-parseCurrency(b.total); };
        if (role==='date')  return function(a,b){ return (new Date(a.date))-(new Date(b.date)); };
        if (role==='orderId') return function(a,b){ var ai=parseInt(String(a.orderId).split('-')[1]); var bi=parseInt(String(b.orderId).split('-')[1]); return ai-bi; };
        return function(a,b){ return String(a[role]).localeCompare(String(b[role])); };
    }

    function sortBy(role, ascending) {
        currentSortRole = role; currentSortAscending = ascending;
        var arr=[]; for (var i=0;i<store.count;++i) arr.push(store.get(i));
        var cmp = comparator(role); arr.sort(cmp); if (!ascending) arr.reverse();
        store.clear(); for (var j=0;j<arr.length;++j) store.append(arr[j]);
    }
}
