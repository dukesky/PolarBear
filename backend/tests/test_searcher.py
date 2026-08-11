import pickle
import numpy as np
from tests.test_indexer import FakeMeiliClient, FakeModel


class SearchableFakeIndex:
    """Extends the fake with search/get_document used by the searcher."""

    def __init__(self, docs):
        self.docs = docs

    def search(self, query, params):
        hits = [d for d in self.docs.values() if query.lower() in d["title"].lower()]
        return {"hits": hits[: params.get("limit", 20)]}

    def get_document(self, pid):
        if str(pid) in self.docs:
            return self.docs[str(pid)]
        raise KeyError(pid)


class SearchableFakeClient:
    def __init__(self, docs):
        self._index = SearchableFakeIndex(docs)

    def index(self, name):
        self.last_index_name = name
        return self._index


def _build_tenant_index(tmp_path, tenant_id, docs, monkeypatch):
    """Index docs for a tenant using the real indexer with fakes."""
    from app.services.search import embedding

    monkeypatch.setattr(embedding, "_model", FakeModel())
    from app.services.search.indexer import HybridIndexer
    from app.services.storage import LocalStorage

    storage = LocalStorage(str(tmp_path))
    fake = FakeMeiliClient()
    HybridIndexer(tenant_id, storage=storage, meili_client=fake).index_data(docs)
    return storage


def test_search_returns_tenant_results(tmp_path, monkeypatch):
    docs = {
        "1": {"id": "1", "title": "Red Running Shoe", "description": "fast"},
        "2": {"id": "2", "title": "Blue Hat", "description": "warm"},
    }
    storage = _build_tenant_index(tmp_path, "tenant-a", list(docs.values()), monkeypatch)

    from app.services.search.searcher import HybridSearcher

    s = HybridSearcher("tenant-a", storage=storage, meili_client=SearchableFakeClient(docs))
    results = s.search("shoe", limit=5)
    ids = [r["id"] for r in results]
    assert "1" in ids
    assert s.meili_client.last_index_name == "products_tenant-a"


def test_search_uses_cache_after_first_load(tmp_path, monkeypatch):
    docs = {"1": {"id": "1", "title": "Shoe", "description": ""}}
    storage = _build_tenant_index(tmp_path, "tenant-a", list(docs.values()), monkeypatch)

    from app.services.search import cache
    from app.services.search.searcher import HybridSearcher

    s = HybridSearcher("tenant-a", storage=storage, meili_client=SearchableFakeClient(docs))
    s.search("shoe")
    assert cache.get("tenant-a") is not None  # loaded and cached

    reads = []
    original_read = storage.read
    monkeypatch.setattr(
        storage, "read", lambda t, n: (reads.append(n), original_read(t, n))[1]
    )
    s.search("shoe")
    assert reads == []  # second search served from cache


def test_search_degrades_to_keyword_only_when_storage_fails(tmp_path, monkeypatch):
    docs = {"1": {"id": "1", "title": "Shoe", "description": ""}}

    from app.services.search import embedding, cache
    monkeypatch.setattr(embedding, "_model", FakeModel())
    assert cache.get("tenant-a") is None  # verify no stale cache entry from prior test

    class BrokenStorage:
        def read(self, t, n):
            raise RuntimeError("gcs down")

        def write(self, t, n, d):
            raise RuntimeError("gcs down")

        def write_public(self, t, n, d, c):
            raise RuntimeError("gcs down")

    from app.services.search.searcher import HybridSearcher

    s = HybridSearcher("tenant-a", storage=BrokenStorage(), meili_client=SearchableFakeClient(docs))
    results = s.search("shoe")  # must NOT raise
    assert [r["id"] for r in results] == ["1"]
