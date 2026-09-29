// Pure. No Firebase/Admin SDK imports here — keeps this testable with plain Node and reusable
// from uploadProductPhoto for both the main image and the thumbnail with different maxBytes.

const JPEG_MAGIC = [0xff, 0xd8, 0xff];

function hasJpegMagic(buffer) {
  if (buffer.length < JPEG_MAGIC.length) return false;
  return JPEG_MAGIC.every((byte, i) => buffer[i] === byte);
}

function validateImage(buffer, { maxBytes }) {
  if (!buffer || !Buffer.isBuffer(buffer) || buffer.length === 0) {
    return { ok: false, code: 'invalid-image' };
  }
  if (!hasJpegMagic(buffer)) {
    return { ok: false, code: 'invalid-image' };
  }
  if (buffer.length > maxBytes) {
    return { ok: false, code: 'image-too-large' };
  }
  return { ok: true };
}

// Both productId and photoId are concatenated directly into a Firestore document path
// (db.doc(`tenants/${tenantId}/inventory/${productId}`)) and a Cloud Storage object path
// (`${env}/tenants/${tenantId}/products/${productId}/${photoId}.jpg`). Firestore treats "/" as a
// path-segment separator, not a literal character, so an unvalidated id containing one could
// address a document or object entirely outside the intended tenant/product -- a real path-
// traversal surface, found in review (2026-09-21 feature, not present before this feature added
// Storage paths). productId itself is still independently checked against Firestore's actual
// inventory collection (a crafted id simply won't exist there), but Storage has no equivalent
// existence check protecting it, and this closes the gap for both before either is ever used.
function isSafePathSegment(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= 200 &&
    !value.includes('/') && !value.includes('..');
}

module.exports = { validateImage, isSafePathSegment };
