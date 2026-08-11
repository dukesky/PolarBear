import pickle

import faiss
import meilisearch
import meilisearch.errors
import numpy as np

from app.core.config import settings
from app.services.search import cache
from app.services.search.embedding import get_model
from app.services.storage import IndexStorage, get_storage


class HybridIndexer:
    FAISS_FILE = "faiss.bin"
    DOC_MAP_FILE = "doc_map.pkl"

    def __init__(self, tenant_id: str, storage: IndexStorage | None = None, meili_client=None):
        self.tenant_id = str(tenant_id)
        self.storage = storage or get_storage()
        self.meili_client = meili_client or meilisearch.Client(
            settings.MEILI_HOST, settings.MEILI_MASTER_KEY
        )
        self.index_name = f"products_{self.tenant_id}"

    def index_data(self, new_documents: list[dict]) -> None:
        """Merge new docs with existing ones, re-index Meilisearch, rebuild FAISS."""
        existing_docs: list[dict] = []
        try:
            results = self.meili_client.index(self.index_name).get_documents({"limit": 10000})
            existing_docs = [dict(d) for d in results.results]
        except meilisearch.errors.MeilisearchApiError as e:
            # Only treat "index_not_found" as an empty index; re-raise other errors
            if getattr(e, "code", None) != "index_not_found":
                raise
            existing_docs = []  # empty/new index

        merged = {str(d["id"]): d for d in existing_docs}
        for doc in new_documents:
            merged[str(doc["id"])] = doc
        all_documents = list(merged.values())

        index = self.meili_client.index(self.index_name)
        index.update_settings(
            {
                "searchableAttributes": ["title", "description", "brand", "category"],
                "filterableAttributes": ["brand", "category", "price", "tags"],
                "displayedAttributes": ["*"],
            }
        )
        index.add_documents(all_documents)

        texts = [f"{d.get('title', '')} {d.get('description', '')}" for d in all_documents]
        embeddings = np.array(get_model().encode(texts)).astype("float32")
        faiss_index = faiss.IndexFlatL2(embeddings.shape[1])
        faiss_index.add(embeddings)

        self.storage.write(
            self.tenant_id, self.FAISS_FILE, faiss.serialize_index(faiss_index).tobytes()
        )
        self.storage.write(
            self.tenant_id, self.DOC_MAP_FILE, pickle.dumps([d["id"] for d in all_documents])
        )
        cache.invalidate(self.tenant_id)
