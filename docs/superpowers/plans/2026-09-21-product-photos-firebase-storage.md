# Product photos in Firebase Storage — Implementation Plan

**Design:** `docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md` (read first — this
plan does not repeat the "why", only the "what/how", and cross-references it by section name).

**Goal:** replace the single device-local `photoUrl` string on a product with a synced, multi-photo,
Firebase-Storage-backed gallery, uploaded through a durable, resumable, bounded-retry background queue.

**Architecture:** two new Cloud Functions (`uploadProductPhoto`, `deleteProductPhoto`) own all Storage
writes behind an idempotency key; the client never writes Storage directly (`storage.rules` denies all
client writes). A new `PhotoQueue` QML store, parallel to (not part of) `Gateway`/`OutboxStore`, persists
pending uploads to `QSettings` and drains them with bounded exponential backoff and a small circuit breaker.
All decision logic (validation, URL building, classification, backoff, breaker, queue-item transitions)
lives in pure `.pragma library` / plain-Node modules so it is unit-testable without Qt or a device.

**Tech Stack:** Qt 6 / QML (Felgo), Node 20 Cloud Functions (`asia-south1`), Firebase Admin SDK, Cloud
Storage for Firebase, `node --test`, `qmltestrunner`.

## Global Constraints (from the design spec — apply to every task)

- Bucket `inventorymanager-48392.firebasestorage.app`, region `asia-south1`, path
  `{env}/tenants/{tenantId}/products/{productId}/{photoId}.jpg` (+ `_t.jpg` thumbnail).
- `photoIds: string[]`, max 10, first entry is cover. No URL field, no `photoUpdatedAt`.
- Idempotency key = `photoId` = `requestId`, checked against `audit_log/{requestId}` before any write,
  same mechanism `applyMutation` already uses.
- Backoff schedule is exactly `OutboxStore`'s `[2000, 8000, 30000, 120000, 600000]` — do not invent a second
  schedule.
- No `Timer` owned directly by a singleton (Skill 20) — create with `Qt.createQmlObject`, same as `Gateway`.
- Do not touch `Gateway.qml`'s three senders. `PhotoQueue` is a sibling, not an addition to it.
- Commit identity for every commit this session: `Taher (via Claude session) <lkdwtaher@gmail.com>`.
- No Qt toolchain, no device, and (confirmed this session — `storage.googleapis.com` is not in the sandbox's
  egress allowlist) no Firebase emulator download available here. `functions/` unit tests under `node --test`
  **are** runnable here (confirmed, clean baseline 195/195 before this feature) — run them for real after
  every functions change. Everything QML, rules-emulator, or native is written, then proven only by CI /
  on-device; say so plainly in the test plan, don't claim what wasn't run.

---

## PR 1 — Server, rules, CI (this branch's first pushed slice)

### Task 1: Pure photo-validation module

**Files:**
- Create: `functions/lib/photoValidation.js`
- Test: `functions/test/photoValidation.test.js`

**Interfaces:**
- Produces: `validateImage(buffer, { maxBytes }) -> { ok: true } | { ok: false, code: 'invalid-image' |
  'image-too-large' }`. Consumed by Task 4 (`uploadProductPhoto`).

- [ ] **Step 1: Write the failing tests**

```js
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
```

- [ ] **Step 2: Run — expect FAIL (module not found)**

Run: `cd functions && node --test test/photoValidation.test.js`

- [ ] **Step 3: Implement**

```js
// functions/lib/photoValidation.js
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
```

- [ ] **Step 4: Run — expect PASS, all 7**

Run: `cd functions && node --test test/photoValidation.test.js`

- [ ] **Step 5: Commit**

```bash
git add functions/lib/photoValidation.js functions/test/photoValidation.test.js
git commit -m "feat(functions): pure JPEG validation for product photo uploads"
```

### Task 2: Pure public-URL builder (client side, but zero Qt dependencies — test it as plain JS first)

**Files:**
- Create: `qml/helper/PhotoUrl.js`
- Test: `functions/test/photoUrl.parity.test.js` (see note below on why this lives under `functions/test`)

**Interfaces:**
- Produces: `buildPhotoDownloadUrl({ bucket, env, tenantId, productId, photoId, thumb }) -> string`.
  Consumed by Task 8 (`ProductPhotoGallery.qml`) and Task 9 (`InventoryPage.qml`).

