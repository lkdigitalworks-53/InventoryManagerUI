# India Compliance Roadmap — Master Design

**Date:** 2026-06-06
**Status:** Approved (design); sub-projects pending individual specs
**Project:** BusinessManagement App_UI (Felgo QML, Android/iOS) — standalone B2B inventory, stock & sales reporting

---

## 1. Purpose & Context

The app is a standalone B2B inventory / stock-maintenance / sales-reporting tool for Indian
retailers and wholesalers. It deliberately excludes billing/invoice generation. Legal research
(see `## Source Research`) establishes that **excluding billing does not exempt the app from
Indian tax, corporate, and data-privacy law** — because any software holding data that feeds a
registered business's books of account is itself part of those "books of account" / "electronic
records."

This document is the **master roadmap**: it decomposes compliance into independently-buildable
sub-projects, orders them by legal-risk × effort, and fixes the one architectural decision every
tax feature depends on. Each sub-project (P0–P7) gets its own spec → plan → implementation cycle.

### Scoping decisions (locked with stakeholder)

| Decision | Value | Consequence |
|---|---|---|
| Target customer | **Mixed — sell to all segments** | Build to the *strictest common denominator*. MCA-grade immutable logging is **P0**. |
| Backend capability | **Add Firebase Cloud Functions** (gateway) | Enables real DB-layer immutability, server identity/time, Auth-account cascade, scheduled jobs. |
| Sequencing | **Foundation-first** | Build gateway + immutable log first; layer features on top; fold cheap client-only wins in opportunistically. |
| Manufacturing / BoM (CGST 56(12)) | **Deferred / optional** | Build only if manufacturer customers are actively targeted. |
| Digital Signature (CGST 56(15)) | **Deferred** | Revisit after foundation. |
| Developer's own OIDAR/GST/TDS | **Out of app scope** | Business-ops task, not an app feature. |

---

## 2. The Architectural Spine (foundation for everything)

**Decision: introduce a Firebase Cloud Functions "compliance gateway" and split every collection
into two tiers.**

### Two-tier data model

- **Ledger tier (immutable, server-owned):** `audit_log` (new), `transactions`, `stock_batches`,
  `stock_movements` (new), and mutation snapshots of `orders`/`inventory`/`staff`/`suppliers`.
  Firestore rules make these **read-only to clients**. The *only* writer is a Cloud Function using
  the Admin SDK. **Append-only — no update, no delete, ever.**
- **Working tier (client-writable, as today):** the live `inventory`, `orders`, `staff`,
  `suppliers` documents the UI reads and edits. Every mutation here calls the gateway, which writes
  the working-tier doc **and** appends a ledger entry in one transaction.

### Why this is non-negotiable

The current app is **client-direct Firestore REST** (device → Firestore with the user's token).
That architecture structurally cannot satisfy the strict mandates:

- `FIRESTORE_RULES.md` grants `create, update, delete` to *any* tenant member — the audit trail is
  editable, exactly what MCA Rule 11(g) auditors test against.
- No trusted party stamps a verified actor identity or NTP server time — the client supplies both,
  so they are forgeable.
- PII erasure can't reach Firebase **Auth accounts** or **backups** from the client (see the
  existing `// TODO: Cloud Function` in `AuthService.cleanupStaffAuthDocs`).

Without a trusted server the log is forgeable, and a corporate buyer's statutory auditor fails it
under Rule 11(g). Client-only compliance is compliance-theater. The gateway is the **minimum**
that unlocks genuine compliance; everything that is pure UI/schema/content can still ship without
it.

### Relationship to existing code

`TransactionStore` and `StockBatchStore` already record per-doc events with timestamps and
before/after values — a strong foundation. Under this design they become **read models** over the
ledger tier rather than the writers. Their document shapes are largely preserved.

---

## 3. Prioritized Sub-Project Roadmap

Ordered by legal-risk × effort. Effort: S ≈ days, M ≈ 1–2 weeks, L ≈ 3+ weeks.

| # | Sub-project | Mandate | Gateway? | Effort | Rationale |
|---|---|---|---|---|---|
| **P0** | **Compliance gateway + immutable `audit_log`** | MCA 11(g), CGST 56(8) | ✅ builds it | L | Everything tax-related writes through this. The foundation. |
| **P1** | **Stock-movement taxonomy** — loss/theft/destroyed/write-off/free-sample/gift + opening/closing balance ledger view | CGST 56(2) | ✅ appends | M | Highest-value tax feature; trivial once the gateway exists. |
| **P2** | **Tax-identity fields** — HSN (4/6/8-digit) on products; GSTIN on supplier/customer/tenant | GST / HSN rules | ❌ client-only | S | Cheap, parallelizable — start immediately alongside P0. |
| **P3** | **Legal docs & acceptance** — ToS, Privacy Policy, DPA; versioned accept-record | ToS risk-allocation, DPDP DPA | ⚠️ accept-log via gateway | S–M | Mostly content + acceptance UI; low engineering risk. |
| **P4** | **DPDP privacy core** — consent capture/logs, privacy notice at data entry, grievance channel, 18+ gate, data-residency decision record | DPDP §1,2,6,7,9 | ✅ consent logs | M | Enforcement deadline May 2027; consent logs are sensitive. |
| **P5** | **PII erasure & retention** — terminated-staff deletion, Auth-account cascade, backup-aware delete, 6/8-yr archival | DPDP §4, IT 44AA / Rule 6F | ✅ scheduled fns | M–L | Needs server jobs; closes the `cleanupStaffAuthDocs` TODO. |
| **P6** | **Breach detection & 72h notification** | DPDP §5 | ✅ server monitor | M | Depends on `audit_log` (P0). |
| **P7** | **Warehouse / storage mapping** — address, license no., item↔location link, goods-in-transit | CGST 56(5) | ❌ mostly client | M | Real but lower auditor-blocking risk for the mixed segment. |
| **D** | **Deferred** — Manufacturing/BoM 56(12), Digital Signature 56(15), developer OIDAR/GST/TDS ops | — | — | — | Out of scope per scoping decisions / not app features. |

