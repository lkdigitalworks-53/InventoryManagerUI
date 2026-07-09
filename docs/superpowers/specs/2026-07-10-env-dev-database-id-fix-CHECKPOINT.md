# Checkpoint — Feature 5 (env) audit + dev-database-id fix

**Date:** 2026-07-10
**Branch:** `fix/env-dev-database-id-mismatch` (off `main`)
**Status:** Code changes complete locally, committed locally. NOT pushed. NOT reviewed by Taher yet.

## Context

Taher asked to "complete the implementation" of Feature 5 (dev/test/prd Firestore
environments) from `docs/superpowers/specs/2026-06-26-five-features-design.md`, now that
the Blaze plan is active. Audit of `main` found the **entire coding scope of Feature 5 was
already implemented and merged** (EnvConfig.js + tests, CMake/main.cpp PRODUCT_STAGE→APP_STAGE
wiring, FirebaseService.qml databaseId/databaseUrl routing, Constants.qml cleanup, env badge
in ProfileSettingsDialog.qml, README/AGENTS.md/SKILLS.md docs, and — beyond the original
spec's scope — Cloud Functions `scopedDb(env)` across all 4 functions + `Gateway.qml` env
injection, done during the later `2026-07-06-scale-reads-writes-analytics` phase).

Taher confirmed the actual remaining gap is **provisioning the real `dev`/`test` Firestore
databases** (infra, not code) — something this sandboxed environment cannot execute
(no GCP/Firebase network access).

## Bugs found during the audit (this is what got fixed)

1. **Real bug:** README's own runbook says to create a database named `dev1` (since
   Firestore requires ≥4-char database ids and `dev` is only 3), but the code
   (`EnvConfig.js`, `functions/index.js`) still mapped the `dev` **env** to database id
   `"dev"`, not `"dev1"`. A `PRODUCT_STAGE "dev"` build would have 404'd against a
   nonexistent database the moment `dev1` was created per the README's own instructions.
2. **Doc error:** README claimed new databases "must match `(default)`'s region." Verified
   against current Firestore docs — this is false; non-default databases can be created in
   any supported region independent of `(default)`. Also flagged (not resolved — needs
   Taher to check `gcloud firestore databases list`): `AGENTS.md`/the compliance spec say
   `(default)` is in `asia-southeast1`, but the README said `asia-south1` — these disagree.

## Changes made (this branch, committed locally)

- `qml/helper/EnvConfig.js` — `databaseIdForEnv("dev")` now returns `"dev1"`.
- `tests/tst_EnvConfig.qml` — updated 2 assertions expecting `"dev"` → `"dev1"`.
- `functions/index.js` — `DATABASE_ID_FOR_ENV.dev` → `"dev1"`.
- `SKILLS.md` — Skill 30 mapping table/resolution-chain example + Skill 33's
  `DATABASE_ID_FOR_ENV` code example, both corrected to `dev1`.
- `README.md` — Environments section: removed the false "region must match `(default)`"
  claim, recommend `asia-southeast1` (colocates with the already-deployed Cloud Functions),
  flagged the `(default)` region discrepancy for Taher to verify himself, updated the
  `firebase firestore:databases:create` commands to use `asia-southeast1`.

Verified: `node --check` on both edited `.js` files passes; manually ran the (stripped)
`EnvConfig.js` logic in Node — `dev→dev1`, `test→test`, `publish→prd/(default)`,
empty/unknown→`prd/(default)` all confirmed correct.

**Not run:** `qmltestrunner` (no Qt/Felgo toolchain in this sandbox) — Taher should re-run
`tests/tst_EnvConfig.qml` locally before merging.

## Not yet done / next steps

1. Taher reviews the diff (explicitly deferred — he said he'd check after full
   implementation, not per-file).
2. On confirmation, commit is already in place locally — just needs Taher's go-ahead to
   push (needs a PAT with push access, not yet provided this session).
3. **Still outstanding, infra not code** (this is the actual "gap" Taher confirmed):
   - Run `gcloud firestore databases list --project=inventorymanager-48392` to confirm the
     real `(default)` region (resolves the asia-south1 vs asia-southeast1 discrepancy).
   - `firebase firestore:databases:create test --location=asia-southeast1`
   - `firebase firestore:databases:create dev1 --location=asia-southeast1`
   - Apply `FIRESTORE_RULES.md` to both new databases.
   - End-to-end verify: build with `PRODUCT_STAGE "dev"`, confirm writes land in `dev1` and
     not `(default)`; same for `"test"`. (Per Taher's standing instruction: do not build/run
     until he explicitly asks.)