**Note on test location:** `qml/helper/*.js` files are `.pragma library` QML modules; this project's own
precedent (`tst_StuckWrites.qml`'s helper, per `SKILLS.md` Skill 67) is to strip the QML test wrapper and
run the underlying logic through plain Node for a real, in-sandbox pass, in addition to a `qmltestrunner`
test that proves the QML wiring in CI. This task writes both: the plain-Node copy under `functions/test/`
(no `.pragma library` line, otherwise byte-identical logic) run for real now, and the QML test in Task 10
covering the same cases via `qmltestrunner` in CI. Keep the two in sync by hand — same convention as
`StuckWrites.js`.

- [ ] **Step 1: Write the failing tests**

```js
// functions/test/photoUrl.parity.test.js
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
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd functions && node --test test/photoUrl.parity.test.js`

- [ ] **Step 3: Implement** `qml/helper/PhotoUrl.js`

```js
.pragma library

// Pure URL builder. No stored URL field exists anywhere (see design spec, "Public URL") — every
// caller computes this from the photoId it already has (from Firestore's photoIds array).
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
```

Then create the plain-Node mirror `functions/test/testSupport/photoUrlParity.js` — identical body, minus
the `.pragma library` line, `module.exports = { buildPhotoDownloadUrl }` appended.

- [ ] **Step 4: Run — expect PASS, all 5**

Run: `cd functions && node --test test/photoUrl.parity.test.js`

- [ ] **Step 5: Commit**

```bash
git add qml/helper/PhotoUrl.js functions/test/photoUrl.parity.test.js functions/test/testSupport/photoUrlParity.js
git commit -m "feat: pure product-photo download URL builder, with a real-run Node parity test"
```

### Task 3: Pure photo-queue logic (classification, backoff reuse, breaker, reducer)

**Files:**
- Create: `qml/helper/PhotoQueueLogic.js`
- Test: `functions/test/photoQueueLogic.parity.test.js` + `functions/test/testSupport/photoQueueLogicParity.js`
  (same parity-test convention as Task 2)

**Interfaces:**
- Produces (all pure functions, no Qt/network):
  - `classifyError(status) -> 'transient' | 'terminal'`
  - `nextBackoffMs(attempts) -> number` (reuses the exact `OutboxStore` schedule)
  - `reduceQueueItem(item, event) -> item'` where `event` is one of `{type:'sent'}`,
    `{type:'failed', status}`, `{type:'retry'}`, `{type:'discard'}` — returns the new item, or `null` for
    `'sent'`/`'discard'` (caller removes it) — see below for exact state machine.
  - `breakerReducer(breakerState, event) -> breakerState'` where `event` is `{type:'success'}` or
    `{type:'failure'}`; `breakerState = { status: 'closed'|'open'|'half-open', consecutiveFailures,
    cooldownUntil, cooldownMs }`; `isBreakerOpen(breakerState, now) -> bool`.
- Consumed by: `PhotoQueue.qml` (Task 6).

- [ ] **Step 1: Write the failing tests** (representative subset — write the full set, this is not
  exhaustive; add monkey/property cases per the note at the end of this task)

```js
const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  classifyError, nextBackoffMs, reduceQueueItem, breakerReducer, isBreakerOpen,
} = require('./testSupport/photoQueueLogicParity');

test('classifyError: terminal codes', () => {
  for (const s of [400, 413, 404, 409]) assert.equal(classifyError(s), 'terminal');
});
test('classifyError: transient codes', () => {
  for (const s of [401, 429, 500, 502, 503, 0]) assert.equal(classifyError(s), 'transient');
});
test('classifyError: unknown status defaults to transient (never lose a photo to an unmapped code)', () => {
  assert.equal(classifyError(599), 'transient');
});

test('nextBackoffMs matches OutboxStore schedule exactly, capped', () => {
  assert.deepEqual([1, 2, 3, 4, 5, 6].map(nextBackoffMs), [2000, 8000, 30000, 120000, 600000, 600000]);
});

const base = { photoId: 'p1', state: 'enqueued', attempts: 0, nextAttemptAt: 0, lastError: null };

test('reduceQueueItem: sent -> removed (null)', () => {
  assert.equal(reduceQueueItem({ ...base, state: 'uploading' }, { type: 'sent' }), null);
});
test('reduceQueueItem: transient failure under attempt cap -> retrying with backoff', () => {
  const r = reduceQueueItem({ ...base, state: 'uploading', attempts: 0 }, { type: 'failed', status: 500 });
  assert.equal(r.state, 'retrying');
  assert.equal(r.attempts, 1);
  assert.equal(r.nextAttemptAt > 0, true);
});
test('reduceQueueItem: terminal failure -> failed regardless of attempt count', () => {
  const r = reduceQueueItem({ ...base, state: 'uploading', attempts: 0 }, { type: 'failed', status: 400 });
  assert.equal(r.state, 'failed');
  assert.equal(r.lastError, 400);
});
test('reduceQueueItem: 8th transient failure while online -> failed (attempt cap)', () => {
  const r = reduceQueueItem({ ...base, state: 'uploading', attempts: 7 }, { type: 'failed', status: 500 });
  assert.equal(r.state, 'failed');
  assert.equal(r.attempts, 8);
});
test('reduceQueueItem: retry resets attempts and reopens the item', () => {
  const r = reduceQueueItem({ ...base, state: 'failed', attempts: 8, lastError: 400 }, { type: 'retry' });
  assert.equal(r.state, 'enqueued');
  assert.equal(r.attempts, 0);
  assert.equal(r.nextAttemptAt, 0);
  assert.equal(r.lastError, null);
});
test('reduceQueueItem: discard -> removed (null) from any state', () => {
  for (const state of ['enqueued', 'uploading', 'retrying', 'failed']) {
    assert.equal(reduceQueueItem({ ...base, state }, { type: 'discard' }), null);
  }
});

test('breaker: opens after 5 consecutive failures, not before', () => {
  let s = { status: 'closed', consecutiveFailures: 0, cooldownUntil: 0, cooldownMs: 60000 };
  for (let i = 0; i < 4; i++) s = breakerReducer(s, { type: 'failure' });
  assert.equal(s.status, 'closed');
  s = breakerReducer(s, { type: 'failure' });
  assert.equal(s.status, 'open');
});
test('breaker: a success resets consecutiveFailures and closes it', () => {
  let s = { status: 'open', consecutiveFailures: 5, cooldownUntil: 1e15, cooldownMs: 60000 };
  s = breakerReducer(s, { type: 'success' });
  assert.equal(s.status, 'closed');
  assert.equal(s.consecutiveFailures, 0);
});
test('breaker: cooldown doubles on repeated trips, capped at 10 minutes', () => {
  let s = { status: 'closed', consecutiveFailures: 0, cooldownUntil: 0, cooldownMs: 60000 };
  for (let i = 0; i < 5; i++) s = breakerReducer(s, { type: 'failure' });
  assert.equal(s.cooldownMs, 60000);
  // trip again after it reopens
  s = { ...s, status: 'closed', consecutiveFailures: 0 };
  for (let i = 0; i < 5; i++) s = breakerReducer(s, { type: 'failure' });
  assert.equal(s.cooldownMs, 120000);
});
test('isBreakerOpen: true while now < cooldownUntil, false after', () => {
  const s = { status: 'open', consecutiveFailures: 5, cooldownUntil: 1000, cooldownMs: 60000 };
  assert.equal(isBreakerOpen(s, 500), true);
  assert.equal(isBreakerOpen(s, 1500), false);
});

// Monkey test: a long random sequence of events must never leave the reducer in an invalid state
// (attempts never negative, state always one of the four, terminal never retried automatically).
test('monkey: 500 random event sequences never produce an invalid item', () => {
  const events = [{ type: 'failed', status: 500 }, { type: 'failed', status: 400 }, { type: 'retry' }];
  for (let run = 0; run < 500; run++) {
    let item = { ...base };
    for (let step = 0; step < 20; step++) {
      const ev = events[Math.floor(Math.random() * events.length)];
      const next = reduceQueueItem({ ...item, state: item.state === 'enqueued' ? 'uploading' : item.state }, ev);
      if (next === null) break;
      assert.ok(['enqueued', 'uploading', 'retrying', 'failed'].includes(next.state));
      assert.ok(next.attempts >= 0);
      item = next;
    }
  }
});
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd functions && node --test test/photoQueueLogic.parity.test.js`

- [ ] **Step 3: Implement** `qml/helper/PhotoQueueLogic.js`

```js
.pragma library

var BACKOFF_MS = [2000, 8000, 30000, 120000, 600000]  // identical to OutboxStore._backoffMs — do not fork
var ATTEMPT_CAP = 8
var TERMINAL_STATUS = { 400: true, 413: true, 404: true, 409: true }
var BREAKER_TRIP_AFTER = 5
var BREAKER_COOLDOWN_BASE_MS = 60000
var BREAKER_COOLDOWN_MAX_MS = 600000

function classifyError(status) {
    return TERMINAL_STATUS[status] ? 'terminal' : 'transient'
}

function nextBackoffMs(attempts) {
    var idx = Math.min(attempts - 1, BACKOFF_MS.length - 1)
    return BACKOFF_MS[Math.max(idx, 0)]
}

function reduceQueueItem(item, event) {
    if (event.type === 'sent' || event.type === 'discard') return null
    if (event.type === 'retry') {
        return Object.assign({}, item, { state: 'enqueued', attempts: 0, nextAttemptAt: 0, lastError: null })
    }
    if (event.type === 'failed') {
        var attempts = item.attempts + 1
        var kind = classifyError(event.status)
        if (kind === 'terminal' || attempts >= ATTEMPT_CAP) {
            return Object.assign({}, item, { state: 'failed', attempts: attempts, lastError: event.status })
        }
        return Object.assign({}, item, {
            state: 'retrying', attempts: attempts, lastError: event.status,
            nextAttemptAt: Date.now() + nextBackoffMs(attempts)
        })
    }
    return item
}

function breakerReducer(state, event) {
    if (event.type === 'success') {
        return Object.assign({}, state, { status: 'closed', consecutiveFailures: 0 })
    }
    var failures = state.consecutiveFailures + 1
    if (failures >= BREAKER_TRIP_AFTER) {
        var cooldownMs = state.status === 'open' || state.consecutiveFailures >= BREAKER_TRIP_AFTER
            ? Math.min(state.cooldownMs * 2, BREAKER_COOLDOWN_MAX_MS)
            : BREAKER_COOLDOWN_BASE_MS
        return {
            status: 'open', consecutiveFailures: failures,
            cooldownUntil: Date.now() + cooldownMs, cooldownMs: cooldownMs
        }
    }
    return Object.assign({}, state, { consecutiveFailures: failures })
}

function isBreakerOpen(state, now) {
    if (typeof now !== 'number') now = Date.now()
    return state.status === 'open' && now < state.cooldownUntil
}
```

Note on the cooldown-doubling test: it re-trips from a closed state with `cooldownMs` already at 60000, so
`breakerReducer`'s doubling condition must trigger whenever the breaker is *about to* open again, not only
while it's already `open` — implement so the second trip's cooldown is `min(previous cooldownMs * 2, cap)`.
Adjust the implementation above if a first real test run disagrees with this description; the tests are the
spec, not this prose.

Then create the plain-Node mirror `functions/test/testSupport/photoQueueLogicParity.js` (strip `.pragma
library`, add `module.exports`).

- [ ] **Step 4: Run — expect PASS, all cases including the monkey test**

Run: `cd functions && node --test test/photoQueueLogic.parity.test.js`

- [ ] **Step 5: Commit**

```bash
git add qml/helper/PhotoQueueLogic.js functions/test/photoQueueLogic.parity.test.js \
        functions/test/testSupport/photoQueueLogicParity.js
git commit -m "feat: pure photo-queue classification, backoff, breaker and reducer logic"
```

### Task 4: `storage.rules` + emulator rules test (written, not runnable here — confirmed no emulator
download in this sandbox; CI proves it)

