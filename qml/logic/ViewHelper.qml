import QtQuick

Item {

    // helper to format currency values for display
    function formatCurrency(val) {
        var n = typeof val === 'number' ? val : parseFloat(String(val).replace(/[^0-9.]/g, ''));
        if (isNaN(n)) n = 0;
        try { return new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 }).format(n); }
        catch(e) { return '₹' + Math.round(n).toString(); }
    }

    // helper to format large numbers
    function formatNumber(val) {
        try { return new Intl.NumberFormat('en-IN').format(val); }
        catch(e) { return String(val); }
    }
}