---

## 4. Low-Level Design — Foundation (P0/P1/P2)

### 4.1 `audit_log/{entryId}` — append-only, server-written

```
{
  entryId,                                  // server-generated
  tenantId,
  actorUid, actorRole,                      // identity attribution (FK → users); derived server-side
  action: "create" | "update" | "delete",
  entity: "inventory" | "order" | "staff" | "supplier"
        | "stock_movement" | "consent" | "tos_accept",
  entityId,
  before: {…} | null,                       // full V(n-1) snapshot
  after:  {…} | null,                       // full V(n)   snapshot
  serverTimestamp,                          // NTP-backed; set by Cloud Function (authoritative)
  clientTimestamp,                          // client value kept for forensic comparison
  requestId                                 // idempotency / dedupe
}
```

### 4.2 Gateway contract

One callable Cloud Function:

```
recordMutation(entity, entityId, action, before, after) -> { ok, entryId }
```

- Verifies the caller's Firebase Auth ID token → derives `actorUid` / `actorRole` **server-side**
  (client cannot forge).
- Stamps `serverTimestamp`.
- Writes the working-tier document **and** the `audit_log` entry inside a single Firestore
  transaction (atomic — never one without the other).

Firestore rules for ledger collections:

```
match /tenants/{tenantId}/audit_log/{id}     { allow read: if isMember(tenantId); allow write: if false; }
match /tenants/{tenantId}/transactions/{id}  { allow read: if isMember(tenantId); allow write: if false; }
match /tenants/{tenantId}/stock_batches/{id} { allow read: if isMember(tenantId); allow write: if false; }
match /tenants/{tenantId}/stock_movements/{id}{ allow read: if isMember(tenantId); allow write: if false; }
```

Only the Admin SDK (inside the Cloud Function) bypasses rules → immutability is enforced at the DB
layer, satisfying MCA's "tamper-proof / cannot be disabled / operates continuously" tests.

### 4.3 Movement taxonomy (P1) — `stock_movements/{id}`

Immutable ledger; `kind` enum:

```
receipt | sale | loss | theft | destroyed | write_off | free_sample | gift | adjustment
```

Each row: `{ id, productId, kind, qty, reason, valueAtCost, batchRef?, serverTimestamp, actorUid }`.
A derived read model produces the **opening balance / receipts / supplies / closing balance**
register required by CGST 56(2).

### 4.4 Tax-identity fields (P2)

- Product gains `hsnCode: string` — validated as 4, 6, or 8 digits (variable-length, per turnover
  tier). Empty allowed for sub-₹1.5cr merchants.
- Supplier, order-customer, and tenant profile gain `gstin: string` — 15-char GSTIN with checksum
  validation.

### 4.5 Required change to existing code

`TransactionStore.renameParty()` currently **mutates past entries** (`TransactionStore.qml` ~line
197), which is illegal under append-only. **Resolution (confirmed in P0): remove it — it is dead
code with zero callers.** The live supplier-rename feature (`EditProductDialog`) goes through
`SupplierStore.updateSupplier`, which propagates by stable `supplierId` and never touches
historical rows. No user-facing feature is lost.

---

## 5. Data Residency Note (DPDP §7)

Firestore region is **`asia-southeast1` (Singapore)** — outside India. Allowed by default under the
DPDP Act today (transfers permitted except to government-restricted countries). Recorded here as a
**documented decision**; if the government later restricts, an India-region migration is required.
Tracked formally in P4.

---

## 6. Out of Scope / Deferred

- **Manufacturing / BoM (CGST 56(12))** — most retailers/wholesalers don't manufacture; build only
  if manufacturer customers are targeted.
- **Digital Signature / DSC (CGST 56(15))** — revisit after the foundation lands.
- **Developer's own OIDAR / GST registration / TDS / SaaS invoicing** — the developer's business-ops
  obligations, not features of this app.

---

## 7. Next Steps

1. This master roadmap is approved.
2. Each sub-project P0–P7 is brainstormed and specced individually, in priority order, starting
   with **P0 (gateway + immutable audit_log)** and **P2 (tax-identity fields, client-only, parallel)**.
3. `AGENTS.md` and `SKILLS.md` are updated to carry this architecture as ready context (done
   alongside this spec).

---

## Source Research

The legal research that drove this design (CGST Rule 56, MCA Rule 3(1)/11(g), Income Tax §44AA /
Rule 6F, DPDP Act 2025 rules, OIDAR taxation, ToS risk allocation) is retained in the project
brainstorming record. Key statutory anchors:

- **Companies Act 2013 §2(13)** — inventories are part of "books of account."
- **Companies (Accounts) Rules 2014, proviso to Rule 3(1)** — un-disablable edit log (eff. 2023-04-01).
- **Companies (Audit & Auditors) Rules 2014, Rule 11(g)** — auditor must verify audit-trail integrity.
- **CGST Rules 2017, Rule 56** — electronic stock register; 56(2) movements, 56(5) storage, 56(8)
  edit logs, 56(12) manufacturing, 56(15) digital signature.
- **Income Tax Act §44AA + Rule 6F** — books of account; 6-year retention; §271A penalty.
- **DPDP Act + 2025 Rules** — consent, notice, DPA, erasure, breach (72h), children's data,
  cross-border, grievance (30 days). Consent Manager live 2026-11-13; full compliance 2027-05-13.