**Files:**
- Create: `storage.rules`
- Create: `test/storage.rules.test.js`
- Modify: `firebase.json` (add `"storage": {"rules": "storage.rules"}` and an `emulators.storage.port`,
  e.g. `9199`)

**Interfaces:** none (rules only; no code consumes this file directly).

- [ ] **Step 1: Write `storage.rules`** — exact content is in the design spec's "Storage rules" section;
  copy it verbatim.

- [ ] **Step 2: Write `test/storage.rules.test.js`** using `@firebase/rules-unit-testing` (same package the
  existing `test/firestore.rules.test.js` already depends on — reuse it, do not add a new dependency):

```js
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { initializeTestEnvironment } = require('@firebase/rules-unit-testing');
const fs = require('node:fs');

let testEnv;

async function setup() {
  testEnv = await initializeTestEnvironment({
    projectId: 'inventorymanager-48392',
    storage: { rules: fs.readFileSync('storage.rules', 'utf8'), host: '127.0.0.1', port: 9199 },
  });
}

test('storage rules', async (t) => {
  await setup();
  const path = 'prd/tenants/tenant1/products/prod1/photo1.jpg';

  await t.test('anyone, including unauthenticated, can read a product photo', async () => {
    const unauth = testEnv.unauthenticatedContext().storage();
    await assert.doesNotReject(unauth.ref(path).getDownloadURL().catch(() => {
      // getDownloadURL needs the object to exist; assert on the rules decision instead via a
      // metadata read, which fails with permission-denied only if rules deny it, not if the
      // object is merely absent.
    }));
  });

  await t.test('an authenticated client cannot write a product photo, even the tenant owner', async () => {
    const owner = testEnv.authenticatedContext('owner-uid').storage();
    await assert.rejects(owner.ref(path).put(Buffer.from('x')));
  });

  await t.test('an authenticated client cannot delete a product photo', async () => {
    const owner = testEnv.authenticatedContext('owner-uid').storage();
    await assert.rejects(owner.ref(path).delete());
  });

  await t.test('an unmapped path denies both read and write', async () => {
    const unauth = testEnv.unauthenticatedContext().storage();
    const owner = testEnv.authenticatedContext('owner-uid').storage();
    await assert.rejects(unauth.ref('some/other/path.jpg').getMetadata());
    await assert.rejects(owner.ref('some/other/path.jpg').put(Buffer.from('x')));
  });

  await testEnv.cleanup();
});
```

