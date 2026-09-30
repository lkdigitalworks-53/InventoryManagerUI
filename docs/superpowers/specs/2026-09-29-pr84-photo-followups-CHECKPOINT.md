# CHECKPOINT — PR #84 photo follow-ups (workstream: photos, separate from roadmap-B in `CHECKPOINT.md`)

**Commit identity:** `tsadmin@gmail.com`. **Skills:** systematic-debugging, qt-qml, ponytail (caveman FULL, chat only).
**Rules:** branch only; push without asking (owner reviews in PR); PAT never in repo; no build/run; no Qt tooling in sandbox (CI is the QML signal); one item (or narrow group) per session; honest advisor, trade-offs before decisions.
**Origin:** final-sweep review of PR #84 (merged 2026-09-29 with F1/F2 unfixed at owner's choice). Findings table: test plan `docs/superpowers/test-plans/2026-09-21-product-photos-firebase-storage-test-plan.md` § "Final-sweep findings".

## Session 2 (this PR): F1 + F2 + F4 — client queue. DONE, unrun (CI is the proof)
| Item | Root cause (traced) | Fix | Tests |
|---|---|---|---|
| F1 | `_upload` persists `uploading`; `_load()` never repaired it; drain/reschedule only take `enqueued`/`retrying` | `PhotoQueue._load()` maps `uploading` -> `enqueued`, attempts kept (server dedupes by `requestId`) | `tst_PhotoQueue` 5 tests |
| F2 | `deleteProduct` walked confirmed `photoIds` only; queue items pointing at the product never touched. One caller path (`DataModel:327`) | `InventoryStore.deleteProduct` discards every queue item of the product (snapshot `filter().forEach(discard)`) | `tst_InventoryStore_deleteProductCascade` 8 tests incl. monkey and late-confirmation |
| F4 | `_upload` returns on empty `idToken`; nothing re-armed when token arrived | `_tokenWatcher` property watcher -> `drainNow()` (non-empty token + non-empty queue only; no polling) | `tst_PhotoQueue` 9 tests (5 + 4 from sweep 2) |

Evidence: Node-run sanity of the two logic snippets only (recovery map, snapshot-discard). No QML test was run.
Known ceiling: upload already in flight at delete time can still land server-side (Storage orphan) — needs server-side cleanup (roadmap item 4).
Not done on purpose: auto-discarding on terminal 404 (a misdeployed function also 404s: data loss) and purging queue items absent from the synced product list (offline-created products are not synced yet: would delete valid photos). Remote-device deletes therefore still leave a parked item; accepted, revisit only with a distinguishable server error code.

## NEXT SESSIONS (one each, in this order). Grill the owner on the decision BEFORE coding.
**S3 — server: F3 + F5 (+ N2 if cheap).** Node tests run for real here (`functions/test/`, real proof).
- F3 orphan objects: uploadProductPhoto writes 2 Storage objects before 404 (product missing) / 409 (cap) checks. Options: (a) read product + count first (one extra Firestore read per upload, no orphans; recommended), (b) write then delete on 404/409 (delete can fail -> orphan), (c) accept orphans (rare paths, bytes only).
- F5 `before` conflict: `gatewayLogic.js:158` deep-equals the whole doc, `photoIds` included; a photo confirmed between edit and drain 409s an unrelated price/stock edit. Options: (a) server excludes `photoIds` from the `before` compare and preserves the current value on write (one place, fixes every client; safe because only photo endpoints write `photoIds`; recommended), (b) client strips it at every full-doc update site (many sites, easy to miss), (c) leave (user-visible spurious conflicts).
- N2 no role check on photo endpoints (viewer can upload/delete): same known gap as `recordMutation` (KNOWN-ISSUES.md). Fix only if the role is already on `ctx`; otherwise leave documented.
**S4 — hygiene: N1 + P2 + N3(dup numbering).** `StorageService.qml:28` id `photo-<Date.now()>-<rand>`: public-read paths are guessable-ish; `Qt.uuid()` minus braces, verify `photoValidation.js` charset first. Delete dead `InventoryStore.setPhoto`. Renumber the duplicate Skill 75/76 headings in SKILLS.md (check cross-refs first).
**Owner decision needed (my honest advice):** P1 (delete `FailedTileGeometry.js` + test + spec, ~-300 lines) — I now advise **do not do it**. It is merged, tested, device-verified UI; the replacement cannot be rendered or tested here; savings are LOC only. Touch-target sizes (20/28/36dp) are a device-UX call: enlarging fights the fixed 72dp tile, decide with a screenshot.

## Files touched this session
`qml/model/PhotoQueue.qml`, `qml/model/InventoryStore.qml`, `tests/tst_PhotoQueue.qml`, `tests/tst_InventoryStore_deleteProductCascade.qml`, test plan, `SKILLS.md` (Skill 85), `AGENTS.md`, this file, one pointer in `CHECKPOINT.md`.
