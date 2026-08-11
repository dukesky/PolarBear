import hashlib
import secrets
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import APIKey

KEY_PREFIXES = {"search": "pb_search_", "admin": "pb_admin_"}


def hash_key(plaintext: str) -> str:
    return hashlib.sha256(plaintext.encode()).hexdigest()


def generate_key(kind: str) -> tuple[str, str]:
    plaintext = KEY_PREFIXES[kind] + secrets.token_urlsafe(32)
    return plaintext, hash_key(plaintext)


async def reset_key(session: AsyncSession, tenant_id: uuid.UUID, kind: str) -> str:
    plaintext, digest = generate_key(kind)
    row = (
        await session.execute(
            select(APIKey).where(APIKey.tenant_id == tenant_id, APIKey.kind == kind)
        )
    ).scalar_one_or_none()
    if row is None:
        row = APIKey(tenant_id=tenant_id, kind=kind, key_hash=digest)
        session.add(row)
    else:
        row.key_hash = digest
    row.plaintext = plaintext if kind == "search" else None
    await session.commit()
    return plaintext


async def create_tenant_keys(session: AsyncSession, tenant_id: uuid.UUID) -> dict[str, str]:
    return {kind: await reset_key(session, tenant_id, kind) for kind in ("search", "admin")}


async def resolve_key(session: AsyncSession, plaintext: str) -> APIKey | None:
    return (
        await session.execute(select(APIKey).where(APIKey.key_hash == hash_key(plaintext)))
    ).scalar_one_or_none()
