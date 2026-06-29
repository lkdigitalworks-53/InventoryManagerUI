import QtQuick

Item {

    // helper to format currency values for display
    function formatCurrency(val) {
        var n = typeof val === 'number' ? val : parseFloat(String(val).replace(/[^0-9.]/g, ''));
        if (isNaN(n)) n = 0;
        // Show up to 1 decimal (so a ₹4.5 discount reads as ₹4.5, not a
        // rounded-to-₹5 that no longer reconciles with the total). Integers
        // stay clean via minimumFractionDigits 0.
        try { return new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', minimumFractionDigits: 0, maximumFractionDigits: 1 }).format(n); }
        catch(e) { return '₹' + (Math.round(n * 10) / 10).toString(); }
    }

    // helper to format large numbers
    function formatNumber(val) {
        try { return new Intl.NumberFormat('en-IN').format(val); }
        catch(e) { return String(val); }
    }
}
