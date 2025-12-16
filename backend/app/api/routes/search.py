from fastapi import APIRouter, HTTPException, Query, BackgroundTasks
from app.services.search.searcher import HybridSearcher
from app.core.database import log_search

router = APIRouter()
_searcher = None

def get_searcher():
    global _searcher
    if _searcher is None:
        print("Initializing HybridSearcher (Lazy)...")
        _searcher = HybridSearcher()
    return _searcher

@router.get("/")
async def search(background_tasks: BackgroundTasks, q: str = Query(..., min_length=1), limit: int = 20):
    """
    Performs a hybrid search (Keyword + Vector) for the given query.
    """
    searcher = get_searcher()
    try:
        results = searcher.search(q, limit)
        
        # Log search asynchronously
        background_tasks.add_task(log_search, q, len(results))
        
        return {
            "query": q,
            "limit": limit,
            "total": len(results),
            "results": results
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
