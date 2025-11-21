from fastapi import APIRouter, HTTPException, Query
from app.services.search.searcher import HybridSearcher

router = APIRouter()
searcher = HybridSearcher()

@router.get("/")
async def search(q: str = Query(..., min_length=1), limit: int = 20):
    """
    Performs a hybrid search (Keyword + Vector) for the given query.
    """
    try:
        results = searcher.search(q, limit)
        return {
            "query": q,
            "limit": limit,
            "total": len(results),
            "results": results
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
