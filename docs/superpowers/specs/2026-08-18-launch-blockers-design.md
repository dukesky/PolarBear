# Launch Blockers (D1) — Design Spec

**Date**: 2026-08-18
**Sub-project**: D1 — password reset, deletion, LICENSE
**Status**: Approved by user (brainstorming session 2026-08-18)
**Depends on**: everything merged through `578c235`

## Context & Motivation

The merchant path works end to end — register, upload any product export,
paste two lines, search, see analytics. But an audit of the hosted service
against "can we open this to strangers?" found gaps that were deliberately
deferred as YAGNI and are now blocking. Verified against production:

```
POST /auth/forgot-password  -> 404   (never mounted)
DELETE /products/{id}       -> 405   (no delete route exists anywhere)
git clone … && ls LICENSE   -> absent (README and specs claim MIT)
```

Each one is disqualifying on its own:

- **A forgotten password loses the account forever.** There is no reset path,
  so the merchant loses their catalog, their analytics, and their API keys —
  and because the search key is embedded in their website, they cannot even
  rotate the widget that is still running there.
- **A merchant cannot delete anything.** No product delete, no catalog clear,
  no account delete. "Can I take my data out or destroy it?" is the most basic
  question a privacy-first product must answer yes to.
- **No LICENSE file.** A repository without one is "all rights reserved" by
  default, whatever the README says. For a project whose stated positioning is
  open-source infrastructure, this blocks adoption by anyone with a legal
  department.

D2 (export, one-command self-host, rate limiting, key domain binding, CORS)
follows this spec; the service opens to users only after both.

## Goals

- A merchant who forgets their password can recover it without contacting us.
- A merchant can delete a single product, clear their catalog, or destroy
  their account and every trace of their data.
- The repository is unambiguously MIT-licensed.
- No new third-party service dependency: email goes over plain SMTP, and the
  product works with no email configured at all.

## Non-Goals (YAGNI — deferred to D2 or later)

- CSV/JSON export of a merchant's catalog (D2 — but the delete-account UI
  already tells merchants to export first, so D2 completes that story)
- One-command `docker compose up` for the whole stack (D2)
- Rate limiting, search-key domain binding, CORS tightening (D2)
- Email verification on signup, soft-delete with a grace period, admin console
- Search quality (sub-project A)

## 1. Pluggable email

New `backend/app/services/email.py` exposing exactly two functions:
`send_email(to: str, subject: str, body: str) -> bool` and
`send_password_reset(to: str, token: str) -> bool`.

Transport is Python's standard-library `smtplib` — no new dependency, no
vendor lock-in. Behavior by configuration:

| State | Behavior |
|---|---|
| `SMTP_HOST` set | Send over SMTP (STARTTLS when `SMTP_TLS` is true; authenticate when `SMTP_USER` is set) |
| `SMTP_HOST` unset | Log the full reset URL to the backend log and return `False`. Development and self-hosted installs stay usable: an operator reads the link from the log. |
| Send raises | Log the error and return `False` — never propagate |

New settings, all read from the environment with safe defaults:
`SMTP_HOST` (`""`), `SMTP_PORT` (`587`), `SMTP_USER` (`""`), `SMTP_PASSWORD`
(`""`), `SMTP_FROM` (`"polarbear@localhost"`), `SMTP_TLS` (`"true"`).

The reset link points at the frontend:
`{FRONTEND_URL}/reset-password?token={token}`.

## 2. Password reset

fastapi-users already implements the flow; it was simply never mounted. Mount
`fastapi_users.get_reset_password_router()` under `/auth`, yielding
`POST /auth/forgot-password` and `POST /auth/reset-password`.

`UserManager.on_after_forgot_password` calls `send_password_reset`. Token
lifetime is one hour (`reset_password_token_lifetime_seconds = 3600`).

**Both endpoints must not leak account existence**: fastapi-users already
returns 202 for `forgot-password` regardless of whether the address is
registered, and the email send failing must not change that.

Frontend gains two pages in the existing centered-card style:

- `/forgot-password` — email field, submits to `/auth/forgot-password`, then
  always shows "If that address has an account, we've sent a reset link."
