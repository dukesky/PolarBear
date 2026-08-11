# PolarBear Multi-Tenant Foundation — Design Spec

**Date**: 2026-08-11
**Sub-project**: B — Multi-Tenant + Persistence (thin version)
**Status**: Approved by user (brainstorming session 2026-08-11)

## Context & Motivation

PolarBear today is a single-tenant demo: `index_name = "products"` is hardcoded
globally, so every upload writes into one shared index and every visitor
searches the same data. There is no authentication and no API key. Index files
(`faiss_index.bin`, `doc_map.pkl`) and the analytics DB (`analytics.db`) live on
the Cloud Run container's local disk — they are lost on restart and diverge
across instances.

The product direction is **open-core**: this repo stays fully open source and
self-deployable, while we also operate a hosted instance where SMEs register,
upload their catalog, and (in sub-project C) embed a search widget on their own
website. Multi-tenancy with durable storage is the hard prerequisite for that
hosted model — without it, two merchants installing the widget would search each
other's products.

**Roadmap agreed**: B (this spec, thin) → C (embeddable JS widget + no-code
onboarding) → A (search quality: RRF fusion, reranker, better embedding model,
eval set). C gets its own spec after B lands.

## Goals

- One registered account = one tenant (one business). All data isolated by `tenant_id`.
- Email+password and Google OAuth login for the admin dashboard.
- Two API keys per tenant (public search key + private admin key), enabling a
  future widget to embed the search key safely in public HTML.
- Index and image persistence that survives Cloud Run restarts (GCS on hosted,
  local filesystem on self-hosted — same abstraction).
- Automated proof that tenant A cannot see tenant B's data.

## Non-Goals (YAGNI — explicitly deferred)

- Billing / plans / quotas
- Email verification and password reset (post-MVP)
- Multiple team members per tenant
- Shopify/WooCommerce auto-sync
- The embeddable widget itself (sub-project C)
- Search-quality work (sub-project A)

## 1. Tenant Model & Architecture

```
Merchant registers → tenant_id + two API keys
  ├── Meilisearch: one index per tenant  → products_{tenant_id}
  ├── FAISS:       one file set per tenant → {storage}/tenants/{tenant_id}/faiss.bin + doc_map.pkl
  ├── Images:      {storage}/tenants/{tenant_id}/images/
  └── Analytics:   all tables gain a tenant_id column
```

**Database moves from SQLite to Postgres via SQLAlchemy.**

- Stores: users, tenants, API keys, search logs, product stats.
- Self-hosted: a Postgres container added to `infrastructure/docker-compose.yml`
  (zero manual config). Local dev may use SQLite; SQLAlchemy abstracts the
  difference.
- Hosted: Cloud SQL or Neon (free tier acceptable for MVP).

Schema (core tables):

- `users` — id, email, hashed_password, oauth fields (managed by fastapi-users)
- `tenants` — id, name, owner_user_id (1:1 with users for MVP)
- `api_keys` — id, tenant_id, key_hash, kind (`search` | `admin`), created_at
- `search_logs`, `product_stats` — existing columns + `tenant_id`

## 2. Authentication & API Keys

**Dashboard auth** — `fastapi-users` library:

1. Step 1: email + password registration/login, JWT sessions.
2. Step 2 (same spec, second increment): Google OAuth via fastapi-users' native
   OAuth support. Self-hosted deployments without Google credentials simply
   don't show the Google button (feature-flagged by env var presence).

All admin operations (upload, product edit, analytics) require a valid JWT and
operate on the caller's own tenant.

**Two API keys per tenant** (Algolia/Meilisearch model):

- `pb_search_...` — **public search key**. Search endpoint only, read-only.
  Safe to appear in public page source (required by sub-project C).
- `pb_admin_...` — **admin key**. Ingestion and product management. Shown only
  in the dashboard; never embedded in public pages.

Keys are random 32-byte tokens, stored hashed (SHA-256) in `api_keys`; the
plaintext is shown at creation/reset time. Either key can be reset from the
dashboard.

## 3. Index Isolation & Persistence

**Meilisearch**: replace the hardcoded `"products"` index with
`products_{tenant_id}` throughout `HybridIndexer` and `HybridSearcher`. The
Meilisearch instance itself (GCE VM with persistent disk) is unchanged.

**FAISS + doc_map**: introduce a storage abstraction:

```python
class IndexStorage(Protocol):
    def read(self, tenant_id: str, name: str) -> bytes | None: ...
    def write(self, tenant_id: str, name: str, data: bytes) -> None: ...
```

- `LocalStorage` — files under a configurable data dir (self-hosted default).
- `GCSStorage` — `gs://<bucket>/tenants/{tenant_id}/...` (hosted; selected by
  env var, e.g. `INDEX_STORAGE=gcs` + `GCS_BUCKET=...`).

Searcher loads a tenant's FAISS index lazily on first search and **caches it in
memory** (keyed by tenant_id, invalidated when the indexer rewrites it). This
also fixes the current bug where every search re-reads the index from disk.

**Images**: uploaded product images move from container-local
`app/static/images` to the same storage abstraction. Hosted: served from GCS
public URLs; self-hosted: served as static files, as today.

**Repo hygiene**: delete `backend/faiss_index.bin`, `backend/doc_map.pkl`,
`backend/analytics.db` from git; add patterns to `.gitignore`.

## 4. API & Frontend Changes

**Backend routes**:

| Route | Auth | Change |
|---|---|---|
| `/auth/*` | — | New. Register/login/JWT/OAuth (fastapi-users). |
| `/tenant/keys` | JWT | New. View + reset the two API keys. |
| `/search` | `pb_search_` key **or** JWT | Key (header `X-PolarBear-Key` or `?key=`) resolves the tenant — no login needed, so public merchant pages can call it. A dashboard JWT also works (used by the admin's own search-test page). |
| `/ingest`, `/products`, `/analytics` | JWT | Scoped automatically to the caller's tenant. |

**Frontend** (Next.js 16 + Tailwind 4):

- New login/register page; Navbar shows the signed-in account with a sign-out
  action. Unauthenticated visitors to admin pages are redirected to login.
- Existing upload / insights / search pages keep their layout; requests carry
  the JWT and data is automatically tenant-scoped.
- New **Settings** page showing the two API keys with copy buttons and reset
  actions. (In sub-project C this page grows into "copy this snippet into your
  site".)

**UI style requirement** (user-specified): keep pages clean and minimal,
consistent with the existing PolarBear look — white/light background, gray
borders, indigo (`indigo-600`) accent, Tailwind utility styling, no new UI
libraries. Auth and Settings pages should feel like the existing Upload page:
one centered card, clear labels, no visual noise.

## 5. Error Handling & Testing

- **Tenant isolation test is the acceptance gate**: pytest suite creates two
  tenants, indexes distinct data into each, and asserts that each tenant's
  search key returns only its own documents (both the Meilisearch and FAISS
  paths) and that cross-tenant document fetches fail.
- Missing/invalid API key → 401. Search key used on admin endpoints → 403.
  JWT of tenant A touching tenant B resources → 404/403.
- GCS unreachable at search time → degrade to keyword-only results (Meilisearch)
  with a logged warning; never a blanket 500.
- Unit tests for: key generation/hashing, storage abstraction (local roundtrip),
  parser tenant tagging.

## Migration Note

Existing single-tenant deployments have data in the `products` index. MVP
approach: no automatic migration — after upgrade, the operator re-uploads their
CSV under their new account. Documented in the release notes/README.
