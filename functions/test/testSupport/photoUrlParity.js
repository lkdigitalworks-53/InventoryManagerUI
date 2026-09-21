// Plain-Node mirror of qml/helper/PhotoUrl.js (identical body, minus the ".pragma library"
// line). Keep these two in sync by hand -- same convention as StuckWrites.js / Skill 67. This
// file exists so the pure URL-building logic gets a real `node --test` run in this sandbox;
// tests/tst_PhotoUrl.qml (written separately) proves the actual QML file loads and behaves the
// same way, but only CI can run that one.

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

module.exports = { buildPhotoDownloadUrl };
