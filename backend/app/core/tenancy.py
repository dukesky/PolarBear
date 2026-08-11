import uuid

from fastapi import Depends, HTTPException, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import get_async_session
from app.core.users import current_active_user, optional_current_user
from app.models import Tenant, User
from app.services.keys import resolve_key


async def _tenant_for_user(session: AsyncSession, user: User) -> Tenant | None:
    return (
        await session.execute(select(Tenant).where(Tenant.owner_user_id == user.id))
    ).scalar_one_or_none()


async def get_current_tenant(
    user: User = Depends(current_active_user),
    session: AsyncSession = Depends(get_async_session),
) -> Tenant:
    tenant = await _tenant_for_user(session, user)
    if tenant is None:
        raise HTTPException(status_code=403, detail="No tenant for user")
    return tenant


async def resolve_search_tenant(
    request: Request,
    user: User | None = Depends(optional_current_user),
    session: AsyncSession = Depends(get_async_session),
) -> uuid.UUID:
    """Tenant for /search: public search key (X-PolarBear-Key header or ?key=) or JWT."""
    raw = request.headers.get("X-PolarBear-Key") or request.query_params.get("key")
    if raw:
        api_key = await resolve_key(session, raw)
        if api_key is None:
            raise HTTPException(status_code=401, detail="Invalid API key")
        return api_key.tenant_id
    if user is not None:
        tenant = await _tenant_for_user(session, user)
        if tenant is not None:
            return tenant.id
    raise HTTPException(status_code=401, detail="Missing API key or login")


async def resolve_admin_tenant(
    request: Request,
    user: User | None = Depends(optional_current_user),
    session: AsyncSession = Depends(get_async_session),
) -> Tenant:
    """Tenant for admin routes: JWT or admin key. A search key here is 403."""
    raw = request.headers.get("X-PolarBear-Key")
    if raw:
        api_key = await resolve_key(session, raw)
        if api_key is None:
            raise HTTPException(status_code=401, detail="Invalid API key")
        if api_key.kind != "admin":
            raise HTTPException(status_code=403, detail="Search key cannot perform admin actions")
        tenant = (
            await session.execute(select(Tenant).where(Tenant.id == api_key.tenant_id))
        ).scalar_one()
        return tenant
    if user is not None:
        tenant = await _tenant_for_user(session, user)
        if tenant is not None:
            return tenant
    raise HTTPException(status_code=401, detail="Missing credentials")
