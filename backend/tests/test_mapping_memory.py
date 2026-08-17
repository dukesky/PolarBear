import io
import json

SHOPIFY_CSV = (
    b"Handle,Title,Body (HTML),Variant Price\n"
    b"blue-mug,Blue Mug,<p>Mug</p>,$12.00\n"
)
OTHER_CSV = b"Product Name,Price\nWool Socks,9.50\n"


class NoopIndexer:
    def __init__(self, tenant_id, storage=None, meili_client=None):
        pass

    def index_data(self, docs):
        pass


async def test_saved_mapping_is_reused_for_a_matching_file(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import ingestion

    monkeypatch.setattr(ingestion, "HybridIndexer", NoopIndexer)
    auth = {"Authorization": f"Bearer {token}"}
    mapping = {"id": "Handle", "title": "Title", "description": "Body (HTML)",
               "price": "Variant Price"}

    files = {"file": ("export.csv", io.BytesIO(SHOPIFY_CSV), "text/csv")}
    r = await client.post("/ingest/upload", files=files,
                          data={"mapping": json.dumps(mapping)}, headers=auth)
    assert r.status_code == 200, r.text

    files = {"file": ("export.csv", io.BytesIO(SHOPIFY_CSV), "text/csv")}
    r = await client.post("/ingest/preview", files=files, headers=auth)
    assert r.json()["guess"]["description"] == "Body (HTML)"


async def test_saved_mapping_ignored_when_columns_do_not_match(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import ingestion

    monkeypatch.setattr(ingestion, "HybridIndexer", NoopIndexer)
    auth = {"Authorization": f"Bearer {token}"}
    mapping = {"id": "Handle", "title": "Title"}

    files = {"file": ("export.csv", io.BytesIO(SHOPIFY_CSV), "text/csv")}
    await client.post("/ingest/upload", files=files,
                      data={"mapping": json.dumps(mapping)}, headers=auth)

    files = {"file": ("other.csv", io.BytesIO(OTHER_CSV), "text/csv")}
    r = await client.post("/ingest/preview", files=files, headers=auth)
    # Falls back to guessing against the new file's own columns
    assert r.json()["guess"]["title"] == "Product Name"
