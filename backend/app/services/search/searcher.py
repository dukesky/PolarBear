import pickle

import faiss
import meilisearch
import numpy as np

from app.core.config import settings
from app.services.search import cache
from app.services.search.embedding import get_model
from app.services.search.indexer import HybridIndexer
from app.services.storage import IndexStorage, get_storage

KEYWORD_WEIGHT = 0.3
VECTOR_WEIGHT = 0.7


class HybridSearcher:
    def __init__(self, tenant_id: str, storage: IndexStorage | None = None, meili_client=None):
        self.tenant_id = str(tenant_id)
        self.storage = storage or get_storage()
        self.meili_client = meili_client or meilisearch.Client(
            settings.MEILI_HOST, settings.MEILI_MASTER_KEY
        )
        self.index_name = f"products_{self.tenant_id}"

    def _load_faiss(self):
        """Return (faiss_index, doc_ids) from cache or storage; None if unavailable."""
        cached = cache.get(self.tenant_id)
        if cached is not None:
            return cached
        try:
            index_bytes = self.storage.read(self.tenant_id, HybridIndexer.FAISS_FILE)
            map_bytes = self.storage.read(self.tenant_id, HybridIndexer.DOC_MAP_FILE)
            if index_bytes is None or map_bytes is None:
                return None
            index = faiss.deserialize_index(np.frombuffer(index_bytes, dtype="uint8"))
            doc_ids = pickle.loads(map_bytes)
            cache.put(self.tenant_id, index, doc_ids)
            return index, doc_ids
        except Exception as e:
            print(f"WARNING: vector index unavailable for {self.tenant_id}: {e}")
            return None

    def search(self, query: str, limit: int = 20) -> list[dict]:
        # 1. Keyword search (Meilisearch)
        try:
            keyword_hits = self.meili_client.index(self.index_name).search(
                query, {"limit": limit}
            ).get("hits", [])
        except Exception as e:
            print(f"Meilisearch error for {self.tenant_id}: {e}")
            keyword_hits = []

        # 2. Vector search (FAISS) — degrade silently to keyword-only on failure
        vector_hits = []
        loaded = self._load_faiss()
        if loaded is not None:
            index, doc_ids = loaded
            try:
                query_vector = get_model().encode([query])
                query_vector = np.array(query_vector).astype("float32")
                distances, indices = index.search(query_vector, limit)
                for dist, idx in zip(distances[0], indices[0]):
                    if idx != -1 and idx < len(doc_ids):
                        vector_hits.append({"id": doc_ids[idx], "distance": float(dist)})
            except Exception as e:
                print(f"FAISS search error for {self.tenant_id}: {e}")

        # 3. Fuse scores
        scores: dict[str, dict] = {}
        for i, hit in enumerate(keyword_hits):
            pid = str(hit["id"])
            scores[pid] = {"score": (1.0 / (i + 1)) * KEYWORD_WEIGHT, "doc": hit}

        for hit in vector_hits:
            pid = str(hit["id"])
            v_score = (1.0 / (1.0 + hit["distance"])) * VECTOR_WEIGHT
            if pid in scores:
                scores[pid]["score"] += v_score
            else:
                try:
                    doc = self.meili_client.index(self.index_name).get_document(pid)
                    scores[pid] = {"score": v_score, "doc": dict(doc) if not isinstance(doc, dict) else doc}
                except Exception:
                    continue  # doc missing from keyword index; skip

        ranked = sorted(scores.values(), key=lambda s: s["score"], reverse=True)
        return [s["doc"] for s in ranked][:limit]
