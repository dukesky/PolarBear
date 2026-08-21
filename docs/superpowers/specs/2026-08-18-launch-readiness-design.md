# Launch Readiness (D2) — Design Spec

**Date**: 2026-08-18
**Sub-project**: D2 — export, one-command self-host, rate limiting, key domain binding, CORS
**Status**: Scope approved by user (2026-08-18); design decisions recorded below
**Depends on**: D1 launch blockers (`8b8235a`)

## Context & Motivation

D1 closed the three disqualifying gaps. D2 is the remaining gate the user set
before opening the hosted service to real merchants. Five items, each verified
as a real gap against the current code:

| Gap | Evidence |
|---|---|
| No data export | `GET /products/export` → 405; a merchant's catalog can go in but not come out. D1's delete-account UI already tells merchants to "download anything you need first" — a promise nothing currently fulfils. |
| Self-host needs three terminals | `infrastructure/docker-compose.yml` has the backend and frontend services commented out; it starts only Meilisearch and Postgres. |
| No rate limiting | The public search key sits in page source by design; nothing bounds how often it can be used. |
| Search key works from anywhere | `resolve_search_tenant` accepts any valid key regardless of origin, and `Tenant.website_url` already exists unused. |
| `allow_origins=["*"]` with `allow_credentials=True` | `backend/app/main.py`. Browsers reject that combination today, so nothing is currently exploitable, but it becomes a real hole the moment any cookie-based auth is added. |

## Goals

- A merchant can download their catalog as CSV or JSON at any time, making the
  delete-account warning honest.
- `docker compose up` brings the whole product up, so a self-hoster gets a
  working PolarBear without reading three sets of instructions.
- Abuse of a public search key is bounded without adding infrastructure.
- A merchant who wants their key restricted to their own site can opt into it,
  without that breaking app or server-side integrations.
- The CORS configuration stops being a latent hole.

## Non-Goals (YAGNI)

- Distributed/shared-state rate limiting (would mean Redis — a new dependency
  that contradicts the "clone and run" self-host story). Per-instance counting
  is enough to stop abuse at this scale; the cap is documented as approximate.
- Import/export of analytics, settings, or API keys — the catalog is what a
  merchant owns and needs portable.
- Per-endpoint or per-plan rate tiers, quotas, billing.
- Search quality (sub-project A), Shopify App (C2).

## 1. Catalog export

`GET /products/export?format=csv` (default) or `?format=json`, admin auth
(`resolve_admin_tenant`, same as every other catalog route).

Returns the tenant's full catalog as a download:

- **CSV**: columns in `TARGET_FIELDS` order (`id, title, description, price,
  category, brand, tags, image_url, url`), written with `csv.DictWriter` so
  quoting and embedded commas are handled. `Content-Disposition:
  attachment; filename="polarbear-products-<YYYY-MM-DD>.csv"`.
- **JSON**: `{"products": [...], "count": N, "exported_at": "<ISO8601>"}`.
- An unknown `format` → 400. An empty catalog exports a header-only CSV (or
  `count: 0`), not an error.

**Round-trip guarantee**: the exported CSV uses PolarBear's own column names,
so re-uploading it goes through the legacy no-mapping path unchanged. This is
what makes the export genuinely portable rather than decorative, and it is
covered by a test that exports, re-imports, and compares.

Frontend: an "Export catalog" control in the Insights product-catalog header
next to Refresh and Clear catalog, and a link in the Settings danger zone
turning "Download anything you need first" into an actual button.

## 2. One-command self-host

`infrastructure/docker-compose.yml` gains working `backend` and `frontend`
services alongside Meilisearch and Postgres, so `docker compose up` is the
whole product.

- **backend**: builds `../backend`, depends on meilisearch + postgres,
  environment wired to the compose service names
  (`MEILI_HOST=http://meilisearch:7700`,
  `DATABASE_URL=postgresql+asyncpg://polarbear:polarbear@postgres:5432/polarbear`),
  `SECRET_KEY` read from the environment with a clearly-marked development
  default, `DATA_DIR=/data` on a named volume so indexes survive restarts.
