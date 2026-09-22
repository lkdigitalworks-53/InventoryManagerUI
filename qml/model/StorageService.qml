pragma Singleton
import QtQuick

import "../helper/EnvConfig.js" as EnvConfig
import "../helper/PhotoUrl.js" as PhotoUrl

// StorageService — the product-photo abstraction the rest of the app talks to, so callers don't
// need to know PhotoQueue, ImageProcessor, or the Cloud Functions exist.
//
// Rewritten 2026-09-21 for the Firebase-Storage-backed, multi-photo, cross-device-synced feature
// (design spec: docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md).
// The OLD single-device model (useCloud toggle, a single photoUrl string, local-file-URL-as-source-
// of-truth) is REPLACED here, not extended — it was never going to satisfy "sync across every
// device" no matter how useCloud was flipped, since the whole premise was a file:// URL that only
// resolves on the device that wrote it. _uploadToFirebase/_deleteFromFirebase's old stub bodies
// are gone along with it.
QtObject {
    id: root

    readonly property string bucket: "inventorymanager-48392.firebasestorage.app"
    readonly property string _deleteUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/deleteProductPhoto"

    function _nextPhotoId() {
        // Same scheme as Gateway._nextRequestId (req-<ms>-<rand>) -- photoId doubles as the
        // upload's idempotency requestId, so it needs the same uniqueness guarantee.
        return "photo-" + Date.now() + "-" + Math.floor(Math.random() * 1000000)
    }

    // Compress (main + a new thumbnail pass), persist both locally, and enqueue the upload.
    // Returns immediately with the minted photoId -- this does NOT wait for the network.
    // PhotoQueue.photoUploaded/photoUploadFailed report the eventual outcome; the caller (the
    // photo gallery) shows a spinner on this photoId in the meantime by checking PhotoQueue.items.
    //
    // Also used for the one-tap "migrate this photo" affordance (design spec, Data model): pass
    // the product's existing legacy photoUrl as sourceUrl -- it's already a valid local file://
    // URI, so no special-casing is needed here, only in the caller that offers the button.
    function addProductPhoto(productId, sourceUrl) {
        if (!productId || !sourceUrl)
            return { ok: false, error: "Missing productId or source", photoId: "" }
        if (!AuthStore.uid || !AuthStore.tenantId)
            return { ok: false, error: "Not signed in", photoId: "" }

        // Picked images on Android arrive as content:// URIs that ImageProcessor can't stat.
        // Resolve to a readable local path first (passthrough for an already-local source, e.g.
        // the migration case above).
        var readable = NativeFile.toReadablePath(sourceUrl)
        if (!readable || readable.length === 0)
            return { ok: false, error: "Could not read the selected image", photoId: "" }

        var photoId = _nextPhotoId()

        var mainCompressed = ImageProcessor.compressForUpload(readable, 800, 75)
        if (!mainCompressed || mainCompressed.length === 0)
            return { ok: false, error: "Could not compress image", photoId: "" }
        var thumbCompressed = ImageProcessor.compressForUpload(readable, 256, 70)
        if (!thumbCompressed || thumbCompressed.length === 0)
            return { ok: false, error: "Could not compress thumbnail", photoId: "" }

        // persistLocalCopy's first parameter is misleadingly named "productId" in ImageProcessor.h
        // (a holdover from the old one-photo-per-product model) -- it's really just a filename-stem
        // key, used here as photoId/photoId+"_t" so each photo gets its own persisted slot instead
        // of colliding on the product's id.
        var mainPersisted = ImageProcessor.persistLocalCopy(photoId, mainCompressed)
        if (!mainPersisted || mainPersisted.length === 0)
            return { ok: false, error: "Could not persist photo locally", photoId: "" }
        var thumbPersisted = ImageProcessor.persistLocalCopy(photoId + "_t", thumbCompressed)
        if (!thumbPersisted || thumbPersisted.length === 0) {
            ImageProcessor.removeLocalCopy(photoId)
            return { ok: false, error: "Could not persist thumbnail locally", photoId: "" }
        }

        PhotoQueue.enqueue({
            photoId: photoId, productId: productId,
            uid: AuthStore.uid, tenantId: AuthStore.tenantId,
            mainFilePath: mainPersisted, thumbFilePath: thumbPersisted
        })
        return { ok: true, error: "", photoId: photoId }
    }

    // A photo still queued (the server has never seen it) is simply discarded locally -- nothing
    // was ever written server-side for it. A photo the server already confirmed (present in the
    // product's photoIds) is deleted via the Cloud Function directly -- removal doesn't need the
    // queue (design spec: no large payload, no offline case worth queuing for a delete).
    function removeProductPhoto(productId, photoId, callback) {
        for (var i = 0; i < PhotoQueue.items.length; ++i) {
            if (PhotoQueue.items[i].photoId !== photoId) continue
            PhotoQueue.discard(photoId)
            if (callback) callback(true, "")
            return
        }

        if (!AuthStore.idToken || AuthStore.idToken.length === 0) {
            if (callback) callback(false, "Not signed in")
            return
        }

        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var ok = xhr.status >= 200 && xhr.status < 300
            if (callback) callback(ok, ok ? "" : ("Delete failed (status " + xhr.status + ")"))
        }
        xhr.open("POST", _deleteUrl)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + AuthStore.idToken)
        xhr.send(JSON.stringify({
            env: FirebaseService.environment,
            productId: productId, photoId: photoId, requestId: "del-" + photoId
        }))
    }

    // Public download URL for a photo the server has already confirmed. Not meaningful for a
    // still-queued photo -- callers should show PhotoQueue's persisted local file for those (see
    // ProductPhotoGallery.qml's resolution order).
    function photoDownloadUrl(productId, photoId, thumb) {
        return PhotoUrl.buildPhotoDownloadUrl({
            bucket: bucket,
            env: EnvConfig.storagePrefixForEnv(FirebaseService.environment),
            tenantId: AuthStore.tenantId, productId: productId, photoId: photoId,
            thumb: !!thumb
        })
    }
}
