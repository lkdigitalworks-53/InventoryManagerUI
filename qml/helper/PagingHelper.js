.pragma library

// Pure cursor-pagination bookkeeping for stores that page Firestore
// collections via FirebaseService.query() instead of fetching everything.
// No QML imports, no singletons — everything needed is passed in, same
// convention as BreakdownMath.js / RealisedMath.js, so it's unit-testable
// via qmltestrunner without a store or network involved.
//
// The over-fetch-by-one trick: FirebaseService.query() is called with
// limit+1. mergePage() trims the extra row and uses its mere presence to
// decide hasMore, so pagination is exact at the boundary (no off-by-one
// ambiguity from "got exactly `limit` rows" which could mean "more remain"
// or "that was everything").

// existingItems: the store's current items array (already-loaded pages).
// newItems: the raw decoded page just fetched, requested at `limit + 1`.
// limit: the page size that was requested (NOT limit+1).
// Returns { items, hasMore }.
function mergePage(existingItems, newItems, limit) {
    var incoming = newItems || []
    var hasMore = incoming.length > limit
    var page = hasMore ? incoming.slice(0, limit) : incoming
    return {
        items: (existingItems || []).concat(page),
        hasMore: hasMore
    }
}

// The cursor to pass as `startAfter` on the next query() call — the last
// loaded item's value for whichever field the collection is ordered by.
// Returns null when there's nothing loaded yet (first page has no cursor).
function cursorFrom(items, orderByField) {
    if (!items || items.length === 0) return null
    var last = items[items.length - 1]
    return last ? last[orderByField] : null
}

// Convenience for a store's loadMore(): given its current paging state
// ({ items, hasMore, loadingMore }) and a freshly fetched page, returns the
// new state. Doesn't touch the network itself — the store still owns the
// FirebaseService.query() call; this just centralizes the merge + cursor
// bookkeeping that would otherwise be copy-pasted per store.
function nextState(currentState, newItems, limit, orderByField) {
    var merged = mergePage(currentState.items, newItems, limit)
    return {
        items: merged.items,
        hasMore: merged.hasMore,
        loadingMore: false,
        cursor: cursorFrom(merged.items, orderByField)
    }
}
