from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.db import get_async_session
from app.core.tenancy import get_current_tenant
from app.models import APIKey, Tenant
from app.services.keys import reset_key

router = APIRouter()


@router.get("/keys")
async def get_keys(
    tenant: Tenant = Depends(get_current_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    keys = (
        await session.execute(select(APIKey).where(APIKey.tenant_id == tenant.id))
    ).scalars()
    return {
        k.kind: {
            "key": k.plaintext if k.kind == "search" else None,
            "created_at": k.created_at.isoformat() if k.created_at else None,
        }
        for k in keys
    }


@router.post("/keys/{kind}/reset")
async def reset(
    kind: str,
    tenant: Tenant = Depends(get_current_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    if kind not in ("search", "admin"):
        raise HTTPException(status_code=400, detail="kind must be 'search' or 'admin'")
    plaintext = await reset_key(session, tenant.id, kind)
    return {"kind": kind, "key": plaintext}


@router.get("/snippet")
async def get_snippet(
    tenant: Tenant = Depends(get_current_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    """Copy-ready embed snippet with the tenant's public search key."""
    key = (
        await session.execute(
            select(APIKey).where(APIKey.tenant_id == tenant.id, APIKey.kind == "search")
        )
    ).scalar_one_or_none()
    if key is None or key.plaintext is None:
        raise HTTPException(status_code=404, detail="Search key missing — reset it first")
    snippet = (
        '<div id="polarbear-search"></div>\n'
        f'<script src="{settings.PUBLIC_BACKEND_URL}/widget.js" '
        f'data-key="{key.plaintext}" async></script>'
    )
    return {"snippet": snippet}
