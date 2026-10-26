# Firestore Rules For Tenant RBAC

What the Firestore security rules enforce for tenant RBAC, and the rules for editing them.

> **Source of truth:** `firestore.rules` at the repo root (wired via `firebase.json`). This file does
> NOT carry a copy of the rules any more: the old code block drifted from the real file in two
> consecutive PRs and showed an unsafe wildcard, so it was removed (2026-10-25, PR #161). Read the
> real file; this page explains what it enforces. Deploy with `firebase deploy --only firestore:rules`.

## Goals

- Tenant data isolation
- Only signed-in users can access data
- Owners/admins can manage members
- Owner record cannot be modified/removed by others
- Admin cannot promote to owner
- **Ledger tier is immutable (P0):** `audit_log`, `transactions`, `stock_batches`,
  `stock_movements` are **read-only to all clients** — only the compliance gateway
  Cloud Function (Admin SDK) writes them. This is what satisfies MCA Rule 11(g).
- **`inventory` is gateway-write-only (P1 S2c):** members can read products, but every create,
  update and delete goes through the gateway Cloud Functions so the ledger rows are always written.
- **Default deny for writes (S2f-4/5):** the wildcard only lets an active member write the four names on
  the client-writable allow-list; `orders`, `staff`, `suppliers`, `removed_staff` and every unknown name
  are gateway-only.

## What `firestore.rules` enforces

"Member" means an **active** member: the member doc exists and `status == 'active'`. A suspended
member is refused everywhere except reading their own member doc (so the app can say why).

| Path under `tenants/{tenantId}` | Read | Write |
|---|---|---|
| `tenants/{tenantId}` (the doc) | active member | create: signed-in user who is the `ownerId`; update, delete: owner |
| `members/{uid}` | own doc always; roster for active members | create: `canAssignRole` (owner assigns admin/manager/staff, admin assigns manager/staff, nobody assigns owner) or the one-time owner bootstrap; update: same role check, existing owner doc never modified; delete: owner/admin (not the owner doc, not self) or voluntary leave (non-owner) |
| `audit_log`, `transactions`, `stock_batches`, `stock_movements` (ledger) | active member | nobody (gateway Cloud Functions only, Admin SDK) |
| `locks`, `pending_cleanup` (server-only) | nobody | nobody |
| `activity_log`, `config`, `counters`, `_migrations` (client-writable allow-list) | active member | active member |
| everything else, e.g. `inventory`, `orders`, `staff`, `removed_staff`, `suppliers`, and any name not yet invented | active member (except the server-only names) | **nobody**: default deny, gateway Cloud Functions only |
| sub-collections below any of the above | nobody | nobody |
| `users/{uid}` (top level) | that user | that user (create, update); never delete |

Rules to keep when editing `firestore.rules`:

- Firestore grants a request if ANY matching rule allows it. An explicit `match` block next to the
  wildcard never *removes* access. Deny by keeping a name **off** the client-writable allow-list
  (`isClientWritableCollection`), not by adding a deny block.
- Adding a name to that allow-list is a security decision: it needs a test in
  `test/firestore.rules.test.js` and a line in `docs/superpowers/specs/2026-10-24-s2f-authz-hardening-design.md`.
- `counters` is on the allow-list because the client mints ids. Any active member can write any value
  to it. This is a known, pinned limit (test "PIN S2f-6"), to be removed with server-side minting.
- Open item: an owner can change `ownerId` on the tenant doc (see `docs/superpowers/KNOWN-ISSUES.md`,
  "Owner can mint a second owner").
- The gateway (`functions/index.js` `deriveContext`) applies the same active-member rule. The two must
  not drift (Skills 127, 128).

Tests: `test/firestore.rules.test.js` and `test/storage.rules.test.js` (see `README.md`, "Testing").

## Temporary Testing Rules (Permissive / Unrestricted)

While debugging, use these permissive rules to ensure membership writes work, then deploy the real `firestore.rules`:

```rules
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    function isSignedIn() {
      return request.auth != null;
    }

    // Temporary: Allow authenticated users full access for testing
    match /{document=**} {
      allow read, write: if isSignedIn();
    }
  }
}
```

This allows any signed-in user to read/write anything. **Use this only for development/testing.**

## Deploy

```bash
firebase deploy --only firestore:rules
```

If you keep rules in a custom file path, reference it in `firebase.json` first.

## Troubleshooting

**If tenant/user docs are created but membership write fails with 403:**

1. Check Firebase Console → Firestore → Rules: Are any rules deployed?
   - If not, deploy the temporary permissive rules above first
   - Then test the flow again

2. Check Firebase Console → Authentication: Confirm your user is signed in (should see UID in Users list)

3. Check browser/app console logs for `[Firestore]` messages showing the exact error response

4. Once membership write succeeds, deploy the real `firestore.rules` and run `test/firestore.rules.test.js` against the emulator