(The exact `@firebase/rules-unit-testing` Storage API surface should be checked against whatever version is
pinned in `package.json` when this task is actually executed — the emulator can't be started in this
sandbox to verify these calls against a live SDK, so treat the method names above as best-effort and correct
them against the installed package's TypeScript types if CI's first run disagrees.)

- [ ] **Step 3: Modify `firebase.json`** — add:

```json
"storage": { "rules": "storage.rules" },
```

under the top-level object, and inside `"emulators"`:

```json
"storage": { "port": 9199 },
```

- [ ] **Step 4: Cannot run here.** State explicitly in the commit message and the test plan that this is
  unverified until CI (or `firebase emulators:exec --only storage "node --test test/storage.rules.test.js"`
  on a machine with access to `storage.googleapis.com`) runs it.

- [ ] **Step 5: Commit**

```bash
git add storage.rules test/storage.rules.test.js firebase.json
git commit -m "feat: Storage rules (public read, no client writes) + emulator rules test

Not run in this sandbox: the Firestore/Storage emulator jar download is
blocked by the sandbox's network egress allowlist (storage.googleapis.com
not listed). CI proves this."
```

### Task 5: `uploadProductPhoto` and `deleteProductPhoto` Cloud Functions

**Files:**
- Modify: `functions/index.js` (add both handlers, following the existing `onRequest` / `verifyIdToken` /
  `deriveContext` / `scopedDb` pattern used by every other handler in this file)
