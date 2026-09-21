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
