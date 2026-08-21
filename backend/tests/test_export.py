import csv
import io
import json

import meilisearch.errors
from sqlalchemy import select


def index_not_found_error():
    """The error Meilisearch raises for a merchant who never uploaded anything."""

    class FakeResponse:
        status_code = 404
        text = json.dumps(
            {
                "message": "Index `products_x` not found.",
                "code": "index_not_found",
                "link": "https://docs.meilisearch.com/errors#index_not_found",
                "type": "invalid_request",
            }
        )

    return meilisearch.errors.MeilisearchApiError("index not found", FakeResponse())


class FakeIndex:
    """Pages the way Meilisearch does, and records what was asked for."""

    def __init__(self, docs, page_size=None, error=None):
        self.docs = docs
        self.page_size = page_size
        self.error = error
        self.calls = []

    def get_documents(self, params):
        if self.error is not None:
            raise self.error
        limit = params.get("limit", len(self.docs))
        offset = params.get("offset", 0)
        self.calls.append({"limit": limit, "offset": offset})
        if self.page_size is not None:
            limit = min(limit, self.page_size)

        class R:
            pass

        r = R()
        r.results = list(self.docs[offset : offset + limit])
        r.total = len(self.docs)
        r.limit = limit
        r.offset = offset
        return r


class FakeClient:
    def __init__(self, docs, expected_index, page_size=None, error=None):
        self._index = FakeIndex(docs, page_size=page_size, error=error)
        self._expected_index = expected_index
        self.requested = []

    def index(self, name):
        # An implementation that read a hard-coded index name would otherwise
        # pass every test in this file — and reading the wrong index is how one
        # merchant's catalog ends up in another merchant's download.
        self.requested.append(name)
        assert name == self._expected_index, (
            f"export read index {name!r}, expected {self._expected_index!r}"
        )
        return self._index


def _indexer_factory(docs, captured=None, page_size=None, error=None):
    class StubIndexer:
        def __init__(self, tenant_id, storage=None, meili_client=None):
            self.tenant_id = str(tenant_id)
            self.index_name = f"products_{tenant_id}"
            self.meili_client = FakeClient(
                docs, self.index_name, page_size=page_size, error=error
            )
            if captured is not None:
                captured["client"] = self.meili_client
                captured["index"] = self.meili_client._index

    return StubIndexer


async def _tenant_id():
    from app.core.db import async_session_maker
    from app.models import Tenant

    async with async_session_maker() as s:
        return (await s.execute(select(Tenant))).scalars().one().id


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


async def test_export_reads_this_tenants_index(registered, monkeypatch):
    """The test that would catch a cross-tenant data leak."""
    client, token, _ = registered
    from app.api.routes import products

    captured = {}
    monkeypatch.setattr(products, "HybridIndexer", _indexer_factory(DOCS, captured))

    r = await client.get("/products/export", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200, r.text

    tenant_id = await _tenant_id()
    assert captured["client"].requested
    assert set(captured["client"].requested) == {f"products_{tenant_id}"}


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


async def test_export_of_a_never_used_account_is_headers_only(registered, monkeypatch):
    """No upload ever means no Meilisearch index. An empty catalog is an empty
    file, not a 500 on the first thing a curious new merchant clicks."""
    client, token, _ = registered
    from app.api.routes import products
    from app.services.ingestion.mapping import TARGET_FIELDS

    monkeypatch.setattr(
        products, "HybridIndexer", _indexer_factory([], error=index_not_found_error())
    )

    r = await client.get("/products/export", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200, r.text
    assert r.text.strip() == ",".join(TARGET_FIELDS)

    r = await client.get(
        "/products/export",
        params={"format": "json"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200
    assert r.json()["count"] == 0


async def test_export_paginates_past_one_page(registered, monkeypatch):
    """A catalog larger than one Meilisearch page must come back whole. The
    old single request truncated at 10 000 with no error and no way to notice."""
    client, token, _ = registered
    from app.api.routes import products

    docs = [{"id": f"sku-{i}", "title": f"Product {i}"} for i in range(2500)]
    captured = {}
    monkeypatch.setattr(
        products, "HybridIndexer", _indexer_factory(docs, captured, page_size=1000)
    )

    r = await client.get(
        "/products/export",
        params={"format": "json"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["count"] == 2500
    assert [p["id"] for p in body["products"]] == [d["id"] for d in docs]
    # More than one request, and each page asked for a distinct offset.
    calls = captured["index"].calls
    assert len(calls) > 1
    assert [c["offset"] for c in calls] == sorted({c["offset"] for c in calls})


async def test_export_csv_paginates_past_one_page(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import products

    docs = [{"id": f"sku-{i}", "title": f"Product {i}"} for i in range(2500)]
    monkeypatch.setattr(
        products, "HybridIndexer", _indexer_factory(docs, page_size=1000)
    )

    r = await client.get("/products/export", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    rows = list(csv.DictReader(io.StringIO(r.text)))
    assert len(rows) == 2500
    assert rows[-1]["id"] == "sku-2499"


async def test_export_refuses_rather_than_truncating_a_huge_catalog(
    registered, monkeypatch
):
    """If the safety cap is ever hit, the merchant gets a clear error — never a
    short file that looks complete."""
    client, token, _ = registered
    from app.api.routes import products

    monkeypatch.setattr(products, "EXPORT_PAGE_SIZE", 100)
    monkeypatch.setattr(products, "EXPORT_MAX_DOCUMENTS", 200)
    docs = [{"id": f"sku-{i}", "title": f"Product {i}"} for i in range(500)]
    monkeypatch.setattr(products, "HybridIndexer", _indexer_factory(docs, page_size=100))

    r = await client.get("/products/export", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 413, r.text
    assert "support" in r.json()["detail"].lower() or "too large" in r.json()["detail"].lower()


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
