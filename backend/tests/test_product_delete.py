from tests.test_indexer import FakeModel


class DeletableFakeIndex:
    def __init__(self):
        self.docs: dict[str, dict] = {}

    def get_documents(self, params):
        class R:
            pass

        r = R()
        r.results = list(self.docs.values())
        return r

    def update_settings(self, s):
        pass

    def add_documents(self, docs):
        for d in docs:
            self.docs[str(d["id"])] = d

    def delete_document(self, pid):
        self.docs.pop(str(pid), None)

    def delete_all_documents(self):
        self.docs.clear()


class DeletableFakeClient:
    def __init__(self):
        self.indexes: dict[str, DeletableFakeIndex] = {}

    def index(self, name):
        return self.indexes.setdefault(name, DeletableFakeIndex())


def _indexer(tmp_path, monkeypatch):
    from app.services.search import embedding
    from app.services.search.indexer import HybridIndexer
    from app.services.storage import LocalStorage

    monkeypatch.setattr(embedding, "_model", FakeModel())
    return HybridIndexer(
        "tenant-a",
        storage=LocalStorage(str(tmp_path)),
        meili_client=DeletableFakeClient(),
    )


def test_delete_document_removes_it_and_rebuilds_vectors(tmp_path, monkeypatch):
    import pickle

    from app.services.search import cache
    from app.services.search.indexer import HybridIndexer

    idx = _indexer(tmp_path, monkeypatch)
    idx.index_data(
        [
            {"id": "1", "title": "Blue Mug", "description": ""},
            {"id": "2", "title": "Red Mug", "description": ""},
        ]
    )

    assert idx.delete_document("1") is True

    remaining = idx.meili_client.index(idx.index_name).docs
    assert list(remaining) == ["2"]

    doc_ids = pickle.loads(idx.storage.read("tenant-a", HybridIndexer.DOC_MAP_FILE))
    assert doc_ids == ["2"]
    assert cache.get("tenant-a") is None


def test_delete_missing_document_returns_false(tmp_path, monkeypatch):
    idx = _indexer(tmp_path, monkeypatch)
    idx.index_data([{"id": "1", "title": "Blue Mug", "description": ""}])
    assert idx.delete_document("nope") is False


def test_clear_all_empties_the_catalog_and_vectors(tmp_path, monkeypatch):
    import pickle

    from app.services.search import cache
    from app.services.search.indexer import HybridIndexer

    idx = _indexer(tmp_path, monkeypatch)
    idx.index_data(
        [
            {"id": "1", "title": "Blue Mug", "description": ""},
            {"id": "2", "title": "Red Mug", "description": ""},
        ]
    )

    assert idx.clear_all() == 2
    assert idx.meili_client.index(idx.index_name).docs == {}
    assert pickle.loads(idx.storage.read("tenant-a", HybridIndexer.DOC_MAP_FILE)) == []
    assert cache.get("tenant-a") is None


class RecordingIndexer:
    """Route-level stand-in so the tests don't need Meilisearch."""

    deleted: list = []
    cleared: list = []

    def __init__(self, tenant_id, storage=None, meili_client=None):
        self.tenant_id = str(tenant_id)

    def delete_document(self, pid):
        RecordingIndexer.deleted.append((self.tenant_id, pid))
        return pid != "missing"

    def clear_all(self):
        RecordingIndexer.cleared.append(self.tenant_id)
        return 7


async def test_delete_product_route(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import products

    monkeypatch.setattr(products, "HybridIndexer", RecordingIndexer)
    auth = {"Authorization": f"Bearer {token}"}

    r = await client.delete("/products/abc", headers=auth)
    assert r.status_code == 200, r.text
    assert RecordingIndexer.deleted[-1][1] == "abc"

    r = await client.delete("/products/missing", headers=auth)
    assert r.status_code == 404


async def test_clear_catalog_requires_the_exact_confirm_string(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import products

    monkeypatch.setattr(products, "HybridIndexer", RecordingIndexer)
    auth = {"Authorization": f"Bearer {token}"}

    r = await client.request("DELETE", "/products/", json={"confirm": "yes"}, headers=auth)
    assert r.status_code == 400

    r = await client.request(
        "DELETE", "/products/", json={"confirm": "delete all products"}, headers=auth
    )
    assert r.status_code == 200
    assert r.json()["deleted"] == 7


async def test_delete_requires_admin_credentials(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import products

    monkeypatch.setattr(products, "HybridIndexer", RecordingIndexer)
    keys = (
        await client.get("/tenant/keys", headers={"Authorization": f"Bearer {token}"})
    ).json()

    assert (await client.delete("/products/abc")).status_code == 401
    r = await client.delete("/products/abc", headers={"X-PolarBear-Key": keys["search"]["key"]})
    assert r.status_code == 403


def test_clear_all_propagates_a_meilisearch_failure(tmp_path, monkeypatch):
    """A delete endpoint must not report success when nothing was deleted."""
    import pytest

    from app.services.search import embedding
    from app.services.search.indexer import HybridIndexer
    from app.services.storage import LocalStorage
    from tests.test_indexer import FakeModel

    monkeypatch.setattr(embedding, "_model", FakeModel())

    class BrokenIndex:
        def get_documents(self, params):
            class R:
                pass

            r = R()
            r.results = [{"id": "1", "title": "Blue Mug"}]
            return r

        def update_settings(self, s):
            pass

        def add_documents(self, docs):
            pass

        def delete_all_documents(self):
            raise RuntimeError("meilisearch unreachable")

    class BrokenClient:
        def index(self, name):
            return BrokenIndex()

    idx = HybridIndexer(
        "tenant-a", storage=LocalStorage(str(tmp_path)), meili_client=BrokenClient()
    )
    with pytest.raises(RuntimeError, match="meilisearch unreachable"):
        idx.clear_all()
