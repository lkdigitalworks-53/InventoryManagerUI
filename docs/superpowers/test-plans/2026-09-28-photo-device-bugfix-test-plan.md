# Test plan — PR #84 device-test bug fixes (product photos): path form, stuck drain, failed-tile UI

**Branch:** `feature/2026-09-21-product-photos-firebase-storage` (PR #84). **Date:** 2026-09-28.
**Status honesty:** Node tests below were RUN in the sandbox. Every QML test is written to repo
conventions but NOT run here (no Qt toolchain, standing instruction); CI is the proof. Gallery layout
and the real upload have no automated coverage and are on-device only. Coverage is NOT 100%:
`PhotoQueue._upload` (native read + XHR) and `ProductPhotoGallery` (imports Felgo) cannot run under
`qmltestrunner`; the pure logic they now depend on is what is fully covered.

## Root causes

1. `persistLocalCopy` returns a `file://` URL; gallery prepended `file://` again; `_upload` read it as a
   bare path -> "file gone" -> terminal 400 -> nothing ever uploaded.
2. `PhotoQueue` never re-drained when the product's outbox create landed -> spinner forever.
3. Failed-tile Retry/Discard were 9px text inside a 72px tile.
4. Gap after discard + re-add: root cause NOT proven from code. Layout made deterministic (top-aligned,
   fixed heights). Confirm on device; send a screenshot if it persists.

## 1. Unit tests, run for real (Node)

`functions/test/photoUrl.parity.test.js` (+ `testSupport/photoUrlParity.js` mirror): 19/19; full
`functions/` suite 329/329. Cases: Windows/unix file URL -> path; bare path passthrough; `%20` decode;
malformed `%` no throw; null/undefined/number/object -> `""`; idempotence; no `file://file` double
prefix; space escaping; 500-string monkey.

## 2. Functional (QML, CI-only)

- `tests/tst_PhotoUrl.qml`: same cases against the real QML file (+ data-driven empty-like inputs, monkey).
- `tests/tst_PhotoQueue.qml`: outbox landing re-arms the drain timer (regression for the stuck spinner);
  outbox change with an empty queue does not arm it; a terminally failed item is not re-armed by the outbox.

## 3. Rules / e2e / regression

No rules or function changes. Existing `test/e2e/tst_ProductPhotosE2E.qml` posts base64 directly, so it
never exercised the queue's local-file read; that gap is why this bug shipped. Follow-up (not done, scope):
an e2e through `StorageService.addProductPhoto` with a real file.

## 4. On-device (owner)

**Happy**
- [ ] Add new product WITH a photo, save, reopen: spinner clears in seconds, photo shows, object exists in
      Firebase Storage under `{env}/tenants/{t}/products/{id}/`.
- [ ] Edit an existing product, add a photo from gallery: uploads, shows as cover.
- [ ] Log has no `Cannot open: file://` and no `file://file`.

**Negative**
- [ ] Airplane mode + add photo: stays queued (spinner), uploads on reconnect.
- [ ] Force a failure (block function URL / bad token): tile gets red border, Retry and Discard sit BELOW
      it, each >= 40dp tall; Retry re-uploads; Discard removes the tile with no leftover gap.
- [ ] Items already `failed` from the previous build (URL-form paths): press Retry, should now upload.

**Edge**
- [ ] Product created offline + photo added, then go online: photo waits for the product, then uploads
      (previously stuck until app restart).
- [ ] Windows profile path containing a space.
- [ ] 10 photos: + tile hidden; discard one: + returns in the same row, no gap.
- [ ] Discard the only failed tile, add another photo: row height returns to one tile height.

**Multi-scenario / monkey**
- [ ] 3 photos to 3 different products quickly; kill app mid-upload; reopen: all resume.
- [ ] Mash Retry/Discard alternately: no crash, no duplicate tile.
- [ ] Two devices, same account: photo uploaded on A appears on B.

**Known unknowns**
- A real upload through the Cloud Function from this build has never happened. If it now returns 4xx/5xx
  the next bug is server-side (`photoValidation`, size, auth); bring the log line.
- `qt.network.http2: GOAWAY` is connection-level noise; status 0 is retried by design.