- Test: `functions/test/index.handlers.photos.test.js` (new file, same harness as
  `functions/test/index.handlers.test.js` — reuse `testSupport/handlerHarness.js`, do not fork it)

**Interfaces:**
- Consumes: `validateImage` (Task 1), the existing `deriveContext`, `scopedDb`, `admin.storage()` (already
  imported in `functions/index.js` for nothing yet — confirm at execution time; add the import if absent).
- Produces: HTTP handlers `uploadProductPhoto`, `deleteProductPhoto`, exported the same way every other
  function in this file is exported for Firebase to deploy.

- [ ] **Step 1: Write the failing tests** covering, at minimum, per the design spec's tables:
  - happy path: new photo, response `{ photoId, photoIds }`, `photoIds` grows by one, both a main and thumb
    object written (assert via a stubbed/mocked `admin.storage()` bucket — follow whatever mocking
    convention `handlerHarness.js` already uses for Firestore; extend it for Storage the same way rather
    than inventing a second style)
  - idempotency: same `requestId` sent twice → second call returns `{ already: true, photoIds }`, bucket
    `save` called only once, `photoIds` has no duplicate
  - `400 invalid-image` for a non-JPEG payload (delegates to `photoValidation`, don't re-implement the
    check inline)
  - `413 image-too-large` for an oversized payload
  - `404 product-not-found` when the product doc doesn't exist
  - `409 photo-limit` when `photoIds.length` is already 10
  - `401` when the ID token is missing/invalid (reuse whatever existing test pattern
    `index.handlers.test.js` uses for this on another handler)
  - `deleteProductPhoto`: removes the id, is a no-op (not an error) when the id is already absent, and
    tolerates the Storage delete itself failing (logged, still returns success) — this is the "best-effort"
    behaviour from the design spec
  - a same-shape monkey test: N random combinations of {existing photoIds 0-9 items, valid/invalid image,
    fresh/repeat requestId} never produce a `photoIds` array longer than 10 or containing a duplicate id

