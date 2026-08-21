"""Where a merchant's widget is actually running."""

import uuid
from datetime import datetime, timezone
from urllib.parse import urlparse

from sqlalchemy import select

from app.core.db import async_session_maker
from app.models import WidgetPing

UNKNOWN = "unknown"


def normalize_origin(value: str | None) -> str:
    """https://MyStore.com/shop -> mystore.com"""
    if not value:
        return UNKNOWN
    raw = str(value).strip()
    # Browsers send the literal `Origin: null` from sandboxed iframes,
    # file:// pages, data:/about:blank documents and mobile WebViews. That is
    # an absent origin, not a site named "null", and treating it as a real
    # host would 403 exactly the integrations we promise to keep working.
    if raw.lower() == "null":
        return UNKNOWN
    if "//" not in raw:
        raw = "//" + raw
    host = (urlparse(raw).hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    return host or UNKNOWN


def origin_from_request(request) -> str:
    """Prefer the CORS Origin header; fall back to the Referer's host."""
    origin = request.headers.get("origin")
    if origin:
        return normalize_origin(origin)
    return normalize_origin(request.headers.get("referer"))


async def record_ping(tenant_id: uuid.UUID, origin: str, kind: str) -> None:
    """Upsert one (tenant, origin, kind) row. Never raises — statistics must
    not break a merchant's page."""
    try:
        async with async_session_maker() as session:
            row = (
                await session.execute(
                    select(WidgetPing).where(
                        WidgetPing.tenant_id == tenant_id,
                        WidgetPing.origin == origin,
                        WidgetPing.kind == kind,
                    )
                )
            ).scalar_one_or_none()
            now = datetime.now(timezone.utc).replace(tzinfo=None)
            if row is None:
                session.add(
                    WidgetPing(
                        tenant_id=tenant_id, origin=origin, kind=kind,
                        count=1, first_seen=now, last_seen=now,
                    )
                )
            else:
                row.count += 1
                row.last_seen = now
            await session.commit()
    except Exception as e:
        print(f"Failed to record widget ping: {e}")
