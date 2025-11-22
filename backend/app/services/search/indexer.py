import meilisearch
import faiss
import numpy as np
from sentence_transformers import SentenceTransformer
from app.core.config import settings
import os
import pickle

class HybridIndexer:
    def __init__(self):
        # Meilisearch Client
        self.meili_client = meilisearch.Client(settings.MEILI_HOST, settings.MEILI_MASTER_KEY)
        self.index_name = "products"
        
        # Embedding Model
        # Using a lightweight model for CPU efficiency
        self.model = SentenceTransformer('all-MiniLM-L6-v2')
        
        # FAISS Index Path
        self.faiss_index_path = "faiss_index.bin"
        self.doc_map_path = "doc_map.pkl" # Maps FAISS ID to Product ID

    def index_data(self, new_documents: list[dict]):
        """
        Performs hybrid indexing with Merge & Rebuild strategy:
        1. Fetch ALL existing documents from Meilisearch.
        2. Merge with new_documents (deduplicate by ID).
        3. Re-index ALL documents to Meilisearch.
        4. Re-build FAISS index from scratch with ALL documents.
        """
        print(f"Received {len(new_documents)} new documents.")
        
        # 1. Fetch Existing Documents
        existing_docs = []
        try:
            # For MVP, we assume < 10k items. In prod, use pagination.
            results = self.meili_client.index(self.index_name).get_documents({'limit': 10000})
            # Meilisearch python client v0.20+ returns an object with .results
            # Older versions might return list. Let's handle object.
            if hasattr(results, 'results'):
                existing_docs = [dict(d) for d in results.results]
            else:
                existing_docs = results # Fallback if it returns list
        except Exception as e:
            print(f"Could not fetch existing docs (might be empty index): {e}")
            existing_docs = []

        print(f"Found {len(existing_docs)} existing documents.")

        # 2. Merge Documents
        # Create a dict keyed by ID for easy merging
        doc_map = {str(d['id']): d for d in existing_docs}
        
        # Update/Add new documents
        for doc in new_documents:
            doc_id = str(doc['id'])
            doc_map[doc_id] = doc # Overwrite if exists, add if new
            
        all_documents = list(doc_map.values())
        print(f"Total documents after merge: {len(all_documents)}")

        # 3. Meilisearch Indexing (Re-index ALL)
        print("Indexing all documents to Meilisearch...")
        index = self.meili_client.index(self.index_name)
        index.update_settings({
            'searchableAttributes': ['title', 'description', 'brand', 'category'],
            'filterableAttributes': ['brand', 'category', 'price', 'tags'],
            'displayedAttributes': ['*'] # Ensure all attributes are returned
        })
        # deleteAll is optional but cleaner to avoid ghosts if we were removing items. 
        # But here we are just adding/updating. add_documents upserts.
        index.add_documents(all_documents)

        # 4. Vector Indexing (FAISS) - Rebuild from scratch
        print("Generating embeddings for all documents...")
        texts = [f"{doc.get('title', '')} {doc.get('description', '')}" for doc in all_documents]
        embeddings = self.model.encode(texts)
        
        # Convert to float32 for FAISS
        embeddings = np.array(embeddings).astype('float32')
        dimension = embeddings.shape[1]

        print(f"Rebuilding FAISS index with dimension {dimension}...")
        faiss_index = faiss.IndexFlatL2(dimension)
        faiss_index.add(embeddings)

        # Save Index
        faiss.write_index(faiss_index, self.faiss_index_path)
        
        # Save ID Mapping (FAISS internal ID -> Document ID)
        # Order matches 'all_documents' list order
        doc_ids = [doc['id'] for doc in all_documents]
        with open(self.doc_map_path, 'wb') as f:
            pickle.dump(doc_ids, f)
            
        print("Hybrid indexing (Merge & Rebuild) complete.")

    def search_vectors(self, query: str, k: int = 10):
        """
        Search FAISS index for query
        """
        if not os.path.exists(self.faiss_index_path):
            return []
            
        index = faiss.read_index(self.faiss_index_path)
        query_vector = self.model.encode([query]).astype('float32')
        
        distances, indices = index.search(query_vector, k)
        
        # Load ID mapping
        with open(self.doc_map_path, 'rb') as f:
            doc_ids = pickle.load(f)
            
        results = []
        for i, idx in enumerate(indices[0]):
            if idx != -1 and idx < len(doc_ids):
                results.append({
                    "id": doc_ids[idx],
                    "score": float(distances[0][i])
                })
                
        return results