- **frontend**: builds `../frontend` with
  `args: NEXT_PUBLIC_API_URL=${PUBLIC_BACKEND_URL:-http://localhost:8000}` —
  it must be a build arg, because `NEXT_PUBLIC_*` is inlined at build time and
  cannot be set at run time. This is the same trap that bit the hosted deploy.
- The compose file's build contexts are `../backend` and `../frontend`, since
  it lives in `infrastructure/`.

README's Quick Start gains a "fastest path" showing the single command, with
the existing three-terminal instructions kept below for development.

## 3. Rate limiting

A small in-process fixed-window limiter, `backend/app/core/ratelimit.py`, with
no new dependency and no shared state:

- `check_rate_limit(bucket_key: str) -> None` raises `HTTPException(429)` with
  a `Retry-After` header when a bucket exceeds its allowance in the current
  60-second window.
- Applied to `/search` and `/analytics/track` and `/analytics/install-ping` —
  the three endpoints reachable with a public key.
- Keyed by tenant id, so one noisy merchant cannot starve another.
- Default `RATE_LIMIT_PER_MINUTE = 120` (env-configurable); `0` disables it
  entirely, which is what a self-hoster behind their own proxy will want.
- Windows are pruned lazily on access, so the dict cannot grow without bound.

**Documented honestly**: with more than one server instance the effective cap
is per instance, so a tenant may see up to `instances × limit`. That is
acceptable for abuse prevention and is written in the code comment and the
docs rather than being quietly wrong.

## 4. Search key domain binding — opt-in

New `Tenant.restrict_key_to_website: bool` (default `False`). A checkbox in
Settings beside the website field: *"Only allow this key on my website."*

When enabled and `website_url` is set, `resolve_search_tenant` compares the
request's normalized origin to `website_url`:

| Request | Behavior |
|---|---|
| Origin matches `website_url` | allowed |
| Origin present and does not match | **403** |
| No Origin and no Referer (app, server, curl) | **allowed** |

The third row is the important one. Native apps and server-side callers send
no `Origin`, so enforcing on absence would silently break every integration
built in C1.6. The Settings copy says so plainly: this setting stops other
*websites* from using your key; app and server integrations are unaffected.

Default off means no existing merchant's integration changes behavior on
deploy.

## 5. CORS

`allow_credentials` becomes `False`. PolarBear authenticates with `Bearer`
tokens and the `X-PolarBear-Key` header, never cookies, so credentials were
never needed — and `allow_origins=["*"]` combined with credentials is the
invalid, dangerous pairing. `allow_origins` stays `["*"]` because the widget
must work from any merchant's domain by design.

## 6. Error Handling & Testing

**Backend tests**

- Export: CSV has the `TARGET_FIELDS` header and one row per product; JSON has
  `count` matching; bad format → 400; empty catalog exports headers only;
  **round trip** — export a catalog, re-upload the exported CSV with no
  mapping, and confirm the same product ids come back
- Export requires admin auth: 401 unauthenticated, 403 with a search key
- Rate limit: the `(limit + 1)`th call within a window is 429 and carries
  `Retry-After`; a different tenant is unaffected; `RATE_LIMIT_PER_MINUTE=0`
  disables the check entirely
- Domain binding: off by default (a mismatched origin still works); on with a
  matching origin works; on with a mismatched origin is 403; on with **no**
  origin is allowed (the app path); the toggle round-trips through
  `PUT /tenant/website`
- CORS: the app's middleware reports `allow_credentials` false

**Frontend**: export controls and the restriction checkbox render; build passes.

**Manual**: `docker compose up` from a clean checkout reaches a working
register → upload → search, with no other commands run.

## Acceptance Criteria

1. A merchant can export their catalog and re-upload that exact file without
   touching it.
2. `docker compose up` alone produces a working PolarBear.
3. A public key hammered past the limit gets 429s while another tenant is
   unaffected.
4. Turning on key restriction blocks another website's origin while leaving
   app and server-side integrations working.
