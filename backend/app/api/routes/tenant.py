from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.db import get_async_session
from app.core.tenancy import get_current_tenant
from app.models import APIKey, Tenant, WidgetPing
from app.services.keys import reset_key
from app.services.origins import normalize_origin

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


class WebsiteUpdate(BaseModel):
    website_url: str


@router.put("/website")
async def set_website(
    payload: WebsiteUpdate,
    tenant: Tenant = Depends(get_current_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    """Store the merchant's site as a bare host so ping comparisons are robust."""
    tenant.website_url = normalize_origin(payload.website_url)
    session.add(tenant)
    await session.commit()
    return {"website_url": tenant.website_url}


@router.get("/install-status")
async def install_status(
    tenant: Tenant = Depends(get_current_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    """Did the widget actually load on the merchant's site?"""
    rows = (
        await session.execute(
            select(WidgetPing).where(WidgetPing.tenant_id == tenant.id)
        )
    ).scalars().all()

    pings = [
        {
            "origin": p.origin,
            "kind": p.kind,
            "count": p.count,
            "last_seen": p.last_seen.isoformat() if p.last_seen else None,
        }
        for p in rows
    ]

    loads = [p for p in rows if p.kind == "load"]
    if not tenant.website_url:
        verdict = "no_website"
    elif not loads:
        verdict = "not_found"
    elif any(p.origin == tenant.website_url for p in loads):
        verdict = "ok"
    else:
        verdict = "wrong_domain"

    return {"website_url": tenant.website_url, "pings": pings, "verdict": verdict}
