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
