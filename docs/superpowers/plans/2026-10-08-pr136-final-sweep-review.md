# PR #136 (PH5 legacy product photoUrl removal) final-sweep review, 2026-10-08

Skills used: superpowers:requesting-code-review, ponytail:ponytail-audit, qt-development-skills:qt-qml-review. Stacked on #136 (branch `review/2026-10-08-pr136-final-sweep`). Load assumed: one owner, dev tenants, a handful of imports/exports.

**Verdict: With fixes.** The removal itself is complete and correct. One decision (R1) must be re-made because its premise was false; one adjacent bug (R2) is fixed here.

## Strengths
- grep of `qml/ src/ functions/ rules`: no product `photoUrl` token left; only user-profile `photoUrl` (AuthStore/AuthService/ProfilePage/`provisionMember`) remains, as designed.
- `_clone`, `_newProductDoc`, normalize, `_mergeRecord` all lost the two keys together; C++ header/writes/widths/template are 14/14/14/14 and consistent (read line by line).
- Guards G01-G11 have a self-test; F42/F42b pin the CAS consequence; Skill 107 + KNOWN-ISSUES written. Reproduced locally: functions suite 599/599. CI on `f479cbe`: 5/5 green. `SKILLS-INDEX.md` in sync (`skills-index.js --write` = no diff).
- qml-review Phase 1 linter: 0 findings on added lines (PR adds one ternary and one empty function; everything else is deletion). Pre-existing `var`/`==` hits are untouched code.

## R1 MUST DECIDE: import is positional, so Q-P5-2 "silent ignore" is silent column shift
- Where: `src/XlsxService.cpp` `readSheet` (reads column N, labels it `kProductHeaders[N-1]`, never reads the header row); design Fact 1 said "keyed by header text" (false, corrected in the spec).
- Case: a pre-PH5 export or downloaded template has Photo URL in col 11. Imported by this build: URL text becomes Supplier, Supplier becomes Size, Size becomes Taxable, Taxable becomes Tax %, old Tax % dropped. The dialog resolves Supplier by name, so a URL can become a bogus supplier + opening batch.
- Not caused by a bug in the diff; caused by Q-P5-1/Q-P5-2 being decided on a wrong fact. Taher's "dev only, fresh files" reasoning may still hold, but it must be chosen knowingly.
- Options: A accept (0 code; stale file = corrupt import). B header-row check in `readSheet`: if row 1 differs from the expected headers, return empty so the dialog says "file does not match the template" (~10 C++ lines; also protects orders/staff sheets that share `readSheet`). C read by header text (tolerant of old files; more C++). D only document it in KNOWN-ISSUES.
- Review recommendation: B. Cost: C++ with no CI compile job (R3), so it is compile-checked only on Taher's device build.

## R2 FIXED here: imported products 409 on first edit/delete (pre-existing, same class as Skill 107)
- `_normalizeRecord` (bulk import) omitted `photoIds`; `_clone()` always emits it; server stores `after` as-is and `_deepEqual` compares key counts. So an imported product has 14 keys in Firestore and a 15-key `before` on its next edit. Base `pr135` had the same gap (0 `photoIds` in `_normalizeRecord`). `tst_InventoryStore_cloneSymmetry` only covered `_newProductDoc`, and the `_newProductDoc` comment said "check by hand".
- Fix: `photoIds: []` in `_normalizeRecord` + 2 tests (key sets equal `_newProductDoc`; clone of imported doc matches). Confidence: high from code reading; not run (QML runs in CI only). Device check below confirms.

## R3 SHOULD FIX (docs): PR body claims a "C++ build" CI check
`checks.yml` has no C++ compile job (jobs: QML, functions, rules, e2e, comment). `XlsxService.cpp` is compiled by nobody until Taher builds. The edit is small and read correctly, so risk is low, but the acceptance line "CI green (... C++ build)" is untrue. Fix the PR text; compile at device-test time.

## R4 MINOR
- Spec Acceptance still named `hasLegacyPhotoColumn` and "imports with a warning" (dropped by Q-P5-2 = A). Fixed here.
- G10 uses `||` so it passes if either ProfilePage check passes; G04 scans only the `photoUrl` token, not a `"Photo URL"` string. Not worth code.
- `EditProductDialog.clearPhotoSource() { }` is an empty function. Keep: `Main.qml` calls it on the shared sheet contract and `AddProductDialog` implements it. Not dead.

## Accepted risk restated (Taher decided, not re-opened)
Pre-PH5 tenants 409 on every edit/delete (Q-P5-3 a). R2 shows imported products hit the same wall even on a fresh tenant, which is why R2 matters more than "fresh tenant" suggests.

## Not checked
README/KNOWN-ISSUES full text beyond the PH5 sections; EditProductDialog beyond the diff; qml-review's six parallel agents (no subagent tool here, so the six domains were checked by hand on the 2 added QML lines: nothing in layout/loader/delegate/state); app not built or run (house rule).

## Test plan for the R2 fix
Already covered: Unit (QML, CI): new `test_normalizeRecord_keys_exactly_match_newProductDoc_keys`, `test_imported_doc_clone_key_count_matches_stored_doc`; existing S13/S14, cloneSymmetry. Server: F42/F42b. E2E: none for import (gap, see R1/R2 follow-up).
On-device:
- Happy path: import 1 new row, open it, change Min Stock, save: saves, no "restored with the latest version" toast. Delete it: gone.
- Negative: import file with a stray 15th column: no crash.
- Edge: import 2 rows (one overwrite, one new); edit the new one twice in a row.
- Affected areas: import preview, product edit/delete, export 14 columns.
- Regression: product added by hand still edits/deletes; photo upload on an imported product keeps photoIds.
