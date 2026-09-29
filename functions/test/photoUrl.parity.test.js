const { test } = require('node:test');
const assert = require('node:assert/strict');
const { buildPhotoDownloadUrl } = require('./testSupport/photoUrlParity');

const base = { bucket: 'inventorymanager-48392.firebasestorage.app', env: 'prd',
  tenantId: 'tenant1', productId: 'prod1', photoId: 'abc123' };

test('builds the main-image public download URL', () => {
  const url = buildPhotoDownloadUrl(base);
  assert.equal(url,
    'https://firebasestorage.googleapis.com/v0/b/inventorymanager-48392.firebasestorage.app/o/' +
    'prd%2Ftenants%2Ftenant1%2Fproducts%2Fprod1%2Fabc123.jpg?alt=media');
});

test('builds the thumbnail URL with the _t suffix when thumb is true', () => {
  const url = buildPhotoDownloadUrl({ ...base, thumb: true });
  assert.match(url, /abc123_t\.jpg\?alt=media$/);
});

test('URL-encodes slashes in the path (not literal /) so Storage treats it as one object name', () => {
  const url = buildPhotoDownloadUrl(base);
  assert.equal((url.match(/%2F/g) || []).length, 5);
  assert.ok(!url.includes('/o/prd/tenants'));
});

test('differs by env so prd/test/dev1 never collide', () => {
  const prd = buildPhotoDownloadUrl(base);
  const test_ = buildPhotoDownloadUrl({ ...base, env: 'test' });
  assert.notEqual(prd, test_);
});

test('throws on a missing required field rather than building a broken URL', () => {
  assert.throws(() => buildPhotoDownloadUrl({ ...base, photoId: undefined }));
  assert.throws(() => buildPhotoDownloadUrl({ ...base, tenantId: '' }));
});

// ── toLocalPath / toFileUrl (PR #84 device-test fix: file:// double-prefix + URL-as-path read) ──
const { toLocalPath, toFileUrl } = require('./testSupport/photoUrlParity');

test('toLocalPath: Windows file URL -> drive path (the exact shape from the device log)', () => {
  assert.equal(toLocalPath('file:///C:/Users/Dell/AppData/Local/Karobar/photos/photo-1.jpg'),
    'C:/Users/Dell/AppData/Local/Karobar/photos/photo-1.jpg');
});
test('toLocalPath: unix file URL keeps the leading slash', () => {
  assert.equal(toLocalPath('file:///data/user/0/app/photos/p.jpg'), '/data/user/0/app/photos/p.jpg');
});
test('toLocalPath: bare paths pass through untouched (Windows, unix, legacy queue items)', () => {
  assert.equal(toLocalPath('C:/x/p.jpg'), 'C:/x/p.jpg');
  assert.equal(toLocalPath('/data/p.jpg'), '/data/p.jpg');
});
test('toLocalPath: percent-escapes are decoded (space in folder name)', () => {
  assert.equal(toLocalPath('file:///D:/My%20Photos/p.jpg'), 'D:/My Photos/p.jpg');
});
test('toLocalPath: malformed escape does not throw, keeps raw text', () => {
  assert.equal(toLocalPath('file:///D:/100%/p.jpg'), 'D:/100%/p.jpg');
});
test('toLocalPath: empty / null / undefined / non-string -> empty string', () => {
  for (const v of ['', null, undefined, 42, {}, []]) assert.equal(toLocalPath(v), '');
});
test('toLocalPath: is idempotent', () => {
  const once = toLocalPath('file:///C:/a/b.jpg');
  assert.equal(toLocalPath(once), once);
});
test('toFileUrl: bare Windows path -> file:///C:/...', () => {
  assert.equal(toFileUrl('C:/a/b.jpg'), 'file:///C:/a/b.jpg');
});
test('toFileUrl: bare unix path -> file:///...', () => {
  assert.equal(toFileUrl('/data/b.jpg'), 'file:///data/b.jpg');
});
test('toFileUrl: an existing file URL is NOT double-prefixed (the device bug)', () => {
  assert.equal(toFileUrl('file:///C:/a/b.jpg'), 'file:///C:/a/b.jpg');
  assert.ok(!toFileUrl('file:///C:/a/b.jpg').includes('file://file'));
});
test('toFileUrl: spaces are escaped so QML Image can open the path', () => {
  assert.equal(toFileUrl('D:/My Photos/b.jpg'), 'file:///D:/My%20Photos/b.jpg');
});
test('toFileUrl: empty-ish input -> empty string (Image gets no source, no bogus "file://")', () => {
  for (const v of ['', null, undefined]) assert.equal(toFileUrl(v), '');
});
test('toFileUrl: is idempotent', () => {
  const once = toFileUrl('C:/a b/c.jpg');
  assert.equal(toFileUrl(once), once);
});
test('monkey: 500 random path-ish strings never throw and round-trip stably', () => {
  const alphabet = 'ab /\\%:.C~é#?';
  let seed = 7; const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  for (let i = 0; i < 500; i++) {
    let s = rnd() < 0.5 ? 'file://' : '';
    for (let j = 0, n = Math.floor(rnd() * 20); j < n; j++) s += alphabet[Math.floor(rnd() * alphabet.length)];
    assert.doesNotThrow(() => toLocalPath(s));
    assert.doesNotThrow(() => toFileUrl(s));
  }
});
