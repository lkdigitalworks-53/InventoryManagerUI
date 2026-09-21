# Product photos in Firebase Storage — design

**Date:** 2026-09-21
**Branch:** `feature/2026-09-21-product-photos-firebase-storage`
**Status:** approved by Taher on 2026-09-21 (decisions Q1–Q3 below; defaults in "Assumed, not vetoed"
carried forward from the design turn because Taher said "go ahead with next steps" without objecting to them).
**Source:** Taher's request — store product photos in Firebase Storage instead of a URL string on the
product, sync across every device, support multiple photos per product for a future catalogue.

## Problem

Today `StorageService.qml` has `useCloud = false`; a photo is compressed by `ImageProcessor`, copied into
the app's local data folder, and the resulting `file://` path is written to the product's `photoUrl` field.
That path resolves only on the device that took the photo — nothing syncs. One photo per product. No
Storage rules are deployed; Cloud Storage for Firebase is on the Blaze plan, bucket
`inventorymanager-48392.firebasestorage.app`, region `asia-south1`.

## Decisions (Taher, 2026-09-21)

| # | Question | Chosen | Rejected, and why |
|---|---|---|---|
| Q1 | What the product record stores | An array of photo ids (`photoIds`), not a URL — forced by "multiple photos"; a single derived path (design-turn option A) can't hold more than one | A stored Storage *path* string (design-turn option B) — no benefit over an id once the path is computed from the id; a Storage download URL (option C) is the URL-as-text Taher explicitly wants to drop |
| Q2 | Read access | **Public by unguessable path** (random photo id, no path listing) | Private reads (signed URLs or an authed download) — costs a server round trip per photo or a new C++ HTTP cache; QML `Image` can't send an auth header; rejected as not worth it for product photos with no stated privacy need |
| Q3 | Background upload model | **Uploads while the app process is alive; resumes on next launch if the app was killed** | True OS-level background upload (Android WorkManager / iOS background session) — needs native code neither buildable nor testable in this sandbox; explicitly rejected by Taher choosing option 1 |
| — | Atomicity across Storage + Firestore | Not literally possible (two different systems, no shared transaction). Closest achievable: write bytes first, then one Firestore transaction that both records the id and its idempotency marker, so an id is never visible without its bytes. Worst case on crash is an orphaned, unreferenced object in Storage — not a corrupted product | — |

### Assumed, not vetoed (from the design turn's "unless you object" list)

- Max 10 photos per product.
- Any tenant member (not just owner/admin) may upload or remove a product photo — same as any other
  product edit today.
- The legacy `photoUrl` field is not bulk-migrated. It stays readable; the UI offers a one-tap "Upload this
  photo" action that re-enqueues the same local file through the new queue, and clears `photoUrl` once that
  upload lands. A photo taken on a device that isn't the one running this session simply isn't there to
  migrate.
- Delete cascade: when a product is deleted, its Storage objects are best-effort deleted server-side. This
  was implied by "complete the feature e2e" and by the existing (currently local-only) delete cleanup in
  `InventoryStore.deleteProduct`.
- Work is split into three PRs/commits in sequence: (1) server + Storage rules + CI, (2) client queue + UI,
  (3) migration affordance + delete cascade + docs. Each is independently reviewable and independently
  revertable.

## Data model

- `tenants/{tenantId}/inventory/{productId}` gains `photoIds: string[]` (max 10; first entry is the cover
  photo). No URL, no `photoUpdatedAt` — ids are immutable so there's nothing to bust a cache for.
- The legacy `photoUrl` (string, `file://…`) field is read-only going forward: still displayed as a fallback
  when `photoIds` is empty, never written by new code except the one-tap migration path above, which writes
  a real `photoIds` entry and then clears it.
