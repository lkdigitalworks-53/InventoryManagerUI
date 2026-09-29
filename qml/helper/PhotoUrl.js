.pragma library

// Pure URL builder. No stored URL field exists anywhere (see the design spec, "Public URL") --
// every caller computes this from the photoId it already has (from Firestore's photoIds array).
// A plain-Node mirror of this file lives at functions/test/testSupport/photoUrlParity.js and is
// kept in sync by hand (same convention as StuckWrites.js / Skill 67) so this logic gets a real
// node --test run in addition to the qmltestrunner test that proves the QML wiring in CI.
function buildPhotoDownloadUrl(opts) {
    var bucket = opts.bucket, env = opts.env, tenantId = opts.tenantId,
        productId = opts.productId, photoId = opts.photoId, thumb = !!opts.thumb
    if (!bucket || !env || !tenantId || !productId || !photoId) {
        throw new Error('buildPhotoDownloadUrl: missing required field')
    }
    var fileName = photoId + (thumb ? '_t' : '') + '.jpg'
    var path = env + '/tenants/' + tenantId + '/products/' + productId + '/' + fileName
    var encoded = path.split('/').map(encodeURIComponent).join('%2F')
    return 'https://firebasestorage.googleapis.com/v0/b/' + bucket + '/o/' + encoded + '?alt=media'
}

// Local-file path helpers (2026-09-28, PR #84 device-test fix). ImageProcessor.persistLocalCopy
// returns a file:// URL (QUrl::fromLocalFile().toString()), but NativeFile.readFileBase64 wants a
// bare path and QML Image wants a URL. Queue items persisted before this fix already hold the URL
// form, so both helpers accept EITHER form and are idempotent.
function toLocalPath(p) {
    if (typeof p !== 'string' || p.length === 0) return ''
    if (p.indexOf('file://') !== 0) return p
    var path = p.substring(7)
    try { path = decodeURIComponent(path) } catch (e) { /* keep raw */ }
    return /^\/[A-Za-z]:[\/\\]/.test(path) ? path.substring(1) : path
}

function toFileUrl(p) {
    var path = toLocalPath(p)
    if (path.length === 0) return ''
    var encoded = encodeURI(path).replace(/#/g, '%23').replace(/\?/g, '%3F')
    return /^[A-Za-z]:/.test(path) ? 'file:///' + encoded : 'file://' + encoded
}
