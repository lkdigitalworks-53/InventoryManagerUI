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

const { isSafePathSegment } = require('../lib/photoValidation');

test('isSafePathSegment: accepts a normal minted photoId', () => {
  assert.equal(isSafePathSegment('photo-1758499200000-482913'), true);
});

test('isSafePathSegment: accepts a normal numeric productId', () => {
  assert.equal(isSafePathSegment('1042'), true);
});

test('isSafePathSegment: rejects a value containing a slash (path-segment injection)', () => {
  assert.equal(isSafePathSegment('other-tenant/inventory/real-id'), false);
  assert.equal(isSafePathSegment('/absolute'), false);
  assert.equal(isSafePathSegment('trailing/'), false);
});

test('isSafePathSegment: rejects a value containing ".." (traversal)', () => {
  assert.equal(isSafePathSegment('..'), false);
  assert.equal(isSafePathSegment('foo..bar'), false);
});

test('isSafePathSegment: rejects empty, non-string, and oversized values', () => {
  assert.equal(isSafePathSegment(''), false);
  assert.equal(isSafePathSegment(null), false);
  assert.equal(isSafePathSegment(undefined), false);
  assert.equal(isSafePathSegment(42), false);
  assert.equal(isSafePathSegment('x'.repeat(65)), false);
  assert.equal(isSafePathSegment('x'.repeat(64)), true);
});

// ---- PH3 whitelist (design Q9; test plan U01-U12) -------------------------------------------
test('whitelist U02: uuid-style id with hyphens accepted', () => {
  assert.equal(isSafePathSegment('photo-3f2b8c1e-9d4a-4b7e-8a11-0c5d6e7f8a90'), true);
});

test('whitelist U03/U04: 64 chars accepted, 65 rejected (boundary)', () => {
  assert.equal(isSafePathSegment('a'.repeat(64)), true);
  assert.equal(isSafePathSegment('a'.repeat(65)), false);
  assert.equal(isSafePathSegment('a'), true);
});

test('whitelist U05/U06: empty, "." and ".." rejected', () => {
  for (const v of ['', '.', '..', '...']) assert.equal(isSafePathSegment(v), false, JSON.stringify(v));
});

test('whitelist U07: slash and backslash rejected', () => {
  for (const v of ['a/b', 'a\\b', '/', '\\']) assert.equal(isSafePathSegment(v), false, JSON.stringify(v));
});

test('whitelist U08: space, tab, newline, NUL rejected', () => {
  for (const v of ['a b', 'a\tb', 'a\nb', 'a\rb', 'a\u0000b', ' a', 'a ']) {
    assert.equal(isSafePathSegment(v), false, JSON.stringify(v));
  }
});

test('whitelist U09: emoji, RTL override, combining and full-width chars rejected', () => {
  for (const v of ['a\u{1F600}', 'a\u202Eb', 'e\u0301', '\uFF21BC', 'caf\u00e9']) {
    assert.equal(isSafePathSegment(v), false, JSON.stringify(v));
  }
});

test('whitelist U10: percent-encoded traversal and other punctuation rejected', () => {
  for (const v of ['%2e%2e', '%2F', 'a.b', 'a:b', 'a*b', 'a?b', 'a#b', 'a@b']) {
    assert.equal(isSafePathSegment(v), false, JSON.stringify(v));
  }
});

test('whitelist U11: non-strings rejected', () => {
  for (const v of [null, undefined, 5, 0, true, {}, [], ['a'], () => 'a', Symbol('a')]) {
    assert.equal(isSafePathSegment(v), false);
  }
});

test('whitelist U12 MONKEY: 1000 random strings accepted iff the regex oracle says so', () => {
  const oracle = /^[A-Za-z0-9_-]{1,64}$/;
  const alphabet = 'abcXYZ019_-./\\ %\u00e9\u{1F600}\n\u0000';
  let seed = 20261003;
  const rnd = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; };
  const chars = Array.from(alphabet);
  for (let i = 0; i < 1000; i++) {
    const len = Math.floor(rnd() * 70);
    let str = '';
    for (let j = 0; j < len; j++) str += chars[Math.floor(rnd() * chars.length)];
    assert.equal(isSafePathSegment(str), oracle.test(str), JSON.stringify(str));
  }
});