- Storage layout: `{env}/tenants/{tenantId}/products/{productId}/{photoId}.jpg` (max edge 800px, JPEG q75 —
  unchanged from today's `ImageProcessor` settings) and `{env}/tenants/{tenantId}/products/{productId}/{photoId}_t.jpg`
  (256px, JPEG q70, new — for list/card thumbnails so `InventoryPage` doesn't pull full-size images into a
  scrolling list). `{env}` is `prd` / `test` / `dev1`, matching `FirebaseService`'s existing per-stage
  Firestore database selection, so the three environments never share objects.
- `photoId` is a random id minted client-side (`Qt.uuid()`-style, stripped of braces) and used as the
  idempotency key for the whole operation — see Atomicity below.

## Public URL

A pure function, not a stored field:

```
https://firebasestorage.googleapis.com/v0/b/{bucket}/o/{urlEncode(path)}?alt=media
```

`bucket` and the `{env}` prefix are build-time constants (already how `FirebaseService` picks its database
per stage). This is the standard public-download form Storage rules make available once a path is
readable — no download token is minted, so there's nothing to revoke or leak beyond the path itself.

## Server: two new Cloud Functions (`functions/index.js`, region `asia-south1`, same pattern as every
existing handler — `verifyIdToken`, `deriveContext(db, uid)` for tenant and role, `scopedDb(env)`)

### `uploadProductPhoto`

Request: `{ env, productId, photoId, requestId, imageBase64, thumbBase64 }`. `requestId` is set to
`photoId` by the client — one id, one idempotency key, no separate concept to keep in sync.

1. Verify the ID token; derive `{ uid, tenantId, role }` from Firestore, same as every other handler. The
   client never names its own tenant.
2. Idempotency check: read `audit_log/{requestId}` first. If it already exists, return `{ already: true,
   photoIds }` from the current product doc — no re-upload, no duplicate id. (Same mechanism
   `applyMutation` already uses for mutations.)
3. Validate both images with a new pure module `functions/lib/photoValidation.js`: JPEG magic bytes
   (`FF D8 FF`), decoded size ceilings (main ≤ 1.5 MB, thumb ≤ 200 KB — generous over what `ImageProcessor`
   actually produces, to catch a corrupt or hostile payload without being brittle to compression changes).
   Failure → `400 invalid-image` (bad format/corrupt) or `413 image-too-large`.
4. Write both objects to Storage with the Admin SDK (`bucket.file(path).save(buffer, {contentType:
   'image/jpeg'})`). This step is *outside* the Firestore transaction — Storage has no transactional join
   with Firestore.
5. One Firestore transaction: read the product; `404 product-not-found` if it's gone; `409 photo-limit` if
   `photoIds.length >= 10`; append `photoId`, write a `photo_change` ledger entry (mirrors the existing
   `TransactionStore.recordPhotoChange` shape) and the `audit_log/{requestId}` marker, all in the one
   transaction. If this step throws after step 4 succeeded, the objects are orphaned but unreferenced —
   accepted risk, documented, not "corrupted" (no id points at missing bytes, only the reverse).
6. `200 { photoId, photoIds }`.

### `deleteProductPhoto`

Request: `{ env, productId, photoId, requestId }`. Same auth/context. Firestore transaction removes
`photoId` from the array (idempotent: removing an absent id is a no-op, not an error) and writes the
`audit_log` marker; Storage objects for that id are then best-effort deleted (`bucket.file(path).delete()`,
errors logged and swallowed — a leftover unreferenced object is a storage-cost issue, not a correctness
one). Reused by the product-delete cascade: `InventoryStore.deleteProduct`'s existing photo-cleanup call
site now calls this once per remaining id instead of touching local files.

### Error classification (client-visible)

| Status | Meaning | Client treats as |
|---|---|---|
| 400 `invalid-image` | Bad format/corrupt payload | Terminal |
| 413 `image-too-large` | Over the size ceiling | Terminal |
| 404 `product-not-found` | Product deleted mid-upload, or the offline gate (below) let one through | Terminal |
| 409 `photo-limit` | Already at 10 photos | Terminal |
| 409 `conflict` (tenant/session mismatch — see Trap 2) | Wrong identity for this queue item | Terminal |
| 401 | Token expired | Transient — refresh via `AuthService.ensureFreshToken()`, retry |
| 429, 5xx, timeout, network error | Overload/outage | Transient |

