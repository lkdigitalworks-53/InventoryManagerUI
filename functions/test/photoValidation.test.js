const { test } = require('node:test');
const assert = require('node:assert/strict');
const { validateImage } = require('../lib/photoValidation');

const JPEG_MAGIC = Buffer.from([0xff, 0xd8, 0xff, 0xe0]);

test('accepts a valid small JPEG buffer', () => {
  const buf = Buffer.concat([JPEG_MAGIC, Buffer.alloc(100, 1)]);
  assert.deepEqual(validateImage(buf, { maxBytes: 1_500_000 }), { ok: true });
});

test('rejects a buffer without the JPEG magic bytes', () => {
  const buf = Buffer.from([0x00, 0x01, 0x02, 0x03]);
  assert.deepEqual(validateImage(buf, { maxBytes: 1_500_000 }), { ok: false, code: 'invalid-image' });
});

test('rejects an empty buffer', () => {
  assert.deepEqual(validateImage(Buffer.alloc(0), { maxBytes: 1_500_000 }), { ok: false, code: 'invalid-image' });
});

test('rejects null/undefined input', () => {
  assert.deepEqual(validateImage(null, { maxBytes: 1_500_000 }), { ok: false, code: 'invalid-image' });
  assert.deepEqual(validateImage(undefined, { maxBytes: 1_500_000 }), { ok: false, code: 'invalid-image' });
});

test('rejects a buffer over maxBytes even if the header is valid', () => {
  const buf = Buffer.concat([JPEG_MAGIC, Buffer.alloc(2_000_000, 1)]);
  assert.deepEqual(validateImage(buf, { maxBytes: 1_500_000 }), { ok: false, code: 'image-too-large' });
});

test('accepts a buffer exactly at maxBytes', () => {
  const buf = Buffer.concat([JPEG_MAGIC, Buffer.alloc(1_500_000 - JPEG_MAGIC.length, 1)]);
  assert.deepEqual(validateImage(buf, { maxBytes: 1_500_000 }), { ok: true });
});

test('rejects a PNG magic-byte buffer (wrong format, not just "not JPEG garbage")', () => {
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  assert.deepEqual(validateImage(png, { maxBytes: 1_500_000 }), { ok: false, code: 'invalid-image' });
});
