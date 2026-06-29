# Known Issues

Running log of accepted, non-blocking issues deferred for later. Each entry: what's
broken, where, why it was deferred, and leads for a future fix.

---

## Leave-workspace: self-leave rule staged but not deployed

**Status:** Partially shipped (2026-06-12). Re-login bug is fixed in code now; clean
member-doc auto-removal awaits a Firestore rules deploy.

**What works without any deploy:** `leaveCurrentTenant()` clears the tenant pointer
(`tenantId`/`role`/`tenants[]`) on the leaver's own `users/{uid}` doc — a self-write
allowed by current live rules. This fixes the main bug (re-login no longer rejoins the
empty workspace; the user correctly lands on onboarding).

**What's deferred (needs a rules deploy):** `firestore.rules` adds a clause letting a
member delete their OWN non-owner membership (`tenants/{tid}/members/{uid}` where
`uid == request.auth.uid`). Until `firebase deploy --only firestore:rules` runs, that
self-delete is denied (403), so the leaver's member doc lingers as `status: active`.
Cosmetic only — the owner can remove the ghost member via Member Management under
current rules.

**Why not deployed now:** the repo `firestore.rules` also carries the **P0 ledger
lockdown** (`audit_log`/`transactions`/`stock_batches`/`stock_movements` → `write: if
false`). `Gateway.mode` is still `"direct"`, so the client writes those collections
directly today; deploying the repo rules before the P0 cutover would DENY those writes
and break restock/stock ops. Rules deploy is free (Spark) — the blocker is functional
(P0 not cut over), NOT the Blaze/Cloud-Functions billing requirement (functions are a
separate `--only functions` deploy).

**When to deploy:** at the P0 cutover, when `firestore.rules` ships as a unit and
`Gateway.mode` flips to `"gateway"`. The self-leave clause goes live then for free. See
the P0 compliance gateway spec.

---

## Desktop (Windows) photo picker — gallery selection still fails after picker fixes

**Status:** RESOLVED (2026-06-27). Root cause: `PhotoSourceSheet._toFileUrl` returned any
`file:`-prefixed string unchanged, so the desktop picker's malformed 2-slash `file://C:/…`
(drive letter parsed as URL host) reached both `Image.source` and `NativeFile::toReadablePath`
and silently failed. Fixed by stripping `file:` + leading slashes and rebuilding via the
drive-letter rule — the same normalization `ImportPreviewDialog._toFileUrl` already used for
the (working) desktop import path. Avatar: no such feature exists, so out of scope.

**Symptom:** On Windows desktop, Add/Edit product → "Choose from gallery" opens the native
file dialog and lets you select an image, but the picked photo still does not end up applied
(it worked end-to-end on Android device — import, export, gallery, camera all confirmed).

**Scope:** Desktop only. On Android the full photo flow (gallery + camera), import, and export
are all verified working on a real device.

**What was already fixed during Stream C (these landed and helped, but desktop still isn't
fully working):**
- `PhotoSourceSheet.qml` was missing `import Felgo` → `NativeUtils` was `undefined`, so the
  gallery handler bailed at the `typeof NativeUtils === "undefined"` guard. Fixed (commit
  `020fa85`).
- Desktop launched `displayImagePicker` (mobile-only); switched to `displayFilePicker` with a
  Qt name-filter and a `Qt.callLater` deferred launch after closing the modal sheet (commits
  `64cadc4`, `3275be1`).
- Picked Windows path (`C:/…`) mis-parsed into a broken `file://c/…` URL; added `_toFileUrl`
  normalization in `PhotoSourceSheet` and a drive-letter branch in `NativeFile::toReadablePath`
  (commits `a94dd72`, `2f6a587`).

**Leads for a future fix (desktop):**
- Capture the exact failure on desktop after the latest fixes — is it the preview `Image`
  (`AddProductDialog.qml:91`-ish `source`) still getting a bad URL, or the save path
  (`StorageService.uploadProductPhoto` → `ImageProcessor.compressForUpload` /
  `NativeFile.toReadablePath`) failing to read the normalized URL?
- Add a temporary `console.log` of `files[0]` (raw) and the `_toFileUrl(...)` result in
  `PhotoSourceSheet._onPhotoFilePicked`, plus the `compressForUpload` input, to see where the
  URL/path breaks.
- Suspect a remaining `file:///C:/…` vs `C:/…` mismatch between what `Image.source` wants
  (URL) and what `ImageProcessor`/`NativeFile` want (local path) on Windows specifically.
- Note OneDrive-managed folders in the repro path (`OneDrive - …/Pictures/`) — spaces and the
  redirected location could be a factor; test with a plain `C:\Temp\x.png` to isolate.

**Decision:** Deferred. Mobile is the shipping target and is fully working; desktop photo-add
is not required for release. Revisit if desktop becomes a supported surface.

---

## Order returns: cross-period temporal netting mismatch

When a completed order is returned/modified in a *different month* than the original sale, the
Analysis reports net the reversal in **different periods** depending on the surface:

- **Sold / Profit** are ledger-sourced (`TransactionStore` sale + return events). A return event is
  dated when the return happens, so Sold/Profit reduce the **return-month** bucket.
- **Revenue** is order-sourced (`OrdersStore.orders`, bucketed by `order.date`). `applyAdjustment`
  updates the order's lines/total but not `order.date`, so Revenue reduces the **original-sale-month**
  bucket retroactively.

Net effect for a sale in month A returned in month B: month A's Revenue drops while its Sold/Profit
stay full; month B shows the Sold/Profit reversal with no Revenue change. The "this year" hero and
all-time totals reconcile correctly; only narrower period buckets (and period-scoped exports) show
the split.

**Decision:** Accepted limitation for now (chosen during the returns/exchange brainstorm — the
"preserve consumption[] on adjusted lines" fix closed the by-supplier ₹0 bug; the temporal split was
explicitly logged here rather than re-sourcing Revenue from the ledger). Revisit when Revenue moves
to a ledger-sourced read (natural fit with the P0 immutable-ledger roadmap), at which point all three
surfaces would net in the same period.

