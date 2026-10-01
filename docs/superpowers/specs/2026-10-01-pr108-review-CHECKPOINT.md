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

## Answers (Taher, 2026-10-01) and resolution
- **Q-A:** cap 5 attempts. Recorded as Q12; mechanics in PH3b.
- **Q-B:** product id not found: delete locally; photo whose product id is not found: delete from Storage. Verified in code: BOTH ALREADY HOLD. `deleteProductPhoto` tolerates a missing product and deletes the objects; server-absent product delete returns 409 `current:null` and `InventoryStore._onMutationConflicted` removes the local row. Only defect: the toast says "restored". Recorded as Q13: no server change, pin tests F40/F41, PH4 toast fix (C26). Upload to a missing product stays 404, zero Storage writes (Q1).
- **Q-C:** rename to PH3/PH4/PH5. Done in spec, test plan, README row, old checkpoint. Q14.
- **Q-D:** scheduled function, own separate session, with error and response handling. Q6 amended, Q15. PH3 loses the drain; PH3b section added to the spec with a proposal and open questions Q-E..Q-I.

## Fixes applied (docs only)
C1 rules (`isServerOnlyCollection`), I1 cap (Q12), I2 marker `envPrefix` + U48, I3 one real file per case, I4 on-device row, I5 rename, M1 base note + checkpoint NEXT amended. `requestId` dropped from marker (ponytail). Test plan now 138 cases: unit 41, functional 36, rules 11, e2e 12, QML 26 + 12. Ids not renumbered (gaps = moved to PH3b).

## OPEN (design NOT complete)
Only PH3b: Q-E schema (`nextAttemptAt` + park by removing the field, advised), Q-F cadence/backoff/envs (10 min, linear x10 min, all 3), Q-G throw-at-end (advised), Q-H keep immediate post-commit sweep (advised), Q-I Blaze + Cloud Scheduler + who deploys (UNVERIFIED). PH3, PH4, PH5 designs are complete.

## NEXT (resume here)
1. Merge PR #108 (after Taher reviews). 2. Start PH3 on `feat/2026-10-01-photos-ph3-server`, task order in the old checkpoint NEXT minus the drain steps; Node tests run in sandbox (`cd functions && npm ci && node --test`). 3. PH3b in its own session after Taher answers Q-E..Q-I. 4. Re-run ponytail-audit and qt-qml-review at PH4/PH5 (first QML diffs).
