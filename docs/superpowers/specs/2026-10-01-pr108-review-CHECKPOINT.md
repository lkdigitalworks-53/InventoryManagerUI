# CHECKPOINT: review of PR #108 (photos S3/S4/S5 design + test plan), 2026-10-01

**Branch:** `docs/2026-10-01-pr108-review` (off PR #108 head `0af0c9d`). **Identity:** `tsadmin@gmail.com`. Docs only, nothing built or run.
**Skills run:** requesting-code-review (no subagent tool here, so reviewed inline), ponytail-audit (design-level), qt-qml-review (no `.qml` in the diff: lint = 0 findings, qmllint not applicable; re-run at S4/S5).
**Verdict:** NOT mergeable as is. 1 critical + 5 important doc fixes, then ready for S3. No code written, so fixes are small edits.

## Step log
1. Read skills, cloned repo, fetched `pull/108/head`. PR touches 6 docs files (+453/-1). Base `0d77f9a`, main is now `52776d7` (#106, #109).
2. `git merge --no-commit pr108` into main: clean, no conflicts. Main drift is client-only (Gateway, OutboxStore, StuckWrites, tests); `functions/`, `firestore.rules`, `storage.rules` untouched since the PR base.
3. Verified design claims against `main` code (table below).
4. Wrote this file.

## Verified OK
- `ctx.role` exists (`deriveContext`, `functions/index.js` L76); owner/admin pattern already used L157, L648. `AuthStore.canManageInventory` = owner/admin (L33): gate matches.
- `ENTITY_COLLECTIONS` maps one entity per collection, so `entity==="inventory"` is the same as collection `inventory`; `isCascadeEntityDelete(entity, action)` is sound.
- `storageEnvPrefix` returns `dev1`/`test`/`prd`; all pass the proposed whitelist. Product ids are `PRD-###` (`InventoryStore.nextProductId`): pass whitelist.
- Skill 66 rename: diff is the single heading line. Test counts 47+39+11+12+25+12 = 146 add up.

## Findings

### Critical
**C1. Rules design would NOT deny access.** Design says add `match /pending_cleanup/{docId} { allow read, write: if false; }` before the wildcard. Firestore grants a request if ANY matching rule allows it, and `match /{collection}/{docId}` (`firestore.rules` L154) still allows members. The file's own comment (L55-58) says so. `locks` is safe only because it is ALSO listed in `isServerOnlyCollection` (L60: `name in ['locks']`). Fix: add `'pending_cleanup'` to that list (one word; the extra match block is optional). Design S3 "firestore.rules" section and old checkpoint step 16 must say this. R02-R05, R11 would catch it on CI, but the design as written would fail them.

### Important
**I1. Poison markers.** No attempts cap or backoff. Drain reads the 10 oldest then filters, so 10 permanently failing markers starve every newer one; each failing marker also adds awaited latency (up to 3 sweeps) to EVERY photo upload/delete. `attempts`/`lastError` are written and never read. Needs a decision (see Q-A).
**I2. Sweep guard not implementable as written.** "prefix == prefix rebuilt from the marker's ids" cannot work: marker has `productId`+`prefix` but no env segment (tenant comes from the doc path). Store `envPrefix` in the marker, or validate `prefix` against `^[A-Za-z0-9_-]{1,64}/tenants/{t}/products/{p}/$`. U45 must name which.
**I3. Test plan file paths wrong/vague.** Plan says `tests/e2e/`; real dir is `test/e2e/` (singular), mixing `.qml` and Node (`recordOperation.e2e.test.js`). Existing `test/e2e/tst_ProductPhotosE2E.qml` and `functions/test/index.handlers.photos.test.js` should be extended, not shadowed by a "new `photoCascade.handlers.test.js`". Rules tests are `test/firestore.rules.test.js` / `test/storage.rules.test.js`. Every U case lists both `photoValidation.test.js / photoCleanup.test.js`; every F case says "handlers / logic tests". Name one file per case.
**I4. False on-device row.** "`recordOperation` ... complete an order (ops path must still work)": grep finds no QML caller of `recordOperation(` outside its definition in `Gateway.qml`. Ops reject (F34/F35) is server-test only. Drop the row or say "no client coverage".
**I5. Slice name collision.** Stuck-writes already owns "S3" (`2026-09-30-s3-discard-resync-design.md`, branch `feat/2026-10-01-s3-discard-parked-writes`, #109 on main). Photos S3/S4/S5 same date prefix. Rename photos slices (e.g. PH3/PH4/PH5) in spec, plan, README row.

### Minor
- M1. Spec/checkpoint pinned to main `0d77f9a`; main is `52776d7`. Update the base line. Old checkpoint step 8 is out of order (after 35).
- M2. Unsafe inventory id on delete returns 400 and blocks the delete forever (see Q-B). Unverified: bulk import never takes ids from the spreadsheet.
- M3. `Qt.uuid()` headless, inventory 409 toast, export col 11 shift, E05 Storage failure hook: already listed as unknown, fine.

### Ponytail (design level, nothing applied)
- shrink: rules fix is one list entry (C1).
- delete: marker `requestId` is never read; `attempts`/`lastError` too unless I1 uses them.
- yagni check: `buildMarker`, `evaluateUploadPreflight` as separate exports are fine for testability; not worth fighting.
- Lean otherwise. Net: about -2 marker fields, -1 rules block.

## Questions for Taher (grill, one answer each)
- **Q-A poison markers:** (1) cap `attempts>=5` then skip + log (fixes starvation and latency, marker stays for manual look), (2) per-drain time budget, (3) leave as is. I advise (1).
- **Q-B unsafe id on inventory delete:** (1) 400 and block (current design, safe prefix, product undeletable), (2) allow delete, write no marker, log (orphans possible). Dev-only and ids are `PRD-###`: (1) is fine, just confirm import.
- **Q-C slice rename** PH3/PH4/PH5: yes/no.
- **Q-D revisit Q6 once:** piggyback drain (3 call sites, latency on user path, idle tenant waits) vs one scheduled function (no user latency, drains idle tenants, but needs a collection-group query/index across dev1/test/default DBs). You decided piggyback; I still lean scheduled, but your call stands unless you want to flip.

## NEXT (resume here)
Taher answers Q-A..Q-D. Then one small docs commit on PR #108's branch: fix C1, I1-I5, M1. Re-run `git merge --no-commit` vs main. Then S3 may start (`feat/2026-10-01-photos-s3-server`, Node tests runnable in sandbox: `cd functions && npm ci && node --test`).
