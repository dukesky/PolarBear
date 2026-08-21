# Launch Readiness (D2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clear the last gate before opening the hosted service — merchants can take their data out, self-hosters get one command, public keys are bounded and optionally domain-locked, and the CORS hole is closed.

**Architecture:** An export route that reuses `TARGET_FIELDS` so exported CSVs re-import through the existing no-mapping path; a dependency-free in-process fixed-window limiter applied to the three public-key endpoints; an opt-in `restrict_key_to_website` flag enforced inside `resolve_search_tenant` that only rejects a *mismatched* origin, never a missing one; and a completed compose file.

**Tech Stack:** FastAPI, SQLAlchemy 2 async, Python stdlib (`csv`, `io`, `time`), Next.js 16 + Tailwind 4, Docker Compose, pytest.

**Spec:** `docs/superpowers/specs/2026-08-18-launch-readiness-design.md`

## Global Constraints

- Backend tests: `cd backend && poetry run pytest` (asyncio_mode=auto; existing `client` / `registered` conftest fixtures). Frontend: `cd frontend && npm run build`.
- **No new Python or npm dependencies.** The limiter is a plain dict; export uses stdlib `csv`.
- Export column order is exactly `TARGET_FIELDS` from `app.services.ingestion.mapping`: `id, title, description, price, category, brand, tags, image_url, url`. An exported CSV must re-upload through `/ingest/upload` with NO mapping field.
- Rate limiting is keyed by tenant id, default `RATE_LIMIT_PER_MINUTE = 120`, `0` disables it, window is a fixed 60 seconds, and a rejection is `429` carrying a `Retry-After` header. Applied to `/search`, `/analytics/track`, `/analytics/install-ping`.
- Domain binding is OPT-IN (`Tenant.restrict_key_to_website`, default `False`) and only rejects a request whose Origin/Referer is present AND does not match `website_url`. A request with no Origin and no Referer is always allowed — apps and servers send none, and breaking them would undo sub-project C1.6.
- New model column `restrict_key_to_website` MUST be added to `MISSING_COLUMN_SHIM` in `backend/app/core/db.py`, or the live Postgres breaks on deploy (there is no Alembic).
- `allow_credentials` becomes `False`; `allow_origins=["*"]` stays — the widget must work from any merchant domain.
- Frontend: Tailwind utilities only, no new packages, existing white / gray-border / `indigo-600` card style.
- YAGNI (out of scope): Redis/shared rate-limit state, analytics or settings export, per-plan tiers, search quality, Shopify App.

---

### Task 1: Catalog export

**Files:**
- Modify: `backend/app/api/routes/products.py`
- Test: `backend/tests/test_export.py`

**Interfaces:**
- Consumes: `resolve_admin_tenant`, `HybridIndexer(str(tenant.id))` (its `meili_client` and `index_name` are used to read documents), `TARGET_FIELDS` from `app.services.ingestion.mapping`.
- Produces: `GET /products/export?format=csv|json`.

- [ ] **Step 1: Write the failing test**

`backend/tests/test_export.py`:

```python
import csv
import io


class FakeIndex:
    def __init__(self, docs):
        self.docs = docs

    def get_documents(self, params):
        class R:
            pass

        r = R()
        r.results = list(self.docs)
        return r


class FakeClient:
    def __init__(self, docs):
        self._index = FakeIndex(docs)

    def index(self, name):
        return self._index


def _indexer_factory(docs):
    class StubIndexer:
        def __init__(self, tenant_id, storage=None, meili_client=None):
            self.tenant_id = str(tenant_id)
            self.meili_client = FakeClient(docs)
            self.index_name = f"products_{tenant_id}"

    return StubIndexer


DOCS = [
    {
        "id": "sku-1",
        "title": "Blue Mug",
        "description": "Ceramic, holds 12oz",
        "price": 12.5,
        "category": "Drinkware",
        "brand": "MyShop",
        "tags": "mug,gift",
        "image_url": "https://ex.com/1.jpg",
        "url": "https://ex.com/p/1",
    },
    {"id": "sku-2", "title": "Red Mug", "description": "", "price": ""},
]


async def test_export_csv_uses_polarbear_columns(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import products
    from app.services.ingestion.mapping import TARGET_FIELDS

    monkeypatch.setattr(products, "HybridIndexer", _indexer_factory(DOCS))

    r = await client.get(
        "/products/export", headers={"Authorization": f"Bearer {token}"}
    )
    assert r.status_code == 200, r.text
    assert "text/csv" in r.headers["content-type"]
    assert "attachment" in r.headers["content-disposition"]

    rows = list(csv.DictReader(io.StringIO(r.text)))
    assert list(rows[0].keys()) == TARGET_FIELDS
    assert [row["id"] for row in rows] == ["sku-1", "sku-2"]
    assert rows[0]["title"] == "Blue Mug"
    assert rows[1]["description"] == ""  # missing fields become empty, not "None"


async def test_export_json(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import products

    monkeypatch.setattr(products, "HybridIndexer", _indexer_factory(DOCS))

    r = await client.get(
        "/products/export",
        params={"format": "json"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["count"] == 2
    assert body["products"][0]["id"] == "sku-1"
    assert body["exported_at"]


async def test_export_rejects_an_unknown_format(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import products

    monkeypatch.setattr(products, "HybridIndexer", _indexer_factory(DOCS))

    r = await client.get(
        "/products/export",
        params={"format": "xml"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 400


async def test_export_of_an_empty_catalog_is_headers_only(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import products
    from app.services.ingestion.mapping import TARGET_FIELDS

    monkeypatch.setattr(products, "HybridIndexer", _indexer_factory([]))

    r = await client.get("/products/export", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    assert r.text.strip() == ",".join(TARGET_FIELDS)


async def test_export_requires_admin_credentials(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import products

    monkeypatch.setattr(products, "HybridIndexer", _indexer_factory(DOCS))
    keys = (
        await client.get("/tenant/keys", headers={"Authorization": f"Bearer {token}"})
    ).json()

    assert (await client.get("/products/export")).status_code == 401
    r = await client.get(
        "/products/export", headers={"X-PolarBear-Key": keys["search"]["key"]}
    )
    assert r.status_code == 403


async def test_exported_csv_reimports_without_a_mapping(registered, monkeypatch):
    """The point of the export: a merchant can feed it straight back in."""
    client, token, _ = registered
    from app.api.routes import ingestion, products

    monkeypatch.setattr(products, "HybridIndexer", _indexer_factory(DOCS))

    captured = {}

    class RecordingIndexer:
        def __init__(self, tenant_id, storage=None, meili_client=None):
            pass

        def index_data(self, docs):
            captured["docs"] = docs

    monkeypatch.setattr(ingestion, "HybridIndexer", RecordingIndexer)

    exported = (
        await client.get("/products/export", headers={"Authorization": f"Bearer {token}"})
    ).text

    files = {"file": ("polarbear-products.csv", io.BytesIO(exported.encode()), "text/csv")}
    r = await client.post(
        "/ingest/upload", files=files, headers={"Authorization": f"Bearer {token}"}
    )
    assert r.status_code == 200, r.text
    assert [d["id"] for d in captured["docs"]] == ["sku-1", "sku-2"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_export.py -v`
Expected: FAIL — `/products/export` is 405 (the `/{product_id}` route does not match a GET on `export`, and no export route exists).

- [ ] **Step 3: Implement the route**

In `backend/app/api/routes/products.py`, add these imports:

```python
import csv
import io
from datetime import datetime, timezone

from fastapi.responses import Response

from app.services.ingestion.mapping import TARGET_FIELDS
```

Add the route **above** `@router.put("/{product_id}")` and `@router.delete("/{product_id}")` so the literal path is matched before the parameterised ones:

