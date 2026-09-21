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

module.exports = { validateImage };
