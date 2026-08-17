import io
import json

SHOPIFY_CSV = (
    b"Handle,Title,Body (HTML),Vendor,Type,Tags,Variant SKU,Variant Price,Image Src\n"
    b"blue-mug,Blue Mug,<p>Ceramic <b>mug</b></p>,MyShop,Drinkware,\"mug,gift\","
    b"SKU-1,$12.00,https://ex.com/1.jpg\n"
    b"red-mug,Red Mug,<p>Second mug</p>,MyShop,Drinkware,\"mug\",SKU-2,$14.00,"
    b"https://ex.com/2.jpg\n"
)
PLAIN_CSV = b"Product Name,Price\nWool Socks,9.50\nWool Socks,9.50\n"


class RecordingIndexer:
    last = None

    def __init__(self, tenant_id, storage=None, meili_client=None):
        self.tenant_id = str(tenant_id)

    def index_data(self, docs):
        RecordingIndexer.last = docs


async def test_preview_guesses_shopify_columns(registered):
    client, token, _ = registered
    files = {"file": ("export.csv", io.BytesIO(SHOPIFY_CSV), "text/csv")}
    r = await client.post(
        "/ingest/preview", files=files, headers={"Authorization": f"Bearer {token}"}
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["row_count"] == 2
    assert len(body["sample_rows"]) == 2
    assert body["columns"][0] == "Handle"
    assert body["guess"]["title"] == "Title"
    assert body["guess"]["price"] == "Variant Price"
    assert body["guess"]["image_url"] == "Image Src"


async def test_preview_requires_auth(client):
    files = {"file": ("export.csv", io.BytesIO(SHOPIFY_CSV), "text/csv")}
    assert (await client.post("/ingest/preview", files=files)).status_code == 401


async def test_preview_rejects_empty_file(registered):
    client, token, _ = registered
    files = {"file": ("empty.csv", io.BytesIO(b""), "text/csv")}
    r = await client.post(
        "/ingest/preview", files=files, headers={"Authorization": f"Bearer {token}"}
    )
    assert r.status_code == 400


async def test_upload_with_mapping_indexes_clean_documents(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import ingestion

    monkeypatch.setattr(ingestion, "HybridIndexer", RecordingIndexer)
    mapping = {"id": "Handle", "title": "Title", "description": "Body (HTML)",
               "price": "Variant Price", "category": "Type", "brand": "Vendor",
               "tags": "Tags", "image_url": "Image Src", "url": None}
    files = {"file": ("export.csv", io.BytesIO(SHOPIFY_CSV), "text/csv")}
    r = await client.post(
        "/ingest/upload",
        files=files,
        data={"mapping": json.dumps(mapping)},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200, r.text
    docs = RecordingIndexer.last
    assert [d["id"] for d in docs] == ["blue-mug", "red-mug"]
    assert docs[0]["title"] == "Blue Mug"
    assert "<" not in docs[0]["description"]
    assert docs[0]["price"] == 12.0
    assert "Vendor" not in docs[0]  # source columns dropped


async def test_upload_without_id_column_generates_ids(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import ingestion

    monkeypatch.setattr(ingestion, "HybridIndexer", RecordingIndexer)
    mapping = {"title": "Product Name", "price": "Price"}
    files = {"file": ("plain.csv", io.BytesIO(PLAIN_CSV), "text/csv")}
    r = await client.post(
        "/ingest/upload",
        files=files,
        data={"mapping": json.dumps(mapping)},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200, r.text
    assert [d["id"] for d in RecordingIndexer.last] == ["wool-socks", "wool-socks-2"]


async def test_upload_with_bad_mapping_is_400(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import ingestion

    monkeypatch.setattr(ingestion, "HybridIndexer", RecordingIndexer)
    auth = {"Authorization": f"Bearer {token}"}

    files = {"file": ("plain.csv", io.BytesIO(PLAIN_CSV), "text/csv")}
    r = await client.post(
        "/ingest/upload", files=files,
        data={"mapping": json.dumps({"title": "Nope"})}, headers=auth,
    )
    assert r.status_code == 400

    files = {"file": ("plain.csv", io.BytesIO(PLAIN_CSV), "text/csv")}
    r = await client.post(
        "/ingest/upload", files=files,
        data={"mapping": json.dumps({"price": "Price"})}, headers=auth,
    )
    assert r.status_code == 400  # title unmapped


def test_read_rows_uniquifies_duplicate_headers_instead_of_failing():
    from app.services.ingestion.parser import DataParser

    columns, rows = DataParser.read_rows(b"Title,Title,Price\nA,B,1\n", "x.csv")
    assert columns == ["Title", "Title.1", "Price"]
    assert rows[0]["Title"] == "A"
    assert rows[0]["Title.1"] == "B"