```python
@router.get("/export")
async def export_products(
    format: str = "csv", tenant: Tenant = Depends(resolve_admin_tenant)
):
    """Download the catalog. The CSV uses PolarBear's own column names, so a
    merchant can re-upload the file unchanged."""
    if format not in ("csv", "json"):
        raise HTTPException(status_code=400, detail="format must be 'csv' or 'json'.")

    indexer = HybridIndexer(str(tenant.id))
    try:
        results = indexer.meili_client.index(indexer.index_name).get_documents(
            {"limit": 10000}
        )
        documents = [dict(d) for d in results.results]
    except Exception as e:
        print(f"[products] export failed for tenant {tenant.id}: {e}")
        raise HTTPException(status_code=500, detail="Could not read the catalog.")

    rows = [{field: doc.get(field, "") for field in TARGET_FIELDS} for doc in documents]
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    if format == "json":
        return {
            "products": rows,
            "count": len(rows),
            "exported_at": datetime.now(timezone.utc).isoformat(),
        }

    buffer = io.StringIO()
    writer = csv.DictWriter(buffer, fieldnames=TARGET_FIELDS)
    writer.writeheader()
    writer.writerows(rows)
    return Response(
        content=buffer.getvalue(),
        media_type="text/csv",
        headers={
            "Content-Disposition": f'attachment; filename="polarbear-products-{stamp}.csv"'
        },
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_export.py tests/test_product_delete.py -v`
Expected: all PASS — the export tests plus the existing delete tests, confirming route ordering did not shadow `/{product_id}`.

- [ ] **Step 5: Commit**

```bash
git add backend/app/api/routes/products.py backend/tests/test_export.py
git commit -m "feat: export the catalog as CSV or JSON, re-importable unchanged"
```

---

### Task 2: Rate limiting

**Files:**
- Create: `backend/app/core/ratelimit.py`
- Modify: `backend/app/core/config.py`, `backend/app/api/routes/search.py`, `backend/app/api/routes/analytics.py`
- Test: `backend/tests/test_ratelimit.py`

**Interfaces:**
- Produces:
  - `app.core.ratelimit`: `check_rate_limit(bucket_key: str) -> None` (raises `HTTPException(429)` with `Retry-After`), `reset_limits() -> None` (test helper)
  - `settings.RATE_LIMIT_PER_MINUTE: int` (default 120; `0` disables)

- [ ] **Step 1: Write the failing test**

`backend/tests/test_ratelimit.py`:

```python
import pytest


def test_limit_allows_up_to_the_cap_then_rejects(monkeypatch):
    from app.core import ratelimit
    from app.core.config import settings
    from fastapi import HTTPException

    monkeypatch.setattr(settings, "RATE_LIMIT_PER_MINUTE", 3)
    ratelimit.reset_limits()

    for _ in range(3):
        ratelimit.check_rate_limit("tenant-a")

    with pytest.raises(HTTPException) as exc:
        ratelimit.check_rate_limit("tenant-a")
    assert exc.value.status_code == 429
    assert "Retry-After" in exc.value.headers


def test_limit_is_per_bucket(monkeypatch):
    from app.core import ratelimit
    from app.core.config import settings

    monkeypatch.setattr(settings, "RATE_LIMIT_PER_MINUTE", 2)
    ratelimit.reset_limits()

    ratelimit.check_rate_limit("tenant-a")
    ratelimit.check_rate_limit("tenant-a")
    ratelimit.check_rate_limit("tenant-b")  # a noisy tenant must not starve another
    ratelimit.check_rate_limit("tenant-b")


def test_zero_disables_the_limit(monkeypatch):
    from app.core import ratelimit
    from app.core.config import settings

    monkeypatch.setattr(settings, "RATE_LIMIT_PER_MINUTE", 0)
    ratelimit.reset_limits()

    for _ in range(500):
        ratelimit.check_rate_limit("tenant-a")  # must not raise


def test_a_new_window_resets_the_count(monkeypatch):
    from app.core import ratelimit
    from app.core.config import settings

    monkeypatch.setattr(settings, "RATE_LIMIT_PER_MINUTE", 1)
    ratelimit.reset_limits()

    now = [1_000_000.0]
    monkeypatch.setattr(ratelimit.time, "time", lambda: now[0])

    ratelimit.check_rate_limit("tenant-a")
    now[0] += 61  # next window
    ratelimit.check_rate_limit("tenant-a")  # must not raise


async def test_search_is_rate_limited(registered, monkeypatch):
    from app.api.routes import search as search_route
    from app.core import ratelimit
    from app.core.config import settings

    class StubSearcher:
        def __init__(self, tenant_id, storage=None, meili_client=None):
            pass

        def search(self, q, limit=20):
            return []

    monkeypatch.setattr(search_route, "HybridSearcher", StubSearcher)
    monkeypatch.setattr(settings, "RATE_LIMIT_PER_MINUTE", 2)
    ratelimit.reset_limits()

    client, token, _ = registered
    key = (
        await client.get("/tenant/keys", headers={"Authorization": f"Bearer {token}"})
    ).json()["search"]["key"]

    assert (await client.get("/search/", params={"q": "a", "key": key})).status_code == 200
    assert (await client.get("/search/", params={"q": "b", "key": key})).status_code == 200
    third = await client.get("/search/", params={"q": "c", "key": key})
    assert third.status_code == 429
    assert third.headers.get("retry-after")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_ratelimit.py -v`