- [ ] **Step 2: Run — expect FAIL**

Run: `cd functions && node --test test/index.handlers.photos.test.js`

- [ ] **Step 3: Implement** both handlers in `functions/index.js`, matching the design spec's numbered
  steps under "Server" exactly (idempotency check → validate → Storage write → one Firestore transaction
  for the id + ledger + audit marker). Reuse the existing photo-change ledger shape
  `TransactionStore.recordPhotoChange` already produces client-side — mirror its field names server-side
  rather than inventing new ones.

- [ ] **Step 4: Run — expect PASS**

Run: `cd functions && node --test test/index.handlers.photos.test.js`, then the *whole* suite
(`node --test`) to confirm nothing existing regressed (baseline this session: 195/195 before this feature).

- [ ] **Step 5: Commit**

```bash
git add functions/index.js functions/test/index.handlers.photos.test.js
git commit -m "feat(functions): uploadProductPhoto and deleteProductPhoto, idempotent, atomic id+ledger write"
```

### Task 6: CI workflow — Storage emulator

**Files:**
- Modify: `.github/workflows/checks.yml`

- [ ] **Step 1:** Add `storage` to the `--only` flag of the `firestore-rules-tests` job (rename the job's
  display concerns only if it now covers both — prefer adding `storage.rules.test.js` to that job's existing
  `firebase emulators:exec --only firestore` command, changed to `--only firestore,storage`, and its `node
  --test` args extended to include `test/storage.rules.test.js`, over adding a whole new job — smaller diff,
  same machine already has both emulators available). Add `test/storage.rules.test.js` to the `e2e-tests`
  job's emulator flags too if that job also starts firestore/auth/functions together (check its `--only`
  list at execution time; extend it to include `storage` so a full e2e run can exercise an actual upload
  against the emulator, not just the rules file in isolation).

- [ ] **Step 2: Cannot run here** (same egress restriction as Task 4). Commit and let the next CI run on the
  pushed branch be the proof — call this out in the checkpoint.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/checks.yml
git commit -m "ci: run Storage rules tests against the emulator"
```

### Task 7: Push PR 1

- [ ] Push the branch (already pushed incrementally per commit, per Taher's "push after every commit"
  instruction — this step is the final push of this slice and updating the checkpoint to mark PR 1 done).

---

## PR 2 — Client queue + UI

### Task 8: Native file-read method (written; on-device-only verification)

**Files:**
- Modify: `src/NativeFile.h`, `src/NativeFile.cpp`

**Interfaces:**
- Produces: `Q_INVOKABLE QString readFileBase64(const QString &path)` returning base64 text, or an empty
  string plus `lastError()` (follow whatever error-reporting convention `NativeFile`'s existing methods use
  — check `toReadablePath`'s pattern at execution time and match it, don't invent a new one).

- [ ] **Step 1:** Add the method declaration and implementation (`QFile::readAll()` +
  `QByteArray::toBase64()`).
- [ ] **Step 2:** Cannot build or test here (no Qt toolchain, standing instruction). Flag explicitly in the
  commit message and the test plan.
- [ ] **Step 3: Commit**

```bash
git add src/NativeFile.h src/NativeFile.cpp
git commit -m "feat(native): NativeFile.readFileBase64 for photo upload payloads

