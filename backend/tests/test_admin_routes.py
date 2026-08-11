import io


class RecordingIndexer:
    instances: list = []

    def __init__(self, tenant_id, storage=None, meili_client=None):
        self.tenant_id = str(tenant_id)
        RecordingIndexer.instances.append(self)

    def index_data(self, docs):
        self.docs = docs


CSV = b"id,title,description\n1,Red Shoe,fast\n"


async def test_ingest_requires_auth(client):
    files = {"file": ("p.csv", io.BytesIO(CSV), "text/csv")}
    r = await client.post("/ingest/upload", files=files)
    assert r.status_code == 401


async def test_search_key_rejected_on_admin_route(registered):
    client, token, _ = registered
    keys = (await client.get("/tenant/keys", headers={"Authorization": f"Bearer {token}"})).json()
    files = {"file": ("p.csv", io.BytesIO(CSV), "text/csv")}
    r = await client.post(
        "/ingest/upload", files=files, headers={"X-PolarBear-Key": keys["search"]["key"]}
    )
    assert r.status_code == 403


async def test_ingest_scopes_to_tenant(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import ingestion

    monkeypatch.setattr(ingestion, "HybridIndexer", RecordingIndexer)
    files = {"file": ("p.csv", io.BytesIO(CSV), "text/csv")}
    r = await client.post(
        "/ingest/upload", files=files, headers={"Authorization": f"Bearer {token}"}
    )
    assert r.status_code == 200, r.text
    assert len(RecordingIndexer.instances[-1].docs) == 1
    assert RecordingIndexer.instances[-1].tenant_id  # a real tenant uuid string


async def test_analytics_scoped_and_authed(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}

    assert (await client.get("/analytics/stats")).status_code == 401

    r = await client.post(
        "/analytics/track",
        json={"type": "click", "product_id": "1", "title": "Red Shoe"},
        headers=auth,
    )
    assert r.status_code == 200

    r = await client.get("/analytics/stats", headers=auth)
    assert r.status_code == 200
    body = r.json()
    assert body["product_stats"][0]["product_id"] == "1"
    assert body["product_stats"][0]["clicks"] == 1
