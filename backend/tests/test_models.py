import uuid
from sqlalchemy import select


async def test_tables_create_and_roundtrip(client):
    from app.core.db import async_session_maker
    from app.models import Tenant, APIKey

    owner_id = uuid.uuid4()
    async with async_session_maker() as s:
        t = Tenant(name="Shop", owner_user_id=owner_id)
        s.add(t)
        await s.commit()
        s.add(APIKey(tenant_id=t.id, key_hash="a" * 64, kind="search", plaintext="pb_search_x"))
        await s.commit()

    async with async_session_maker() as s:
        got = (await s.execute(select(Tenant).where(Tenant.owner_user_id == owner_id))).scalar_one()
        assert got.name == "Shop"
        key = (await s.execute(select(APIKey).where(APIKey.tenant_id == got.id))).scalar_one()
        assert key.kind == "search" and key.plaintext == "pb_search_x"
