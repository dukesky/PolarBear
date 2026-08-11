import pickle
import numpy as np
import pytest


class FakeModel:
    def encode(self, texts):
        return np.array(
            [[(hash(t) % 97) / 97.0] * 8 for t in texts], dtype="float32"
        )


class FakeMeiliIndex:
    def __init__(self):
        self.docs: dict[str, dict] = {}
        self.settings = None

    def get_documents(self, params):
        class R:
            pass

        r = R()
        r.results = list(self.docs.values())
        return r

    def update_settings(self, s):
        self.settings = s

    def add_documents(self, docs):
        for d in docs:
            self.docs[str(d["id"])] = d


class FakeMeiliClient:
    def __init__(self):
        self.indexes: dict[str, FakeMeiliIndex] = {}

    def index(self, name):
        return self.indexes.setdefault(name, FakeMeiliIndex())


def test_indexer_is_tenant_scoped_and_persists_to_storage(tmp_path, monkeypatch):
    from app.services.search import embedding

    monkeypatch.setattr(embedding, "_model", FakeModel())

    from app.services.search.indexer import HybridIndexer
    from app.services.storage import LocalStorage

    storage = LocalStorage(base_dir=str(tmp_path))
    meili = FakeMeiliClient()
    idx = HybridIndexer("tenant-a", storage=storage, meili_client=meili)

    assert idx.index_name == "products_tenant-a"

    idx.index_data([{"id": "1", "title": "Red Shoe", "description": "running"}])

    # Meilisearch got the doc in the tenant-scoped index
    assert "1" in meili.indexes["products_tenant-a"].docs

    # FAISS + doc_map persisted through storage under the tenant prefix
    assert storage.read("tenant-a", HybridIndexer.FAISS_FILE) is not None
    doc_ids = pickle.loads(storage.read("tenant-a", HybridIndexer.DOC_MAP_FILE))
    assert doc_ids == ["1"]

    # Nothing leaked into another tenant's space
    assert storage.read("tenant-b", HybridIndexer.FAISS_FILE) is None


def test_indexer_invalidates_cache(tmp_path, monkeypatch):
    from app.services.search import cache, embedding

    monkeypatch.setattr(embedding, "_model", FakeModel())
    from app.services.search.indexer import HybridIndexer
    from app.services.storage import LocalStorage

    cache.put("tenant-a", "stale-index", ["stale"])
    idx = HybridIndexer("tenant-a", storage=LocalStorage(str(tmp_path)), meili_client=FakeMeiliClient())
    idx.index_data([{"id": "1", "title": "X", "description": ""}])
    assert cache.get("tenant-a") is None


class FakeMeiliIndexWithError:
    """Fake Meilisearch index that raises an error on get_documents."""
    def __init__(self):
        self.settings = None

    def get_documents(self, params):
        raise RuntimeError("connection refused")

    def update_settings(self, s):
        self.settings = s

    def add_documents(self, docs):
        pass


class FakeMeiliClientWithError:
    """Fake Meilisearch client that returns an index that raises on get_documents."""
    def index(self, name):
        return FakeMeiliIndexWithError()


def test_indexer_propagates_non_index_not_found_errors(tmp_path, monkeypatch):
    """Verify that real errors (e.g., connection refused) are propagated, not silently ignored."""
    from app.services.search import embedding
    monkeypatch.setattr(embedding, "_model", FakeModel())

    from app.services.search.indexer import HybridIndexer
    from app.services.storage import LocalStorage

    meili = FakeMeiliClientWithError()
    idx = HybridIndexer("tenant-a", storage=LocalStorage(str(tmp_path)), meili_client=meili)

    # Attempting to index should raise the RuntimeError, not silently proceed
    with pytest.raises(RuntimeError, match="connection refused"):
        idx.index_data([{"id": "1", "title": "X", "description": ""}])