Expected: FAIL — `ModuleNotFoundError: app.core.ratelimit`.

- [ ] **Step 3: Add the setting**

In `backend/app/core/config.py`, inside `class Settings`, after the SMTP block:

```python
    # Requests per minute per tenant on the endpoints a public search key can
    # reach. 0 disables the limit, which is what a self-hoster behind their own
    # proxy usually wants.
    RATE_LIMIT_PER_MINUTE: int = int(os.getenv("RATE_LIMIT_PER_MINUTE", "120"))
```

- [ ] **Step 4: Write the limiter**

`backend/app/core/ratelimit.py`:

```python
"""A small fixed-window rate limiter.

Deliberately in-process and dependency-free: adding Redis would buy exact
counting across instances at the cost of the "clone it and run it" self-hosting
story. With more than one instance the effective cap is per instance, so a
tenant may see up to (instances x limit) requests per minute. That is fine for
stopping abuse, and saying so is better than a shared-state claim we do not
actually make.
"""

import time

from fastapi import HTTPException

from app.core.config import settings

WINDOW_SECONDS = 60

# bucket key -> (window start, count in that window)
_counters: dict[str, tuple[float, int]] = {}


def reset_limits() -> None:
    """Drop all counters. Used by tests."""
    _counters.clear()


def check_rate_limit(bucket_key: str) -> None:
    """Raise 429 when this bucket has exceeded its allowance for the window."""
    limit = settings.RATE_LIMIT_PER_MINUTE
    if limit <= 0:
        return

    now = time.time()
    window_start = now - (now % WINDOW_SECONDS)

    start, count = _counters.get(bucket_key, (window_start, 0))
    if start != window_start:
        start, count = window_start, 0

    if count >= limit:
        retry_after = int(window_start + WINDOW_SECONDS - now) + 1
        raise HTTPException(
            status_code=429,
            detail="Too many requests. Try again shortly.",
            headers={"Retry-After": str(retry_after)},
        )

    _counters[bucket_key] = (start, count + 1)

    # Keep the dict from growing forever on a long-lived instance: anything
    # from an older window is dead weight.
    if len(_counters) > 10000:
        for key in [k for k, (s, _) in _counters.items() if s != window_start]:
            del _counters[key]
```

- [ ] **Step 5: Apply it to the public endpoints**

In `backend/app/api/routes/search.py`, import `from app.core.ratelimit import check_rate_limit` and call it as the first statement of the `search` function body:

```python
    check_rate_limit(str(tenant_id))
```

In `backend/app/api/routes/analytics.py`, import the same helper and call
`check_rate_limit(str(tenant_id))` as the first statement of both `track_event`
and `install_ping`. Do NOT add it to `/analytics/stats` — that is a JWT-only
dashboard route, not reachable with a public key.

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_ratelimit.py tests/test_search_route.py tests/test_install_ping.py tests/test_track_auth.py -v`
Expected: all PASS.

- [ ] **Step 7: Run the full suite**

Run: `cd backend && poetry run pytest`
Expected: all green. If any pre-existing test now trips the limit because it makes many calls in one window, call `ratelimit.reset_limits()` in that test rather than raising the default.

- [ ] **Step 8: Commit**

```bash
git add backend/app/core/ratelimit.py backend/app/core/config.py backend/app/api/routes/search.py backend/app/api/routes/analytics.py backend/tests/test_ratelimit.py
git commit -m "feat: per-tenant rate limiting on the public-key endpoints"
```

---

### Task 3: Opt-in search key domain binding

**Files:**
- Modify: `backend/app/models.py`, `backend/app/core/db.py`, `backend/app/core/tenancy.py`, `backend/app/api/routes/tenant.py`
- Test: `backend/tests/test_key_restriction.py`

**Interfaces:**
- Consumes: `normalize_origin`, `origin_from_request`, `UNKNOWN` from `app.services.origins`; `resolve_key`; `Tenant.website_url`.
- Produces:
  - `Tenant.restrict_key_to_website: Mapped[bool]` default `False`
  - `PUT /tenant/website` accepts an optional `restrict_key_to_website` boolean and echoes it back
  - `GET /tenant/install-status` includes `restrict_key_to_website`
  - `resolve_search_tenant` rejects a *mismatched* origin with 403 when the flag is on

- [ ] **Step 1: Write the failing test**

`backend/tests/test_key_restriction.py`:

```python
async def _key(client, token):
    r = await client.get("/tenant/keys", headers={"Authorization": f"Bearer {token}"})
    return r.json()["search"]["key"]