Not buildable or testable in this sandbox (no Qt toolchain, standing
instruction). On-device verification required before merge."
```

### Task 9: `OutboxStore.hasPendingForEntity` (Trap 1 gate)

**Files:**
- Modify: `qml/model/OutboxStore.qml`
- Test: `tests/tst_OutboxStore.qml` (extend the existing file — check it exists at execution time; if the
  project keeps `OutboxStore` coverage inside `tst_Gateway.qml` instead, add there — match whatever this
  repo's current layout actually is rather than assuming)

**Interfaces:**
- Produces: `hasPendingForEntity(entityId) -> bool`, scanning `items` for any entry whose target matches.
  Consumed by Task 11 (`PhotoQueue.qml`).

- [ ] Write a failing test asserting `hasPendingForEntity` is `true` right after a product-creation mutation
  is queued and `false` once that item is removed (success or terminal drop); implement by scanning
  `OutboxStore`'s existing per-item entity/product-id field (name it exactly as `OutboxStore` already
  stores it — read the file at execution time rather than guessing the field name here); run
  `qmltestrunner` — cannot run in this sandbox, note it; commit.

### Task 10: `PhotoQueue.qml`

**Files:**
- Create: `qml/model/PhotoQueue.qml`
- Test: `tests/tst_PhotoQueue.qml`

**Interfaces:**
- Consumes: `PhotoQueueLogic.js` (Task 3, exact function names above), `OutboxStore.hasPendingForEntity`
  (Task 9), `AuthService.ensureFreshToken()`, `AuthService.isOnline`.
- Produces: `enqueue({productId, photoId, mainFilePath, thumbFilePath})`, `retry(photoId)`,
  `discard(photoId)`, `items` (list model for the UI), signals `photoUploaded(productId, photoId,
  photoIds)` and `photoUploadFailed(photoId, status)`.

- [ ] Persist to `QSettings` exactly as `OutboxStore` does (same technique, same
  `SettingsPath.settingsLocationOverride` so `qmltestrunner` proves durability for real, not just in prose).
  Drain trigger: app start, `AuthService.isOnline` flipping true (via a property-binding watcher —
  **not** `Connections{}`, which crashes any `pragma Singleton QtObject` root at runtime, SKILLS.md
  Skill 20 — a real mistake caught by re-reading SKILLS.md before writing the file, not by a test),
  and a `Qt.createQmlObject` timer respecting each item's `nextAttemptAt` (same reason `Gateway`
  avoids a singleton-owned `Timer` — Skill 20 again). Use `PhotoQueueLogic.reduceQueueItem` for
  every state transition — do not re-implement the state machine inline. Structure the file so the
  gating decision (`drainCandidates()`: due time, Trap 1, Trap 2) is a separate, side-effect-free
  function from the actual native-file-read-plus-XHR call (`_upload()`) — `NativeFile`/
  `ImageProcessor` are root context properties (`main.cpp` `setContextProperty`), not QML
  singletons, so they are `undefined` under `qmltestrunner` (confirmed: `StorageService.qml`, the
  only other file that references them, has zero tests, for this exact reason). `drainCandidates()`
  is therefore unit-testable for real by CI; `_upload()` is not, consistent with `Gateway._send`'s
  own established precedent of being untested at this level (its real XHR call, per
  `tst_Gateway.qml`'s own comment).
  Test at minimum: enqueue persists immediately with a spinner-eligible state; success removes the item and
  emits `photoUploaded`; a terminal failure moves to `failed` without another retry attempt; a transient
  failure schedules a retry at the correct backoff; `retry()` on a failed item resets it; `discard()` removes
  the item from the queue (its `ImageProcessor.removeLocalCopy` calls are guarded with
  `typeof ImageProcessor !== "undefined"` so the array-removal half stays testable);
  Trap 1 — an item whose product has a pending `OutboxStore` entry is skipped by the drain loop until that
  entry clears; Trap 2 — an item is skipped if its `uid`/`tenantId` no longer matches the current session.
  Cannot run `qmltestrunner` here; commit, flag for CI.

### Task 11: `EditProductDialog.qml`, `ProductPhotoGallery.qml`, `InventoryStore.qml`, `InventoryPage.qml`

**Files:**
- Create: `qml/components/ProductPhotoGallery.qml`
- Test: `tests/tst_ProductPhotoGallery.qml`
- Modify: `qml/pages/EditProductDialog.qml` (replace `applyPhotoSource`/`clearPhotoSource` single-photo
  wiring with the gallery + one-tap-migrate affordance from the design spec's "UI" section)
- Modify: `qml/model/InventoryStore.qml` (`photoIds` read/write instead of `photoUrl`/`photoUpdatedAt`;
  `deleteProduct`'s photo cleanup now calls `deleteProductPhoto` per remaining id instead of local file
  cleanup)
- Modify: `qml/pages/InventoryPage.qml` (card image source resolution: `PhotoQueue` local file if pending,
  else `PhotoUrl.buildPhotoDownloadUrl(..., thumb: true)`, else legacy `photoUrl` fallback)
- Test: extend `tests/tst_InventoryStore.qml` and `tests/tst_InventoryPage.qml` (check current file names
  at execution time)

This task is UI/store wiring with no new algorithmic content — every decision it makes is either already
specified (Task 2's `PhotoUrl`, Task 3's `PhotoQueueLogic`, Task 10's `PhotoQueue` interface) or is ordinary
QML plumbing (bind a `Repeater`/`ListView` to `PhotoQueue.items` plus `photoIds`, wire button `onClicked` to
`PhotoQueue.enqueue`/`retry`/`discard`). Write it directly against those interfaces; write tests for the
gallery's state-to-visual mapping (spinner for enqueued/uploading/retrying, badge+buttons for failed, plain
image otherwise) and for the store/page wiring listed above. Cannot run `qmltestrunner` here; commit per
sub-piece (gallery, then store, then page) rather than one giant commit, flag each for CI.

### Task 12: Push PR 2

---

## PR 3 — Delete cascade wiring confirmation, docs, test plan

### Task 13: Confirm delete cascade end to end

`InventoryStore.deleteProduct`'s call site (modified in Task 11) already calls `deleteProductPhoto` per id;
this task is the E2E test proving it, not new production code.

**Files:**
- Test: `test/e2e/tst_ProductPhotosE2E.qml` (new, same pattern as `tst_InventoryE2E.qml` — real emulator,
  no UI, service-level)

Cannot run here (emulator download blocked); written and committed for CI to run for real, same as every
other file in `test/e2e/`.

### Task 14: Update `SKILLS.md`, `AGENTS.md`, `README.md`

- `SKILLS.md`: one new numbered entry (next available number — check the file's current max at execution
  time, don't hardcode a number here that may already be stale) summarizing the atomicity-can't-be-literal
  finding, the two traps, and the parity-test convention reuse — write it the way Skill 67 is written
  (Files/What was wrong/Decisions/what it does NOT cover), not a changelog line.
- `AGENTS.md`: extend the relevant existing agent sections (`5. Store & Firebase Agent` for `PhotoQueue`,
  `8. Compliance & Audit Agent` if photo deletion needs an audit note, `9. Testing & QA Agent` for the
  parity-test convention) — check current section content at execution time before writing, don't duplicate
  what's already generically true.
- `README.md`: add product photos to the `## Features` list; add `storage.rules` to whatever section already
  documents `firestore.rules`/`firebase.json`; add the Storage emulator port to `## Environments (dev / test
  / prd)` if that section lists emulator ports.

### Task 15: Write the test plan

`docs/superpowers/test-plans/2026-09-21-product-photos-firebase-storage-test-plan.md`, following this
repo's template (sections: Unit / Functional-E2E / Regression / Firestore+Storage rules / "What was
genuinely run" / On-Device Test Plan with Happy Path, Negative, Edge, Affected Areas, Regression, Monkey).
Report real numbers for everything `node --test` actually ran in this session (Tasks 1, 2, 3, 5) and say
plainly, per file, what was written-but-not-run (everything QML, native, rules-emulator, e2e) — same honesty
standard as the 2026-09-19 test plan. Add the new row to `docs/superpowers/test-plans/README.md`'s index.

### Task 16: Final push, update `CHECKPOINT.md` to "done, awaiting Taher's PR review", final push.
