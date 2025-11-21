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

    def index_data(self, documents: list[dict]):
        """
        Performs hybrid indexing:
        1. Send documents to Meilisearch (Keyword)
        2. Generate embeddings and build FAISS index (Vector)
        """
        # 1. Meilisearch Indexing
        print(f"Indexing {len(documents)} documents to Meilisearch...")
        index = self.meili_client.index(self.index_name)
        index.update_settings({
            'searchableAttributes': ['title', 'description', 'brand', 'category'],
            'filterableAttributes': ['brand', 'category', 'price', 'tags']
        })
        index.add_documents(documents)

        # 2. Vector Indexing (FAISS)
        print("Generating embeddings...")
        texts = [f"{doc.get('title', '')} {doc.get('description', '')}" for doc in documents]
        embeddings = self.model.encode(texts)
        
        # Convert to float32 for FAISS
        embeddings = np.array(embeddings).astype('float32')
        dimension = embeddings.shape[1]

        print(f"Building FAISS index with dimension {dimension}...")
        # Using FlatL2 for exact search (good for small/medium datasets < 100k)
        faiss_index = faiss.IndexFlatL2(dimension)
        faiss_index.add(embeddings)

        # Save Index
        faiss.write_index(faiss_index, self.faiss_index_path)
        
        # Save ID Mapping (FAISS internal ID -> Document ID)
        doc_ids = [doc['id'] for doc in documents]
        with open(self.doc_map_path, 'wb') as f:
            pickle.dump(doc_ids, f)
            
        print("Hybrid indexing complete.")

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
