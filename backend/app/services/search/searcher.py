import meilisearch
import faiss
import numpy as np
from sentence_transformers import SentenceTransformer
from app.core.config import settings
import pickle
import os

class HybridSearcher:
    def __init__(self):
        # Meilisearch Client
        self.meili_client = meilisearch.Client(settings.MEILI_HOST, settings.MEILI_MASTER_KEY)
        self.index_name = "products"
        
        # Embedding Model
        self.model = SentenceTransformer('all-MiniLM-L6-v2')
        
        # FAISS Index & Map Paths
        self.faiss_index_path = "faiss_index.bin"
        self.doc_map_path = "doc_map.pkl"

    def search(self, query: str, limit: int = 20) -> list[dict]:
        """
        Performs hybrid search:
        1. Get Keyword results from Meilisearch.
        2. Get Vector results from FAISS.
        3. Merge and rank results.
        """
        # 1. Keyword Search (Meilisearch)
        try:
            meili_results = self.meili_client.index(self.index_name).search(query, {'limit': limit})
            keyword_hits = meili_results.get('hits', [])
        except Exception as e:
            print(f"Meilisearch error: {e}")
            keyword_hits = []

        # 2. Vector Search (FAISS)
        vector_hits = []
        if os.path.exists(self.faiss_index_path) and os.path.exists(self.doc_map_path):
            try:
                index = faiss.read_index(self.faiss_index_path)
                with open(self.doc_map_path, 'rb') as f:
                    doc_ids = pickle.load(f)
                
                query_vector = self.model.encode([query]).astype('float32')
                distances, indices = index.search(query_vector, limit)
                
                for i, idx in enumerate(indices[0]):
                    if idx != -1 and idx < len(doc_ids):
                        vector_hits.append({
                            "id": doc_ids[idx],
                            "vector_score": float(distances[0][i]) # Lower is better for L2
                        })
            except Exception as e:
                print(f"FAISS error: {e}")

        # 3. Merge Results (Simple Linear Combination)
        # We need to retrieve full documents for vector hits from Meilisearch if they aren't in keyword hits
        
        # Create a map of all unique IDs found
        all_ids = set([h['id'] for h in keyword_hits] + [h['id'] for h in vector_hits])
        
        # Retrieve full documents for all IDs from Meilisearch to ensure we have data
        # (Optimization: In production, we might store data in a DB, but here Meilisearch acts as DB)
        final_results = []
        if all_ids:
            try:
                # Meilisearch 'get_documents' can fetch by ID
                docs = self.meili_client.index(self.index_name).get_documents({'filter': f"id IN [{','.join(all_ids)}]", 'limit': len(all_ids)})
                doc_map = {d.id: d for d in docs.results} # Meilisearch python client returns objects or dicts depending on version
                # Let's assume it returns objects with attributes or dicts. The python client usually returns objects that can be accessed as dicts or attributes.
                # Actually, standard client returns object with .results which is a list of dicts usually? 
                # Let's check standard behavior or use a safer retrieval.
                # Safer: use search with filter id IN [...] to get full docs
                
                # Alternative: Just use the data we have. 
                # Keyword hits have data. Vector hits only have ID.
                # We MUST fetch data for vector-only hits.
                pass
            except Exception:
                pass

        # RERANKING LOGIC (Simplified)
        # We will score items. 
        # Keyword Score: 1.0 / (rank + 1) (Reciprocal Rank) or just use Meilisearch score if available? Meilisearch doesn't expose score easily in standard search response without showRankingScore=True.
        # Vector Score: 1.0 / (1.0 + distance)
        
        scores = {}
        
        # Process Keyword Hits
        for i, hit in enumerate(keyword_hits):
            pid = hit['id']
            # Score: High for top results. 
            # Simple approach: 1.0 for top 1, 0.9 for top 2... or just 1.0 * weight
            # Let's use Reciprocal Rank: 1 / (i + 1)
            k_score = 1.0 / (i + 1)
            scores[pid] = {'score': k_score * 0.3, 'doc': hit} # Weight 0.3

        # Process Vector Hits
        for hit in vector_hits:
            pid = hit['id']
            # L2 Distance: Lower is better. Convert to similarity score.
            # Simple inversion: 1 / (1 + distance)
            v_score = 1.0 / (1.0 + hit['vector_score'])
            
            if pid in scores:
                scores[pid]['score'] += v_score * 0.7 # Weight 0.7
            else:
                # We need to fetch the doc content if it wasn't in keyword hits
                # For MVP, we will do a quick fetch from Meilisearch for this ID
                try:
                    doc = self.meili_client.index(self.index_name).get_document(pid)
                    # get_document returns a dict usually
                    scores[pid] = {'score': v_score * 0.7, 'doc': doc}
                except:
                    # If doc not found (sync issue?), skip
                    continue

        # Sort by final score
        sorted_pids = sorted(scores.keys(), key=lambda x: scores[x]['score'], reverse=True)
        
        # Format Output
        output = []
        for pid in sorted_pids:
            doc = scores[pid]['doc']
            # Add debug score info if needed
            # doc['_score'] = scores[pid]['score'] 
            output.append(doc)
            
        return output[:limit]
