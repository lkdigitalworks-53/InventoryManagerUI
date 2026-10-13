const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// test/e2e/E2EHelpers.js is a QML `.pragma library` file, not a Node module: strip the pragma and run it in a
// sandbox to reach the pure converters the PH5 e2e tests use to seed a raw Firestore document.
const src = fs.readFileSync(path.join(__dirname, '..', '..', 'test', 'e2e', 'E2EHelpers.js'), 'utf8').replace(/^\.pragma library\s*$/m, '');
const ctx = {};
vm.runInNewContext(src + '\nthis.toFirestoreValue = toFirestoreValue; this.toFirestoreFields = toFirestoreFields;', ctx);
// results come from another realm: a JSON round trip gives plain objects the strict deepEqual accepts
const toFirestoreValue = (v) => JSON.parse(JSON.stringify(ctx.toFirestoreValue(v)));
const toFirestoreFields = (o) => JSON.parse(JSON.stringify(ctx.toFirestoreFields(o)));

test('E2EH-1 scalars: string, boolean, null/undefined, integer, double', () => {
  assert.deepEqual(toFirestoreValue('x'), { stringValue: 'x' });
  assert.deepEqual(toFirestoreValue(''), { stringValue: '' });
  assert.deepEqual(toFirestoreValue(true), { booleanValue: true });
  assert.deepEqual(toFirestoreValue(false), { booleanValue: false });
  assert.deepEqual(toFirestoreValue(null), { nullValue: null });
  assert.deepEqual(toFirestoreValue(undefined), { nullValue: null });
  assert.deepEqual(toFirestoreValue(5), { integerValue: '5' });
  assert.deepEqual(toFirestoreValue(0), { integerValue: '0' });
  assert.deepEqual(toFirestoreValue(-3), { integerValue: '-3' });
  assert.deepEqual(toFirestoreValue(2.5), { doubleValue: 2.5 });
});

test('E2EH-2 arrays and nested objects', () => {
  assert.deepEqual(toFirestoreValue([]), { arrayValue: { values: [] } });
  assert.deepEqual(toFirestoreValue(['a', 1]), { arrayValue: { values: [{ stringValue: 'a' }, { integerValue: '1' }] } });
  assert.deepEqual(toFirestoreValue({ k: 'v' }), { mapValue: { fields: { k: { stringValue: 'v' } } } });
});

test('E2EH-3 toFirestoreFields keeps EXACTLY the keys given, including empty strings (the PH5 legacy keys)', () => {
  const f = toFirestoreFields({ productId: 'p', photoIds: [], photoUrl: '', photoUpdatedAt: '', price: 100 });
  assert.deepEqual(Object.keys(f).sort(), ['photoIds', 'photoUpdatedAt', 'photoUrl', 'price', 'productId']);
  assert.deepEqual(f.photoUrl, { stringValue: '' });
  assert.deepEqual(f.photoUpdatedAt, { stringValue: '' });
  assert.deepEqual(toFirestoreFields({}), {});
});

test('E2EH-4 round trip with the e2e files\' typed-value reader', () => {
  // the reader the QML e2e files carry (_firestoreFieldsToPlain), re-stated here as the oracle
  const read = (v) => {
    if (v.stringValue !== undefined) return v.stringValue;
    if (v.integerValue !== undefined) return Number(v.integerValue);
    if (v.doubleValue !== undefined) return v.doubleValue;
    if (v.booleanValue !== undefined) return v.booleanValue;
    if (v.nullValue !== undefined) return null;
    if (v.arrayValue !== undefined) return (v.arrayValue.values || []).map(read);
    if (v.mapValue !== undefined) return Object.fromEntries(Object.entries(v.mapValue.fields || {}).map(([k, x]) => [k, read(x)]));
    return null;
  };
  const doc = { productId: 'p1', name: 'W', stock: 5, price: 12.5, taxable: false, photoIds: ['a', 'b'], nested: { n: null, s: 'x' }, photoUrl: '' };
  const back = Object.fromEntries(Object.entries(toFirestoreFields(doc)).map(([k, x]) => [k, read(x)]));
  assert.deepEqual(back, doc);
});