## Storage rules (`storage.rules`, new)

```
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /{env}/tenants/{tenantId}/products/{productId}/{photoFile} {
      allow read: if true;
      allow write: if false;
    }
    match /{allPaths=**} {
      allow read: if false;
      allow write: if false;
    }
  }
}
```

All writes are server-only (Admin SDK bypasses rules). The default-deny fallback keeps a future path
addition from being accidentally public.

## Client: a separate queue, not the Gateway outbox

`Gateway`/`OutboxStore` retry forever with no attempt cap (`DELETE-FEATURE-ROADMAP` item 1's root cause,
partially addressed by PR #75 for its own failure mode) and have no request timeout. Photos need bounded
retry, a give-up state with user-facing Retry/Discard, and per-item file cleanup — different enough
lifecycle that bolting it onto `Gateway` (already 825 lines, three near-duplicate senders) would make both
harder to reason about. New, small, parallel components instead:

- **`qml/helper/PhotoQueueLogic.js`** (`.pragma library`, pure — same shape as `StuckWrites.js`): error
  classification (table above), the backoff schedule (reuse `OutboxStore`'s exact `[2000, 8000, 30000,
  120000, 600000]` — one schedule, not two to keep in sync), the circuit-breaker state machine, and the
  queue-item reducer (`enqueued → uploading → (success: gone) | (transient: retrying, backoff) |
  (terminal/attempts-exhausted: failed)`, plus `retry` and `discard` transitions). Fully unit-testable
  without Qt.
- **`qml/model/PhotoQueue.qml`**: owns the list of pending items, persists it to `QSettings` (same technique
  `OutboxStore` already uses, including `SettingsPath.settingsLocationOverride` so `qmltestrunner` exercises
  real durability), drains on: app start, `Main.isOnline` flipping true, and a `Qt.createQmlObject`-created
  timer respecting each item's `nextAttemptAt` (same reason `Gateway` avoids a singleton-owned `Timer` —
  Skill 20).
- **Circuit breaker** is scoped to the photo endpoint only, independent of any Gateway breaker: trips after
  5 consecutive endpoint-level failures (timeout/5xx/429 — not a single item's own retries), cooldown 60s
  doubling to a 10-minute cap, then one half-open probe. This is the least valuable piece of the requested
  pattern set given per-item backoff already exists, but it's cheap (~40 lines of the same pure module) and
  Taher asked for it explicitly.
- **Attempt cap**: 8 attempts made *while online* (offline waiting doesn't count against it) before an item
  moves to `failed` and waits for the user.

### Queue item shape (persisted)

```
{ photoId, requestId: photoId, productId, uid, tenantId,
  mainFilePath, thumbFilePath,       // persisted local copies, see below
  state, attempts, nextAttemptAt, lastError }
```

### Flow

1. User picks/takes a photo → `ImageProcessor.compressForUpload` (main, existing 800px/q75) and a new thumb
   pass (256px/q70) → both persisted via `ImageProcessor.persistLocalCopy(photoId, …)` /
   `persistLocalCopy(photoId + "_t", …)`. Compression writes to the cache dir, which the OS can clear
   between launches, so the queue only ever references the *persisted* copies, never the cache path.
2. `PhotoQueue.enqueue(...)` — written to `QSettings` before anything else happens, so the item and its
   files both survive an app kill. UI shows the persisted local file immediately with a spinner overlay:
   the user is never blocked waiting on the network.
3. Drain loop, per item: **offline gate** (Trap 1, below) → breaker check → read both persisted files as
   base64 (new native method, below) → `POST uploadProductPhoto` with a 45s timeout → success removes the
   item and the store updates `photoIds` locally from the response (no wait for the next Firestore
   snapshot); the persisted local files are kept as an offline-capable cache for *this device's own*
   uploads, keyed by `photoId`.
4. **Retry** (user-initiated, from `failed`): resets `attempts` to 0, `nextAttemptAt` to now, `state` to
   `enqueued`. **Discard**: removes the item and deletes its two persisted files. Neither touches the
   server — nothing was ever written for a `failed` item.

### Two traps found in the existing code, both handled

1. **Product created offline, then a photo added before the product's own creation mutation has synced.**
   The server would 404. The drain loop gates an item on `OutboxStore` having no pending mutation for that
   `productId` (new small helper on `OutboxStore`, `hasPendingForEntity(productId)`) before attempting the
   upload — it waits, it doesn't fail.
2. **Cross-tenant / cross-session id reuse.** Product ids are counter-minted per tenant, so the same numeric
   id can exist in two tenants. A queue item is bound to the `uid`/`tenantId` active when it was enqueued;
   the drain loop only sends items matching the *current* signed-in identity, and the server independently
   rejects a `productId` that doesn't belong to the caller's derived tenant with `409 conflict` (terminal —
   discarding is correct, retrying never will succeed).

### One new native method

`src/NativeFile` gains `Q_INVOKABLE QString readFileBase64(const QString &path)` — `NativeFile` today only
has `toReadablePath`; nothing existing reads a file's bytes into QML. This cannot be built or exercised in
this sandbox (no Qt toolchain here, per standing instruction) — it lands in the plan's C++ task, flagged as
on-device-only verification, same as every other native change this project has shipped.

## UI

- New `qml/components/ProductPhotoGallery.qml`: cover photo plus a thumbnail strip. Each thumbnail's source
  is (in order) its `PhotoQueue` persisted local file if a matching queue item exists, else the computed
  Storage URL. `enqueued`/`uploading`/`retrying` show a spinner overlay; `failed` shows an error badge with
  Retry/Discard; nothing else changes about the picker itself.
- `EditProductDialog.qml`: replaces the current single-photo `applyPhotoSource`/`clearPhotoSource` wiring
  with "add a photo" (enqueues) and per-photo remove (calls `deleteProductPhoto` directly — removal doesn't
  need the queue, there's no large payload and no offline case worth queuing for a delete). Legacy
  `photoUrl` (no `photoIds` yet) shows the one-tap "Upload this photo" affordance described under Data
  model.
- `InventoryPage.qml` product cards: cover photo (first `photoIds` entry, or legacy `photoUrl` fallback) via
  the same local-cache-first, thumbnail-URL-second resolution.

## Known limits (told to Taher during design, restated here for the record)

- "Background" means "while the app process is alive." An OS-killed app does not upload until reopened —
  this is exactly what Taher chose in Q3.
- A photo synced in from *another* device has no offline disk cache (`Image` only memory-caches a decoded
  pixmap for the current session) — it's blank offline until the network returns. Only a device's *own*
  uploads stay visible offline, via the persisted queue files. Fixing this needs a C++ HTTP cache layer;
  out of scope, flagged as a possible follow-up.
- 100% coverage is not reachable end-to-end: the XHR wiring, the new native `readFileBase64` method, and
  real spinner/tap UI behavior cannot run in this sandbox (no Qt toolchain, no device). Every pure-logic
  path (validation, classification, breaker, reducer, URL building) is unit-tested for real; QML store/UI
  wiring is written and tested but only provably passes once CI or a device runs it; the native method and
  on-screen behavior are on-device-only, same precedent as Skill 67 and every prior native change here.
- Deploying `storage.rules` and the two new functions is on Taher — this feature does nothing in production
  until that deploy happens, independent of this branch merging.

## Not building this round

- Photo captions/ordering beyond "first id is cover" (an array-of-maps upgrade if the catalogue needs it
  later).
- Bulk/automatic migration of every existing `photoUrl` (impossible in general — most of those files only
  exist on a device that may not be the one running any given session).
- A C++/native offline cache for photos synced from other devices.
- True OS-level background upload (Q3, explicitly rejected).