def _stub_searcher(monkeypatch):
    from app.api.routes import search as search_route

    class StubSearcher:
        def __init__(self, tenant_id, storage=None, meili_client=None):
            pass

        def search(self, q, limit=20):
            return []

    monkeypatch.setattr(search_route, "HybridSearcher", StubSearcher)


async def test_restriction_is_off_by_default(registered, monkeypatch):
    """An existing merchant's integration must not change behavior on deploy."""
    client, token, _ = registered
    _stub_searcher(monkeypatch)
    auth = {"Authorization": f"Bearer {token}"}
    await client.put("/tenant/website", json={"website_url": "mystore.com"}, headers=auth)
    key = await _key(client, token)

    r = await client.get(
        "/search/", params={"q": "mug", "key": key}, headers={"Origin": "https://elsewhere.com"}
    )
    assert r.status_code == 200


async def test_restriction_blocks_a_mismatched_origin(registered, monkeypatch):
    client, token, _ = registered
    _stub_searcher(monkeypatch)
    auth = {"Authorization": f"Bearer {token}"}
    r = await client.put(
        "/tenant/website",
        json={"website_url": "mystore.com", "restrict_key_to_website": True},
        headers=auth,
    )
    assert r.status_code == 200
    assert r.json()["restrict_key_to_website"] is True
    key = await _key(client, token)

    blocked = await client.get(
        "/search/", params={"q": "mug", "key": key}, headers={"Origin": "https://elsewhere.com"}
    )
    assert blocked.status_code == 403

    allowed = await client.get(
        "/search/", params={"q": "mug", "key": key}, headers={"Origin": "https://www.mystore.com"}
    )
    assert allowed.status_code == 200


async def test_restriction_still_allows_requests_with_no_origin(registered, monkeypatch):
    """Apps and servers send no Origin - restricting them would undo C1.6."""
    client, token, _ = registered
    _stub_searcher(monkeypatch)
    auth = {"Authorization": f"Bearer {token}"}
    await client.put(
        "/tenant/website",
        json={"website_url": "mystore.com", "restrict_key_to_website": True},
        headers=auth,
    )
    key = await _key(client, token)

    r = await client.get("/search/", params={"q": "mug", "key": key})
    assert r.status_code == 200


async def test_restriction_without_a_website_does_not_block(registered, monkeypatch):
    client, token, _ = registered
    _stub_searcher(monkeypatch)
    auth = {"Authorization": f"Bearer {token}"}
    await client.put(
        "/tenant/website", json={"website_url": "", "restrict_key_to_website": True}, headers=auth
    )
    key = await _key(client, token)

    r = await client.get(
        "/search/", params={"q": "mug", "key": key}, headers={"Origin": "https://anywhere.com"}
    )
    assert r.status_code == 200


