import uuid

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query

from app.core.tenancy import resolve_search_tenant
from app.services.analytics_db import log_search
from app.services.search.searcher import HybridSearcher

router = APIRouter()


@router.get("/")
async def search(
    background_tasks: BackgroundTasks,
    q: str = Query(..., min_length=1),
    limit: int = 20,
    tenant_id: uuid.UUID = Depends(resolve_search_tenant),
):
    """Hybrid search scoped to the tenant resolved from the search key or JWT."""
    searcher = HybridSearcher(str(tenant_id))
    try:
        results = searcher.search(q, limit)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    background_tasks.add_task(log_search, tenant_id, q, len(results))
    return {"query": q, "limit": limit, "total": len(results), "results": results}