- `/reset-password` — reads `?token=`, takes a new password, submits to
  `/auth/reset-password`, then redirects to `/login` on success and shows a
  plain error ("This reset link has expired — request a new one.") on failure.

The login page gains a "Forgot your password?" link.

## 3. Deletion

Three levels, all admin-authenticated and tenant-scoped:

| Endpoint | Body | Effect |
|---|---|---|
| `DELETE /products/{product_id}` | — | Remove one product from Meilisearch and rebuild that tenant's vector index |
| `DELETE /products/` | `{"confirm": "delete all products"}` | Remove every product and the tenant's vector index artifacts |
| `DELETE /tenant/account` | `{"email": "<the caller's own email>"}` | Destroy the tenant and every trace of its data |

**Vector index consistency is the subtle part.** The FAISS index is a rebuild-
from-scratch artifact keyed by position, so deleting a document from
Meilisearch without rebuilding leaves the vector index pointing at a product
that no longer exists. Both product-delete paths therefore rebuild (or clear)
the FAISS artifacts through the existing `HybridIndexer`, and invalidate the
in-memory cache for that tenant.

**Account deletion order** — external resources first, database last, because a
half-finished delete that leaves database rows is recoverable while orphaned
external data is not discoverable:

1. Meilisearch index `products_{tenant_id}`
2. GCS objects under `tenants/{tenant_id}/` in the private index bucket and in
   the public image bucket (no-op for local storage beyond the local dirs)
3. Database rows, in FK-safe order: `WidgetPing`, `SearchLog`, `ProductStat`,
   `APIKey`, `Tenant`, then the `User`

Every step is individually guarded: a failure is logged and the sequence
continues. A merchant must be able to leave even when an external service is
down. The response reports what was removed.

`IndexStorage` gains `delete_tenant(tenant_id: str) -> None` so account
deletion does not reach into storage internals; `LocalStorage` removes the
tenant's directories, `GCSStorage` deletes blobs under both prefixes.

**Frontend**: the Insights product catalog gains a per-row Delete (with a
`confirm()` guard) and a "Clear catalog" action on the card header. Settings
gains a red-bordered danger zone at the bottom: an explanation, a note to
export first (D2), an email-confirmation input, and a Delete-account button
that stays disabled until the typed address matches the signed-in account.
On success the frontend clears the token and returns to `/login`.

## 4. LICENSE

Add a standard MIT `LICENSE` file at the repository root, copyright the
project owner, year 2026. Remove `Design Doc.gdoc` — a 174-byte Google Docs
shortcut that is meaningless to anyone who clones the repository (the readable
`Design Doc.txt` stays).

## 5. Error Handling & Testing

**Backend errors**

- `DELETE /products/{id}` on a missing product → 404
- `DELETE /products/` without the exact confirm string → 400
- `DELETE /tenant/account` with a mismatched email → 400
- All three with a search key instead of an admin key → 403 (existing
  `resolve_admin_tenant` behavior); unauthenticated → 401
- Email send failure → logged, `forgot-password` still 202

**Backend tests (pytest)**

- Reset flow: `forgot-password` returns 202 with no SMTP configured and does
  not raise; the generated token resets the password and the new password
  logs in; an invalid/garbage token is rejected
- `forgot-password` for an unregistered address also returns 202 (no
  account-existence leak)
- Deleting a product removes it from the indexer's document set and
  invalidates the vector cache
- Clearing the catalog requires the exact confirm string
- **Account deletion is the acceptance gate**: create two tenants, give both
  data, delete tenant A, then assert every table has no rows for A, A's user
  can no longer log in, and **tenant B's data is completely untouched**
- Account deletion still succeeds and still removes database rows when the
  storage backend raises

**Frontend**: the two new auth pages and the danger zone render; build passes.

**Manual**: against a local stack, run the reset flow end to end reading the
link from the backend log, then delete a test account and confirm login fails.

## Acceptance Criteria

1. A merchant who forgets their password recovers it unaided — and on an
   install with no SMTP configured, an operator can complete the same flow
   from the backend log.
2. A merchant can delete one product, all products, or their entire account,
   and after account deletion no row, index, or object referencing them
   remains — while other tenants are provably unaffected.
3. `git clone` yields a repository with an MIT LICENSE file.
