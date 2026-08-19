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

        self._rebuild_vectors(all_documents)

    def _rebuild_vectors(self, documents: list[dict]) -> None:
        """Write the vector artifacts for exactly these documents.

        Callers that already know the surviving set must not re-read Meilisearch:
        its deletes are queued asynchronously, so a re-read can still return a
        product that is on its way out.
        """
        if not documents:
            self._clear_vectors()
            cache.invalidate(self.tenant_id)
            return
        texts = [f"{d.get('title', '')} {d.get('description', '')}" for d in documents]
        embeddings = np.array(get_model().encode(texts)).astype("float32")
        faiss_index = faiss.IndexFlatL2(embeddings.shape[1])
        faiss_index.add(embeddings)
        self.storage.write(
            self.tenant_id, self.FAISS_FILE, faiss.serialize_index(faiss_index).tobytes()
        )
        self.storage.write(
            self.tenant_id, self.DOC_MAP_FILE, pickle.dumps([d["id"] for d in documents])
        )
        cache.invalidate(self.tenant_id)

    def _fetch_all(self) -> list[dict]:
        """Every document currently in this tenant's keyword index."""
        try:
            results = self.meili_client.index(self.index_name).get_documents({"limit": 10000})
            return [dict(d) for d in results.results]
        except meilisearch.errors.MeilisearchApiError as e:
            if getattr(e, "code", None) != "index_not_found":
                raise
            return []

    def delete_document(self, product_id: str) -> bool:
        """Remove one product. Returns False when it wasn't there.

        The FAISS index is positional, so it must be rebuilt from what remains -
        deleting only from Meilisearch would leave vectors pointing at a product
        that no longer exists.
        """
        existing = self._fetch_all()
        remaining = [d for d in existing if str(d["id"]) != str(product_id)]
        if len(remaining) == len(existing):
            return False

        # Meilisearch first, then the vector rebuild. If the rebuild fails the
        # route surfaces a 500 and the artifacts briefly describe the old set;
        # a re-run of the delete or the next upload repairs them. Full atomicity
        # across two stores would need a redesign we have not taken on.
        self.meili_client.index(self.index_name).delete_document(str(product_id))
        self._rebuild_vectors(remaining)
        return True

    def clear_all(self) -> int:
        """Remove every product and the vector artifacts. Returns the count removed."""
        count = len(self._fetch_all())
        self.meili_client.index(self.index_name).delete_all_documents()
        self._clear_vectors()
        cache.invalidate(self.tenant_id)
        return count

    def delete_index(self) -> None:
        """Remove the tenant's index entirely, not just its documents."""
        try:
            self.meili_client.delete_index(self.index_name)
        except meilisearch.errors.MeilisearchApiError as e:
            if getattr(e, "code", None) != "index_not_found":
                raise

    def _clear_vectors(self) -> None:
        """Empty vector artifacts so a search finds nothing rather than ghosts."""
        self.storage.write(self.tenant_id, self.FAISS_FILE, b"")
        self.storage.write(self.tenant_id, self.DOC_MAP_FILE, pickle.dumps([]))
