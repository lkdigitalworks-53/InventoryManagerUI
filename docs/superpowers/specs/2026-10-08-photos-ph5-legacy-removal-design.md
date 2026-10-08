# Photos PH5 — remove legacy PRODUCT `photoUrl` / `photoUpdatedAt` — design

**Status:** design only, no code. Questions Q-P5-1..6 below are OPEN until Taher answers; each has a recommended default. Facts were read on `main` @ `78fa742` (PH4 PR #133 is NOT merged; line numbers will move).
**Parent design:** `2026-09-30-photos-s3-s4-design.md` (Q8 decided: PH5 = full removal, own slice, after PH3/PH4). **Test plan:** `test-plans/2026-10-08-photos-ph5-test-plan.md`. **Checkpoint:** `2026-10-08-photos-ph5-design-CHECKPOINT.md`.
**Project facts (Taher):** dev env only, no legacy product `photoUrl`, new tenant per PR, app disabled offline. User-profile `photoUrl` (AuthStore, AuthService, ProfilePage, `provisionMember` in `functions/index.js`) is a different field and is NEVER touched.

## Scope (every product `photoUrl` site found by grep on main)
| File | Site | Action |
|---|---|---|
| `qml/model/InventoryStore.qml` | normalize L144-145; `_clone` L240-241; default product L268; `setPhoto` L673-686 (zero callers); `clearLegacyPhotoUrl` L718-727; `_normalizeRecord` L1036-1037; `_mergeRecord` keys L1048 (zero callers, see Q-P5-4) | remove |
| `qml/pages/EditProductDialog.qml` | property L31, load L147, `clearLegacyPhotoUrl` call L218-219, "Upload this photo" migration UI L299-305, header comment L14 | remove |
| `qml/pages/InventoryPage.qml` | card avatar fallback L241 `: (card.product.photoUrl \|\| "")` -> `""` | remove |
| `qml/model/StorageService.qml` | comments L12, L37 (legacy wording only) | reword |
| `src/XlsxService.cpp` | header L20, `doc.write(row, 11, ...)` L81, widths, template row "Photo URL" L251 | Q-P5-1 |
| `qml/pages/ImportPreviewDialog.qml` | `photoUrl: r["Photo URL"]` L460, dup-compare field L482 | Q-P5-2 |
| tests | `tests/tst_InventoryStore_photoIds.qml` L31 fixture, `tests/tst_InventoryStore_deleteProductCascade.qml` L126-163, `test/felgo-dependent/tst_InventoryPage_deleteButton.qml` L38 | edit |
| NOT touched | `AuthStore`, `AuthService`, `ProfilePage`, `functions/index.js:805` (`provisionMember`, user doc), `PhotoUrl.js` (name only: builds Storage download URLs, unrelated) | — |

## Facts that drive the questions (all verified in code)
1. **Import is keyed by header text** (`r["Min Stock"]`, `r["Photo URL"]` ...); no required-column list or unknown-column check exists. A file that still has a "Photo URL" column imports fine whether or not the app knows the column.
2. **Export is keyed by position** (`doc.write(row, 11 ...)`, `setColumnWidth(11, ...)`): removing a column shifts columns 12-15 to 11-14 in both writer and widths. The template ("Notes" sheet) is a hand-written row list, separate from `kProductHeaders`.
3. **Today `Photo URL` only reaches NEW rows.** The overwrite branch of `upsertMany` builds its own `fields` object without `photoUrl`, so the template text "Leave empty to keep the existing photo" is already false. A new imported row gets `photoUrl` = whatever URL was typed, and `InventoryPage` still renders it as the card avatar (the L241 fallback). After PH5 that value is dropped.
4. **`_mergeRecord` has zero callers** (grep) and was flagged "leave alone" in 2026-07 and again by the 2026-10-07 audit decision (do not delete zero-reference functions). It still contains the `photoUrl` keys, which would break the PH5 acceptance ("no product `photoUrl` token").
5. **THE TRAP — whole-document CAS.** `gatewayLogic._deepEqual(current, before)` requires identical key sets. Every product created by the current app is stored WITH `photoUrl: ""` and `photoUpdatedAt: ""`. Client `before` comes from `_clone()` (explicit field list). Once `_clone` stops emitting the two keys, `before` has 2 fewer keys than the stored doc -> `409` on EVERY update and delete of EVERY product that existed before PH5. The 409 handler restores the row from server `current`, `_clone` strips the keys again, the next attempt 409s again: permanent, with the misleading "restored with the latest version" toast. Fresh tenants are unaffected (new docs never get the keys).
6. `functions/test/` has no test for this and `test/felgo-dependent/` tests do NOT run in CI (`checks.yml` runs `qmltestrunner -input tests` only). So QML cannot cover S04-S08 as originally hoped.

## Decision ledger (OPEN — Taher answers; defaults in bold)
| ID | Question | Options and trade-offs | Recommendation |
|---|---|---|---|
| **Q-P5-1** | Export column 11 "Photo URL" | **A remove** (14 columns; cols 12-15 shift to 11-14; ~6 C++ lines; export format changes). B keep header, write blank (positions stable for anyone indexing by column number; dead column forever, confusing to every future reader, still needs a "reserved" comment). | **A.** Import is header-keyed (fact 1) so old exports keep importing; dev only, no external consumer. B only pays off if a spreadsheet formula somewhere indexes by position, and you have said no real data exists. |
| **Q-P5-2** | Import file that still has a "Photo URL" column | A silently ignore (0 extra code; a user who typed 40 URLs sees nothing happen, same "silent success" class of bug this repo keeps fixing). **B ignore + ONE non-blocking file-level warning** when the column exists and at least one cell is non-empty (pure helper `ImportMath.hasLegacyPhotoColumn(rows)` + ~3 lines in the dialog; the dialog already follows "show it, don't guess"). C reject the file (hostile to every old export). | **B.** Cost is one helper, one string, 4 tests. |
| **Q-P5-3** | Stored docs that already carry the two keys (fact 5) | **a Do nothing, fresh tenants only** (matches your standing practice; pin the consequence with a server test + a loud line in the PR and KNOWN-ISSUES: "pre-PH5 tenants are unusable, recreate"). b Keep passing the two keys through `_clone` (defeats the removal, rejected). c One-shot admin script stripping the keys (code + deploy for data you say does not exist). d Server `_deepEqual` ignores the two legacy keys on both sides; the next successful write drops them (self-healing, ~4 lines + tests, but loosens the money-path CAS comparator for two named keys and is permanent compat code you said you do not want). | **a**, with the pin test. Honest risk: if ANY tenant you still open predates PH5, every edit/delete on its products fails forever and the toast lies. If that can happen, choose **d** instead and delete it when the last old tenant is gone. Your call; I am not assuming it cannot. |
| **Q-P5-4** | Dead `_mergeRecord` (contains `photoUrl`) | A delete it (25 lines, zero callers). **B edit only the two keys out** (keeps your 2026-10-07 "do not delete zero-reference functions" decision; the audit list is a separate cleanup PR). | **B**, for consistency with your own decision. I would delete it in that cleanup PR. |
| **Q-P5-5** | How to test what QML CI cannot reach (fact 6) | **A Node source-guard tests** (`functions/test/`, run in sandbox and CI): token scan on the 5 files (case-SENSITIVE `\bphotoUrl\b|photoUpdatedAt`, comments included; the capital-P module alias `PhotoUrl` is allowed; CRLF/comment variants in a self-test), `XlsxService.cpp` header count == `doc.write` count == `setColumnWidth` count == 14, no "Photo URL" in template; plus QML tests for store behaviour and the pure import helper. B extract the row->record mapping from the dialog into a pure helper (bigger refactor, new risk). C leave S04-S08 device-only. | **A.** Cheap, runnable here, catches the exact regression (a column added/removed in one of the three C++ places). |
| **Q-P5-6** | Branch base / sequencing | PH5 edits `InventoryStore.qml`, same file as open PR #133 (stack #131 -> #132 -> #133, none merged). A implement now on a fresh branch off `main`, rebase after #133 merges (hunks look disjoint: #133 touches `hasProduct`/`listComplete`/`_onMutationConflicted`/`PhotoQueue`; Skill numbers and `SKILLS-INDEX.md` WILL collide and are renumbered on rebase). B wait for #131/#132/#133 to merge. C stack a 4th PR on #133. | **A** if you want PH5 moving while #133 is under test; **B** if you would rather not review a rebase. Not C (4-deep stack, any #131 fix cascades). |

## Design (given the defaults above)
**One slice, one PR** (`feat/2026-10-08-photos-ph5-legacy-removal`): QML + C++ removals must land together (a half state either exports a column the store no longer fills or imports into a dropped field). Order of commits: (1) failing tests (guards, store, helper), (2) store + dialog + page + comments, (3) C++ export/template, (4) import helper + warning, (5) server pin test, (6) docs.
- Store: delete `setPhoto`, `clearLegacyPhotoUrl`; remove the two keys from normalize, `_clone`, default product, `_normalizeRecord`, `_mergeRecord`. `recordPhotoChange` stays (used by `applyPhotoIds`).
- Dialog: remove `photoUrl` property/load/reset and the migration button block; the `photoIds.length === 0` empty-gallery state stays as is.
- Page: card avatar source is `StorageService.photoDownloadUrl(...)` when `photoIds` has an entry, else `""` (placeholder letter badge already handles empty).
- C++: remove header, column 11 write, width 11; shift writes 12-15 -> 11-14 and widths; delete the template row. Update the "Notes" sheet column count check if any. No test infrastructure for C++ exists: CI build (S12) + Node source guard (S06).
- Import: `rec.photoUrl` and the dup-compare field removed; warning helper per Q-P5-2.
- Server: NO production change. One pin test (F42): `applyMutation` with `before` lacking the two keys vs a stored doc having them returns 409 (documents Q-P5-3 and fails loudly if someone later "fixes" it without deciding).

## Known limits (to write into KNOWN-ISSUES at implementation)
Pre-PH5 tenants are not usable after PH5 (Q-P5-3 a). Historical `photo_change` ledger rows that hold URL strings still render (display reads before/after non-emptiness only). Spreadsheet exports from before PH5 contain a "Photo URL" column that import ignores (with the Q-P5-2 warning).

## Not building
Data migration, server-side compat shim (unless Q-P5-3 = d), a column-position-stable export, removal of user-profile `photoUrl`, deletion of `_mergeRecord` (Q-P5-4 B), the 10 audit zero-reference functions.

## Docs to update when implementing
`SKILLS.md` (new Skill: removing a client-side field from a CAS-compared document 409s every stored doc that has it; number assigned at rebase, #133 holds 107-108) + `SKILLS-INDEX.md` regenerate, `AGENTS.md` (file map: import/export columns, store functions removed), `README.md` (product import/export column list, Photo URL mentions), `KNOWN-ISSUES.md` (pre-PH5 tenants), `DELETE-FEATURE-ROADMAP.md` status, `docs/superpowers/test-plans/README.md` index row, test plan section statuses.

## Acceptance
No product `photoUrl`/`photoUpdatedAt` token left in `qml/` or `src/` except (a) user-profile files, (b) `ImportMath.hasLegacyPhotoColumn` and its tests, (c) guard tests that assert absence. Export has 14 product columns with widths aligned. Old 15-column file imports with a warning and no error. Profile photo save/load unchanged (S09). CI green (QML, functions, rules, e2e, C++ build). Pin test F42 present.
