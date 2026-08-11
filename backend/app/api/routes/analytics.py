import uuid

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import desc, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import get_async_session
from app.core.tenancy import get_current_tenant, resolve_search_tenant
from app.models import ProductStat, SearchLog, Tenant
from app.services.analytics_db import track_product_event

router = APIRouter()


class TrackEvent(BaseModel):
    type: str  # 'click' | 'order'
    product_id: str
    title: str


@router.post("/track")
async def track_event(event: TrackEvent, tenant_id: uuid.UUID = Depends(resolve_search_tenant)):
    """Track a click/order. Auth: public search key, admin key, or JWT —
    callable from merchant sites (write-only, tenant-scoped)."""
    if event.type not in ("click", "order"):
        raise HTTPException(status_code=400, detail="Invalid event type")
    await track_product_event(tenant_id, event.type, event.product_id, event.title)
    return {"status": "success"}


@router.get("/stats")
async def get_analytics(
    tenant: Tenant = Depends(get_current_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    tid = tenant.id
    total = (
        await session.execute(
            select(func.count()).select_from(SearchLog).where(SearchLog.tenant_id == tid)
        )
    ).scalar_one()

    top_q = select(SearchLog.query, func.count().label("count")).where(
        SearchLog.tenant_id == tid
    ).group_by(SearchLog.query).order_by(desc("count")).limit(10)
    top_queries = [{"query": q, "count": c} for q, c in (await session.execute(top_q))]

    zero_q = top_q.where(SearchLog.result_count == 0)
    zero_results = [{"query": q, "count": c} for q, c in (await session.execute(zero_q))]

    stats_q = select(ProductStat).where(ProductStat.tenant_id == tid).order_by(
        desc(ProductStat.orders), desc(ProductStat.clicks)
    )
    product_stats = [
        {"product_id": p.product_id, "title": p.title, "clicks": p.clicks, "orders": p.orders}
        for p in (await session.execute(stats_q)).scalars()
    ]

    return {
        "total_searches": total,
        "top_queries": top_queries,
        "zero_results": zero_results,
        "product_stats": product_stats,
    }