async def test_install_status_reports_the_flag(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    body = (await client.get("/tenant/install-status", headers=auth)).json()
    assert body["restrict_key_to_website"] is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_key_restriction.py -v`
Expected: FAIL — `restrict_key_to_website` is unknown to the model and the route.

- [ ] **Step 3: Add the column and the schema shim entry**

In `backend/app/models.py`, inside `class Tenant`, after `website_url`:

```python
    restrict_key_to_website: Mapped[bool] = mapped_column(Boolean, default=False)
```

Add `Boolean` to the existing `from sqlalchemy import ...` line in that file.

In `backend/app/core/db.py`, add an entry to `MISSING_COLUMN_SHIM` for
`tenants.restrict_key_to_website` with DDL type `BOOLEAN DEFAULT 0` (SQLite and
Postgres both accept `0`/`1` for booleans in a DEFAULT clause; use whatever
form matches the existing entries' style). **This is mandatory** — without it
the live Postgres breaks on deploy, because this project has no Alembic.

- [ ] **Step 4: Enforce it in the tenancy dependency**

In `backend/app/core/tenancy.py`, import the origin helpers:

```python
from app.services.origins import UNKNOWN, origin_from_request
```

and add the check inside `resolve_search_tenant`, immediately after the key
resolves to an `api_key` and before returning its tenant id:

```python
        tenant = (
            await session.execute(select(Tenant).where(Tenant.id == api_key.tenant_id))
        ).scalar_one_or_none()
        if tenant is not None and tenant.restrict_key_to_website and tenant.website_url:
            origin = origin_from_request(request)
            # Only a *mismatched* origin is rejected. Apps and server-side
            # callers send no Origin at all (recorded as UNKNOWN) and must keep
            # working - this setting exists to stop other websites, not to
            # break non-browser integrations.
            if origin != UNKNOWN and origin != tenant.website_url:
                raise HTTPException(
                    status_code=403,
                    detail="This search key is restricted to the store's own website.",
                )
        return api_key.tenant_id
```

- [ ] **Step 5: Expose the flag on the tenant routes**

In `backend/app/api/routes/tenant.py`, extend the website payload model and the
handler:

```python
class WebsiteUpdate(BaseModel):
    website_url: str
    restrict_key_to_website: bool | None = None
```

In `set_website`, after assigning `tenant.website_url`, add:

```python
    if payload.restrict_key_to_website is not None:
        tenant.restrict_key_to_website = payload.restrict_key_to_website
```

and return `{"website_url": tenant.website_url, "restrict_key_to_website": tenant.restrict_key_to_website}`.

In `install_status`, add `"restrict_key_to_website": tenant.restrict_key_to_website`
to the returned dictionary.

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_key_restriction.py tests/test_install_status.py tests/test_install_channels.py tests/test_search_route.py -v`
Expected: all PASS — the new tests plus every existing test that exercises `PUT /tenant/website`, `install-status`, or search-key resolution.

- [ ] **Step 7: Run the full suite**

Run: `cd backend && poetry run pytest`
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add backend/app/models.py backend/app/core/db.py backend/app/core/tenancy.py backend/app/api/routes/tenant.py backend/tests/test_key_restriction.py
git commit -m "feat: opt-in search key domain binding that never blocks app integrations"
```

---

### Task 4: CORS credentials

**Files:**
- Modify: `backend/app/main.py`
- Test: `backend/tests/test_cors.py`

**Interfaces:**
- Produces: the app's CORS middleware configured with `allow_credentials=False`.

- [ ] **Step 1: Write the failing test**

`backend/tests/test_cors.py`:

```python
def test_cors_does_not_allow_credentials_with_a_wildcard_origin():
    """allow_origins=* with credentials is the dangerous pairing. PolarBear
    authenticates with Bearer tokens and X-PolarBear-Key, never cookies."""
    from starlette.middleware.cors import CORSMiddleware

    from app.main import app

    cors = [m for m in app.user_middleware if m.cls is CORSMiddleware]
    assert cors, "CORS middleware is not installed"
    options = cors[0].kwargs
    assert options["allow_origins"] == ["*"]
    assert options["allow_credentials"] is False


async def test_widget_origin_still_gets_cors_headers(client):
    """The widget must keep working from any merchant domain."""
    r = await client.get("/health", headers={"Origin": "https://any-merchant.example"})
    assert r.status_code == 200
    assert r.headers.get("access-control-allow-origin") == "*"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_cors.py -v`
Expected: FAIL — `allow_credentials` is currently `True`.

- [ ] **Step 3: Change the setting**

In `backend/app/main.py`, in the `add_middleware(CORSMiddleware, ...)` call,
set `allow_credentials=False` and replace the surrounding comment with:

```python
# The widget runs on merchant domains, so origins stay open. Credentials are
# off because PolarBear authenticates with Bearer tokens and the
# X-PolarBear-Key header, never cookies - and "*" with credentials is the
# pairing that actually creates a hole.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_cors.py -v` then `poetry run pytest`
Expected: all PASS. If `app.user_middleware[...].kwargs` is not how this
Starlette version exposes the options, read the actual attribute (e.g.
`.options`) and use it, noting the difference in your report.

- [ ] **Step 5: Commit**

```bash
git add backend/app/main.py backend/tests/test_cors.py
git commit -m "fix: stop advertising CORS credentials alongside a wildcard origin"
```

---

### Task 5: One-command self-host

**Files:**
- Modify: `infrastructure/docker-compose.yml`, `README.md`, `docs/INTEGRATION.md`

- [ ] **Step 1: Complete the compose file**

Replace the commented-out backend/frontend blocks in
`infrastructure/docker-compose.yml` with working services (keep the existing
`meilisearch` and `postgres` services and the `volumes:` section, adding
`backend_data` to it):

```yaml
  backend:
    build: ../backend
    ports:
      - '8000:8000'
    environment:
      - MEILI_HOST=http://meilisearch:7700
      - MEILI_MASTER_KEY=masterKey
      - DATABASE_URL=postgresql+asyncpg://polarbear:polarbear@postgres:5432/polarbear
      # Change this before exposing the stack to anyone.
      - SECRET_KEY=${SECRET_KEY:-dev-secret-change-me}
      - INDEX_STORAGE=local
      - DATA_DIR=/data
      - PUBLIC_BACKEND_URL=${PUBLIC_BACKEND_URL:-http://localhost:8000}
      - FRONTEND_URL=${FRONTEND_URL:-http://localhost:3000}
      - PORT=8000
    volumes:
      - backend_data:/data
    depends_on:
      - meilisearch
      - postgres
    restart: always

  frontend:
    build:
      context: ../frontend
      args:
        # NEXT_PUBLIC_* is inlined at build time, so the API URL must be a build
        # arg - setting it as a runtime environment variable does nothing.
        NEXT_PUBLIC_API_URL: ${PUBLIC_BACKEND_URL:-http://localhost:8000}
    ports:
      - '3000:3000'
    depends_on:
      - backend
    restart: always
```

Add `backend_data:` to the `volumes:` block at the bottom of the file.

- [ ] **Step 2: Verify the compose file parses**

Run: `cd infrastructure && docker compose config --quiet && echo "compose OK"`
Expected: prints `compose OK` with no errors.

- [ ] **Step 3: Put the one-command path first in the README**

In `README.md`, in the Quick Start section, insert this immediately after the
"Clone the Repository" step and renumber the existing steps that follow:

```markdown
2.  **Start everything**
    ```bash
    cd infrastructure
    docker compose up -d
    ```
    That's the whole stack — Meilisearch, Postgres, the API and the dashboard.
    Open <http://localhost:3000/login> and register.

    > Set `SECRET_KEY` before exposing it to anyone: `SECRET_KEY=$(openssl rand -hex 32) docker compose up -d`

    Prefer to run the services yourself while developing? The three-terminal
    setup is below.
```

Keep the existing "Start Infrastructure / Start Backend / Start Frontend"
steps, retitling the first of them "Start Infrastructure only (development)".

- [ ] **Step 4: Update the self-hosting section of the integration guide**

In `docs/INTEGRATION.md`, in "Running PolarBear yourself", replace the three
numbered blocks with the single-command version first, then the development
alternative:

```markdown
```bash
git clone https://github.com/dukesky/PolarBear.git
cd PolarBear/infrastructure
docker compose up -d
```

That's everything — search engine, database, API and dashboard. Open
<http://localhost:3000/login> and register.

**Before anyone else can reach it**, set a real secret:

```bash
SECRET_KEY=$(openssl rand -hex 32) docker compose up -d
```

Developing on PolarBear itself? Run `docker compose up -d meilisearch postgres`
for the infrastructure and start the backend (`cd backend && poetry install &&
poetry run uvicorn app.main:app --reload --port 8000`) and frontend
(`cd frontend && npm install && npm run dev`) yourself.
```
```

Also add `RATE_LIMIT_PER_MINUTE` to the environment-variable table in that
section, described as "Requests per minute per merchant on the public search
endpoints; `0` disables it".

- [ ] **Step 5: Document the new settings in the env example**

Append to `backend/.env.example`:

```bash
# Requests per minute per merchant on the endpoints a public search key can
# reach. 0 disables the limit (useful behind your own proxy).
# RATE_LIMIT_PER_MINUTE=120
```

- [ ] **Step 6: Commit**

```bash
git add infrastructure/docker-compose.yml README.md docs/INTEGRATION.md backend/.env.example
git commit -m "feat: docker compose up runs the whole product"
```

---

### Task 6: Frontend — export controls and the restriction toggle

**Files:**
- Modify: `frontend/src/app/insights/page.tsx`, `frontend/src/app/settings/page.tsx`

**Interfaces:**
- Consumes: `GET /products/export?format=csv` (Task 1), `PUT /tenant/website` with `restrict_key_to_website` and `GET /tenant/install-status` returning it (Task 3); `authFetch`, `API_URL`, `getToken` from `../../lib/api`.

- [ ] **Step 1: Add the export control to the product catalog**

In `frontend/src/app/insights/page.tsx`, inside `ProductCatalog`, add this
handler next to the existing `removeProduct` / `clearCatalog`:

```tsx
    const exportCatalog = async () => {
        try {
            const r = await authFetch('/products/export?format=csv');
            if (!r.ok) {
                alert('Could not export the catalog. Please try again.');
                return;
            }
            const blob = await r.blob();
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = `polarbear-products-${new Date().toISOString().slice(0, 10)}.csv`;
            document.body.appendChild(a);
            a.click();
            a.remove();
            URL.revokeObjectURL(url);
        } catch {
            alert('Could not export the catalog. Please try again.');
        }
    };
```

The download goes through `authFetch` and a blob rather than a plain link
because the route needs the `Authorization` header — an `<a href>` cannot carry
one.

In the catalog card header, before the existing "Clear catalog" control, add:

```tsx
            <button onClick={exportCatalog} className="text-sm text-indigo-600 hover:text-indigo-800 ml-4">
              Export CSV
            </button>
```

- [ ] **Step 2: Add the restriction checkbox and an export link to Settings**

In `frontend/src/app/settings/page.tsx`, in the `InstallCheck` component, add
state and wire it through the existing save:

```tsx
  const [restrict, setRestrict] = useState(false);
```

In the `load()` callback where `d.website_url` is read, also read the flag:

```tsx
        setRestrict(Boolean(d.restrict_key_to_website));
```

In `saveWebsite`, send it alongside the URL:

```tsx
      body: JSON.stringify({ website_url: website, restrict_key_to_website: restrict }),
```

Directly beneath the website hint paragraph, add the checkbox:

```tsx
      <label className="flex items-start gap-2 mb-3 text-xs text-gray-600">
        <input
          type="checkbox"
          checked={restrict}
          onChange={(e) => setRestrict(e.target.checked)}
          className="mt-0.5"
        />
        <span>
          Only allow this key on my website. Blocks other <em>websites</em> from using
          your search key — app and server-side integrations keep working, because they
          don&apos;t send a browser origin. Save to apply.
        </span>
      </label>
```

In the `DangerZone` component, replace the sentence "Download anything you need
first." with a real link:

```tsx
        Download anything you need first —{' '}
        <a href="/insights" className="text-indigo-600 hover:underline">
          export your catalog
        </a>
        .
```

- [ ] **Step 3: Verify build**

Run: `cd frontend && npm run build`
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/app/insights/page.tsx frontend/src/app/settings/page.tsx
git commit -m "feat(frontend): catalog export and the key-restriction toggle"
```

---

## Final Verification (whole plan)

- [ ] `cd backend && poetry run pytest` — all green including the new export, ratelimit, key-restriction and CORS suites
- [ ] `cd frontend && npm run build` — clean
- [ ] `cd infrastructure && docker compose config --quiet` — parses
- [ ] **Acceptance gate**: export a catalog, then re-upload the exported file through `/ingest/upload` with no mapping and confirm the same products come back
- [ ] **Acceptance gate**: with the restriction on, a request carrying a foreign Origin is 403 while the same key with no Origin still returns results
- [ ] **Acceptance gate**: with `RATE_LIMIT_PER_MINUTE` set low, the over-limit request returns 429 with `Retry-After` while a second tenant is unaffected
- [ ] `git log --oneline` shows one commit per task
