# CHECKPOINT — 2026-10-09 PR #138 final sweep (resume here)

**Branch:** `feat/2026-10-08-photos-ph4-r1-404-body` (PR #138, base `main` @ 38ac768, CI green on aa8c22c: QML 1941, functions 622, e2e 87, rules 45). NOTHING IS DEPLOYED, app not built or run.
**Commit identity:** `lkdwtaher@gmail.com`. PAT only in the push command, never in a file or git config. (The original PR commit aa8c22c was authored as `dextran52@gmail.com`; history is NOT rewritten.)
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-09-pr138-final-sweep-prev-CHECKPOINT.md` (the R1 build checkpoint).
**Decision (Taher, 2026-10-08):** R1 option (b): a 404 discards a queued photo only if the body error is `product-not-found` AND the product is absent from the COMPLETE local list.

## Sweep passes (done)
- [x] 1 ponytail-audit + qt-qml-review (linter on changed QML: only repo-wide `var` style noise) + independent code reviewer + 6-domain QML analysis. Report: `docs/superpowers/specs/2026-10-09-pr138-final-sweep-review.md`
- [x] 2 verified: Node parity 46/46, functions 622/622, CI-script tests 76/76, SKILLS-INDEX current (run in sandbox)

## Fix plan (tick as done)
- [x] F1 failure branch of `PhotoQueue._upload` x3 copies -> ONE `_failUpload(item, uploading, status, responseText)`; tests in `tests/tst_PhotoQueue.qml` (closes the only uncovered new line)
- [x] F2 Node monkeys D5/P6/R1-7 never reached the discard region (low-bit LCG: 0 of 1000 hits; R1-7 never built a string `error`) -> high bits + positive-path counters
- [x] F3 docs: "visible Retry/Discard" claim is false when the row is gone (invisible `failed` item until sign-out): fix wording in test plan, KNOWN-ISSUES, PQL comment; fix R1 device steps so they observe the queue, not tiles
- [x] F4 stale: PQL + tst_PhotoQueueLogic + tst_PhotoQueue header counts (23/23 -> no number), CHECKPOINT counts (608 -> 622), roadmap status line for R1
- [~] F5 push, then poll CI (QML tests are CI-only). Sandbox verified: Node parity 46/46, functions 622/622, CI-script tests 76/76, SKILLS-INDEX current (113 skills); mutation checks fail 5+5 Node tests

## Open items found, NOT fixed here (scope; for Taher)
- O1 invisible `failed` item (misrouted endpoint + product deleted elsewhere) stays until sign-out; option: purge failed items whose row is absent from a complete list (drops R1's second signal, needs your call)
- O2 late 2xx after `PhotoQueue.clear()` (sign-out) emits `photoUploaded` under the next account; `applyPhotoIds` matches by productId only (needs an in-flight upload + sign-out + same productId)
- O3 on timeout Qt may fire both `onreadystatechange` (DONE, status 0) and `ontimeout`: breaker counted twice (unverified, device check)
- O4 body may not survive the QTBUG-49896 snapshot (fail-safe: no discard); `console.warn` added in F1 shows it on device

## NEXT
After F5: Taher reads CI on #138, squash-merges when green.
