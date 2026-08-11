import uuid

from sqlalchemy import select

from app.core.db import async_session_maker
from app.models import ProductStat, SearchLog


async def log_search(tenant_id: uuid.UUID, query: str, result_count: int) -> None:
    try:
        async with async_session_maker() as session:
            session.add(SearchLog(tenant_id=tenant_id, query=query, result_count=result_count))
            await session.commit()
    except Exception as e:
        print(f"Failed to log search: {e}")


async def track_product_event(
    tenant_id: uuid.UUID, event_type: str, product_id: str, title: str
) -> None:
    try:
        async with async_session_maker() as session:
            stat = (
                await session.execute(
                    select(ProductStat).where(
                        ProductStat.tenant_id == tenant_id,
                        ProductStat.product_id == product_id,
                    )
                )
            ).scalar_one_or_none()
            if stat is None:
                stat = ProductStat(
                    tenant_id=tenant_id, product_id=product_id, title=title, clicks=0, orders=0
                )
                session.add(stat)
            if event_type == "click":
                stat.clicks += 1
            elif event_type == "order":
                stat.orders += 1
            await session.commit()
    except Exception as e:
        print(f"Failed to track product event: {e}")
