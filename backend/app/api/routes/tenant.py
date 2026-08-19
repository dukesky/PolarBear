from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import delete as sql_delete
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.db import get_async_session
from app.core.tenancy import get_current_tenant
from app.core.users import current_active_user
from app.models import APIKey, ProductStat, SearchLog, Tenant, User, WidgetPing
from app.services.keys import reset_key
from app.services.origins import UNKNOWN, normalize_origin
from app.services.search.indexer import HybridIndexer
from app.services.storage import get_storage

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
    normalized = normalize_origin(payload.website_url)
    tenant.website_url = None if normalized in ("", UNKNOWN) else normalized
    session.add(tenant)
    await session.commit()
    return {"website_url": tenant.website_url}


@router.get("/install-status")
async def install_status(
    tenant: Tenant = Depends(get_current_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    """Which integration channels are actually live: the web widget, a direct API/app integration, or neither."""
    rows = (
        await session.execute(
            select(WidgetPing).where(WidgetPing.tenant_id == tenant.id)
        )
    ).scalars().all()

    def _iso(value):
        return value.isoformat() if value else None

    pings = [
        {
            "origin": p.origin,
            "kind": p.kind,
            "count": p.count,
            "last_seen": _iso(p.last_seen),
        }
        for p in rows
    ]

    # A browser always sends an Origin; a native app or a server-side caller
    # does not, and is recorded under the UNKNOWN sentinel. That difference is
    # what lets us report the two integration channels apart.
    loads = [p for p in rows if p.kind == "load" and p.origin != UNKNOWN]
    # (tenant_id, origin, kind) is unique, so at most one row can match.
    match = next(
        (p for p in loads if tenant.website_url and p.origin == tenant.website_url), None
    )

    # API integration can be either a search from UNKNOWN or a load from UNKNOWN
    unknown_search = next((p for p in rows if p.kind == "search" and p.origin == UNKNOWN), None)
    unknown_load = next((p for p in rows if p.kind == "load" and p.origin == UNKNOWN), None)

    if match:
        web = {"status": "ok", "origin": match.origin, "last_seen": _iso(match.last_seen)}
    elif loads:
        latest = max(loads, key=lambda p: p.last_seen or p.first_seen)
        web = {
            "status": "wrong_domain",
            "origin": latest.origin,
            "last_seen": _iso(latest.last_seen),
        }
    else:
        web = {"status": "none", "origin": None, "last_seen": None}

    if unknown_search:
        api = {
            "status": "active",
            "search_count": unknown_search.count,
            "last_seen": _iso(unknown_search.last_seen),
        }
    elif unknown_load:
        api = {
            "status": "active",
            "search_count": 0,
            "last_seen": _iso(unknown_load.last_seen),
        }
    else:
        api = {"status": "none", "search_count": 0, "last_seen": None}

    # api_only deliberately outranks no_website: an app-only merchant must not
    # be nagged for a website they do not have.
    if web["status"] == "ok":
        verdict = "ok"
    elif unknown_search or unknown_load:
        verdict = "api_only"
    elif loads:
        verdict = "wrong_domain"
    elif not tenant.website_url:
        verdict = "no_website"
    else:
        verdict = "not_found"

    return {
        "website_url": tenant.website_url,
        "web": web,
        "api": api,
        "verdict": verdict,
        "pings": pings,
    }


class AccountDeletion(BaseModel):
    email: str


@router.delete("/account")
async def delete_account(
    payload: AccountDeletion,
    user: User = Depends(current_active_user),
    tenant: Tenant = Depends(get_current_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    """Destroy this tenant and every trace of its data.

    External resources go first: a half-finished delete that leaves database
    rows is recoverable, while orphaned indexes and objects are not even
    discoverable. Every step is guarded - a merchant must be able to leave even
    when an external service is down.
    """
    if payload.email.strip().lower() != user.email.lower():
        raise HTTPException(
            status_code=400, detail="Type your own email address to confirm deletion."
        )

    removed = {"search_index": False, "files": False}

    try:
        HybridIndexer(str(tenant.id)).clear_all()
        removed["search_index"] = True
    except Exception as e:
        print(f"[delete] search index for {tenant.id}: {e}")

    try:
        get_storage().delete_tenant(str(tenant.id))
        removed["files"] = True
    except Exception as e:
        print(f"[delete] stored files for {tenant.id}: {e}")

    for model in (WidgetPing, SearchLog, ProductStat, APIKey):
        await session.execute(sql_delete(model).where(model.tenant_id == tenant.id))
    await session.execute(sql_delete(Tenant).where(Tenant.id == tenant.id))
    await session.execute(sql_delete(User).where(User.id == user.id))
    await session.commit()

    removed["account"] = True
    return {"status": "deleted", "removed": removed}
