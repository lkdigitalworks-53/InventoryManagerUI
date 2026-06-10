# Firestore Rules For Tenant RBAC

Use these rules to enforce the same member-management constraints that the app now applies client-side.

> **Deployable copy:** the canonical, deploy-ready rules now live in `firestore.rules`
> at the repo root (wired via the root `firebase.json`). The blocks below are the
> explanatory reference; keep the two in sync. Deploy with `firebase deploy --only firestore:rules`.

## Goals

- Tenant data isolation
- Only signed-in users can access data
- Owners/admins can manage members
- Owner record cannot be modified/removed by others
- Admin cannot promote to owner
- **Ledger tier is immutable (P0):** `audit_log`, `transactions`, `stock_batches`,
  `stock_movements` are **read-only to all clients** — only the compliance gateway
  Cloud Function (Admin SDK) writes them. This is what satisfies MCA Rule 11(g).

## Example Rules

```rules
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    function isSignedIn() {
      return request.auth != null;
    }

    function memberDoc(tenantId, uid) {
      return get(/databases/$(database)/documents/tenants/$(tenantId)/members/$(uid));
    }

    function myMember(tenantId) {
      return memberDoc(tenantId, request.auth.uid);
    }

    function myRole(tenantId) {
      return myMember(tenantId).data.role;
    }

    function isOwner(tenantId) {
      return isSignedIn() && myRole(tenantId) == 'owner';
    }

    function isAdmin(tenantId) {
      return isSignedIn() && myRole(tenantId) == 'admin';
    }

    function isOwnerOrAdmin(tenantId) {
      return isOwner(tenantId) || isAdmin(tenantId);
    }

    function isMember(tenantId) {
      return isSignedIn() && exists(/databases/$(database)/documents/tenants/$(tenantId)/members/$(request.auth.uid));
    }

    function roleIsValid(role) {
      return role in ['owner', 'admin', 'manager', 'staff'];
    }

    function statusIsValid(status) {
      return status in ['active', 'suspended'];
    }

    // users/{uid}
    match /users/{uid} {
      allow read: if isSignedIn() && request.auth.uid == uid;
      allow create, update: if isSignedIn() && request.auth.uid == uid;
      allow delete: if false;
    }

    // tenants/{tenantId}
    match /tenants/{tenantId} {
      allow read: if isMember(tenantId);

      // One-time tenant creation by authenticated owner account.
      allow create: if isSignedIn()
                    && request.resource.data.ownerId == request.auth.uid
                    && request.resource.data.name is string;

      allow update: if isOwner(tenantId);
      allow delete: if isOwner(tenantId);

      // tenants/{tenantId}/members/{uid}
      match /members/{uid} {
        allow read: if isMember(tenantId);

        // Create member records only by owner/admin.
        allow create: if isOwnerOrAdmin(tenantId)
                      && roleIsValid(request.resource.data.role)
                      && statusIsValid(request.resource.data.status)
                      && request.resource.data.uid == uid;

        // BOOTSTRAP: Allow owner to create their own membership during tenant setup
        // (when no member records exist yet for this tenant).
        allow create: if isSignedIn()
                      && request.auth.uid == uid
                      && request.resource.data.role == 'owner'
                      && request.resource.data.status == 'active'
                      && exists(/databases/$(database)/documents/tenants/$(tenantId))
                      && get(/databases/$(database)/documents/tenants/$(tenantId)).data.ownerId == request.auth.uid
                      && !exists(/databases/$(database)/documents/tenants/$(tenantId)/members/$(uid));

        // Update member records with role restrictions.
        allow update: if isOwnerOrAdmin(tenantId)
                      && roleIsValid(request.resource.data.role)
                      && statusIsValid(request.resource.data.status)
                      // Cannot change owner row.
                      && resource.data.role != 'owner'
                      // Admin cannot assign owner/admin.
                      && (
                        isOwner(tenantId)
                        || (isAdmin(tenantId)
                            && request.resource.data.role in ['manager', 'staff'])
                      );

        // Owner/admin can remove non-owner records, cannot self-remove.
        allow delete: if isOwnerOrAdmin(tenantId)
                      && resource.data.role != 'owner'
                      && uid != request.auth.uid;
      }

      // Ledger tier (P0): immutable, written only by the gateway Cloud
      // Function (Admin SDK bypasses rules). Clients may read, never write.
      match /audit_log/{docId}       { allow read: if isMember(tenantId); allow write: if false; }
      match /transactions/{docId}    { allow read: if isMember(tenantId); allow write: if false; }
      match /stock_batches/{docId}   { allow read: if isMember(tenantId); allow write: if false; }
      match /stock_movements/{docId} { allow read: if isMember(tenantId); allow write: if false; }

      // Working-tier domain collections (orders, inventory, sales, staff, ...).
      // The ledger guard stops a ledger collection from ever matching this
      // writable fallback (Firestore grants access if ANY match allows).
      function isLedgerCollection(name) {
        return name in ['audit_log', 'transactions', 'stock_batches', 'stock_movements'];
      }
      match /{collection}/{docId} {
        allow read: if isMember(tenantId);
        allow create, update, delete: if isMember(tenantId)
                                      && !isLedgerCollection(collection);
      }
    }
  }
}
```

## Temporary Testing Rules (Permissive / Unrestricted)

While debugging, use these permissive rules to ensure membership writes work, then tighten them:

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

4. Once membership write succeeds, deploy the strict rules above incrementally and test after each rule type
