# CHECKPOINT — 2026-09-29: DELETE-FEATURE-ROADMAP next item — options + trade-offs, DECISION PENDING (Taher); docs only

**Session date:** 2026-09-29
**Branch:** `docs/2026-09-29-delete-roadmap-next-item-options`, off `main` @ `88eeb68` (PR #93 merged; PR #84 photos merged; PR #94/#95 merged).
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-28-gateway-write-error-classification-CHECKPOINT.md`
**Skills invoked by Taher:** `superpowers:brainstorming`, `qt-development-skills:qt-qml`, `ponytail:ponytail`, caveman FULL (chat replies only).
**Commit identity:** `Taher (via Claude session) <dextran52@gmail.com>`.

## Standing instructions (unchanged)

Branch only, push without asking, PAT never written to the repo, no build/run, no Qt tooling in sandbox (CI is the QML signal; Node tests run for real), tests toward 100% + test plan + SKILLS/AGENTS/README, honest advisor who grills before deciding, small scope per session.

## Step log

1. Read notes, cloned repo, read `DELETE-FEATURE-ROADMAP.md`, previous checkpoint, options spec.
2. Roadmap state: items 2 and 3 RESOLVED. Item 1: parts A (PR #75) and C (PR #93) merged. **Left: item 1 part B (park + Retry/Discard) and item 4 (photo cleanup on delete).**
3. The photos branch (PR #84) has merged, so item 4 is unblocked. The roadmap said to pull item 4 forward once it landed. Traced item 4 against the new multi-photo code (below).
4. Created branch, archived previous checkpoint, wrote this file. Pushed. **No code changed.**

## Item 4 trace (code read, nothing run)

The roadmap text is stale: it says `deleteProduct()` calls `StorageService.deleteProductPhoto()`. That function no longer exists. Today `InventoryStore.deleteProduct()` (qml/model/InventoryStore.qml ~1088-1115) loops `before.photoIds` and calls `StorageService.removeProductPhoto(productId, photoId, cb)` per id, inside try/catch, then removes a legacy local copy if `photoIds` is empty.

Gaps found by reading, each a candidate real bug, not confirmed on-device:

| # | Gap | Effect | Severity |
|---|---|---|---|
| G1 | `removeProductPhoto` is a single fire-and-forget XHR. Offline, expired token, or transient 5xx -> `console.warn` only. Not in the outbox, no retry. | Storage objects (main + thumb) orphaned forever. Cost leak, not a correctness bug. | Medium |
| G2 | Queued-but-not-yet-uploaded photos for the product are not in `before.photoIds`, so the cascade never discards them. Later they upload, server 404s (product gone), `PhotoQueue` marks the item `failed`. | Invisible failed queue entry plus persisted local file, no UI to reach it. | Low-Medium |
| G3 | Product delete and photo removal race: server tolerates a missing product doc by design, so order is safe. | None. | OK |
| G4 | Server-side `deleteProductPhoto` role check not read this session. | Unknown. | Open |

## The decision (Taher)

- **Option A:** item 4 first. G1+G2 fixes are small, mostly QML plus a Node-testable server check for G4. Gives Taher an on-device check target now.
- **Option B:** item 1 part B (park + Retry/Discard) first, per the 2026-09-28 decisions (Q2 re-pull, Q3 persisted, Q4 tappable caption -> dialog). Largest QML surface, CI-only signal, needs per-store refresh path for Party / Category / OrderChannel / operation sender.
- **Option C:** close item 4 as "verify on-device only", do B.

Honest read: B is the last real data-integrity item and is the bigger risk to leave open; item 4 is a cost leak. But B is large for one free-plan session and a half-built destructive Discard path on a branch is the worst outcome. A is small, finishable, and its G2 fix reuses `PhotoQueue.discard`.

## NEXT SESSION — start here

1. Read Taher's answer to the decision above (in this chat or the PR comments).
2. Do whichever item he chose on a new branch off `main`. Do not start B and item 4 together.

## Not done

- Nothing built or run. No code changes. G4 unread. No on-device confirmation of G1/G2.
