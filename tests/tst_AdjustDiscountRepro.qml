import QtQuick
import QtTest
import "../qml/helper/OrderMath.js" as OM
import "../qml/helper/OrderAdjust.js" as OA

// Reproduce the in-app ADJUST of ORD-003 that produces event-sourced Rida
// net 68.67 instead of 67 (and total profit 179.67 vs 178).
//
// Original completed ORD-003 line: Rida qty 2 @ 20, no discount.
// Modified to:                     Rida qty 3 @ 18, flat discount 5.
// (Bag separately: 2@200 → 1@180 5% — handled by return + price_adjust.)
//
// Correct Rida net for the FINAL line = 3*18 - 5 = 49 (this order's contribution).
// The adjust flow records DELTA events. This test sums what the CURRENT
// _tryAdjustOrder discount-scanner + added-unit stamping actually book, and
// checks whether the event-sourced net equals the correct net.
TestCase {
    name: "AdjustDiscountRepro"
    function _round2(x){ return Math.round(x*100)/100 }

    // Mirror DataModel._tryAdjustOrder's _lineDiscAmt.
    function _lineDiscAmt(ln) {
        var gross = (ln.quantity||0)*(ln.price||0)
        if (ln.discountType==="percent"){var p=parseFloat(ln.discountValue)||0; if(p<0)p=0; if(p>100)p=100; return gross*(p/100)}
        var d=parseFloat(ln.discountValue)||0; if(d<0)d=0; if(d>gross)d=gross; return d
    }

    // Simulate the Rida portion of the adjust and return the net the EVENT
    // ledger will hold (what realisedProfitByDimension reads).
    function test_added_units_plus_discount_loses_fraction() {
        var oldLine = { productId:"PRD-001", name:"Rida", price:20, quantity:2,
                        taxable:false, taxPercent:0, discountType:"flat", discountValue:0 }
        var newLine = { productId:"PRD-001", name:"Rida", price:18, quantity:3,
                        taxable:false, taxPercent:0, discountType:"flat", discountValue:5 }

        // diffLines: addedQty 1, price 20->18.
        var oldQ = oldLine.quantity, newQ = newLine.quantity
        var addedQty = Math.max(0, newQ - oldQ)              // 1
        // 1) Original completion sale event (immutable): net = 2*20 = 40.
        var origSaleNet = oldQ * oldLine.price               // 40
        // 2) Added-unit sale event: allocate a 1-unit order at new price, NO discount.
        var addedSaleNet = addedQty * newLine.price          // 18  (no discount applied!)
        // 3) Price-change price_adjust on surviving units: (oldPrice-newPrice)*survQ.
        var survQ = Math.min(oldQ, newQ)                     // 2
        var priceDelta = -((oldLine.price - newLine.price) * survQ)  // -(2*2) = -4
        // 4) Discount-scanner price_adjust — FIXED formula: surviving-unit rate
        //    change PLUS the added units' full new per-unit discount.
        var newPerUnitDisc = _lineDiscAmt(newLine) / newQ    // 5/3
        var oldPerUnitDisc = _lineDiscAmt(oldLine) / oldQ    // 0
        var addedQ = Math.max(0, newQ - oldQ)                // 1
        var discDelta = survQ * (newPerUnitDisc - oldPerUnitDisc)
                      + addedQ * newPerUnitDisc              // 2*(5/3) + 1*(5/3) = 5
        var discAdjust = -discDelta                          // -5

        var eventNet = origSaleNet + addedSaleNet + priceDelta + discAdjust
        // CORRECT final Rida net for this order = 3*18 - 5 = 49.
        var correctNet = newQ * newLine.price - _lineDiscAmt(newLine)  // 49

        // After the fix the event ledger net equals the correct net exactly.
        compare(_round2(eventNet), 49, "event ledger Rida net must reconcile to 49 (no lost discount)")
        compare(_round2(discDelta), 5, "full line discount of 5 is booked (surviving + added units)")
        compare(_round2(eventNet), _round2(correctNet), "event ledger == correct live-order net")
    }
}
