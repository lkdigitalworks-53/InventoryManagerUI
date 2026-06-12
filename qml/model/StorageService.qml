pragma Singleton
import QtQuick

// StorageService — abstracts product photo persistence so the rest of the app
// doesn't care whether bytes live on the local device or in Firebase Storage.
//
// Today (no Firebase Storage plan): the file is copied into the app's local
// data directory via ImageProcessor.persistLocalCopy and the resulting
// file:// URL is stored in Firestore. That URL only resolves on the device
// that uploaded it — fine for single-device use, will be revisited once the
// Storage plan is in place.
//
// When `useCloud` flips to true, uploadProductPhoto switches to a resumable
// XHR upload to gs://{bucket}/products/{tenantId}/{productId}.jpg. The
// callback signature is identical, so callers don't change.
QtObject {
    id: root

    // Toggle once Firebase Storage is enabled in the project.
    readonly property bool useCloud: false

    // Default Firebase Storage bucket for the project. Production deployment
    // should confirm this matches what the Firebase console shows.
    readonly property string bucket: "inventorymanager-48392.appspot.com"

    signal uploadProgress(string productId, real fraction)

    function _localPath(productId) {
        return "products/" + productId + ".jpg"
    }

    // Compress + persist a picked image. callback(ok, photoUrl, error).
    function uploadProductPhoto(productId, sourceUrl, callback) {
        if (!productId || productId.length === 0) {
            if (callback) callback(false, "", "Missing productId")
            return
        }
        if (!sourceUrl || sourceUrl.length === 0) {
            if (callback) callback(false, "", "Missing source")
            return
        }

        // Picked images on Android arrive as content:// URIs that ImageProcessor
        // can't stat. Resolve to a readable local path first (passthrough for
        // already-local sources).
        var readable = NativeFile.toReadablePath(sourceUrl)
        if (!readable || readable.length === 0) {
            if (callback) callback(false, "", "Could not read the selected image")
            return
        }

        // Compress first so on-device storage stays small (~50 KB JPEG).
        var compressedUrl = ImageProcessor.compressForUpload(readable, 800, 75)
        if (!compressedUrl || compressedUrl.length === 0) {
            if (callback) callback(false, "", "Could not compress image")
            return
        }

        if (useCloud) {
            _uploadToFirebase(productId, compressedUrl, callback)
            return
        }

        // Local-only path: copy compressed JPEG into app data folder so it
        // survives the cache being cleared. The returned URL is stable.
        var persistedUrl = ImageProcessor.persistLocalCopy(productId, compressedUrl)
        if (!persistedUrl || persistedUrl.length === 0) {
            if (callback) callback(false, "", "Could not persist photo locally")
            return
        }
        // Fake "instant" progress for UI consistency with the cloud path.
        uploadProgress(productId, 1.0)
        if (callback) callback(true, persistedUrl, "")
    }

    function deleteProductPhoto(productId, callback) {
        if (!productId) { if (callback) callback(false, "Missing productId"); return }
        if (useCloud) {
            _deleteFromFirebase(productId, callback)
            return
        }
        var ok = ImageProcessor.removeLocalCopy(productId)
        if (callback) callback(ok, ok ? "" : "Could not remove local file")
    }

    // ── Firebase Storage path (kept ready for when the plan is enabled) ─────

    function _uploadToFirebase(productId, localFileUrl, callback) {
        // Stub: implement when Storage is enabled. Path scheme:
        //   POST https://firebasestorage.googleapis.com/v0/b/{bucket}/o
        //        ?name=products/{tenantId}/{productId}.jpg
        //        &uploadType=media
        //   Authorization: Bearer {AuthStore.idToken}
        // On success the response carries downloadTokens; build the URL
        //   https://firebasestorage.googleapis.com/v0/b/{bucket}/o/{escapedPath}
        //        ?alt=media&token={token}
        // Track progress via xhr.upload.onprogress and emit uploadProgress.
        if (callback) callback(false, "", "Firebase Storage not enabled in this build")
    }

    function _deleteFromFirebase(productId, callback) {
        if (callback) callback(false, "Firebase Storage not enabled in this build")
    }
}
