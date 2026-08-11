from sqlalchemy import select


async def test_register_login_me(registered):
    client, token, email = registered
    r = await client.get("/users/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    assert r.json()["email"] == email


async def test_me_requires_auth(client):
    r = await client.get("/users/me")
    assert r.status_code == 401


async def test_register_creates_tenant_and_keys(registered):
    client, token, email = registered
    from app.core.db import async_session_maker
    from app.models import APIKey, Tenant, User

    async with async_session_maker() as s:
        user = (
            (await s.execute(select(User).where(User.email == email))).unique().scalar_one()
        )
        tenant = (
            await s.execute(select(Tenant).where(Tenant.owner_user_id == user.id))
        ).scalar_one()
        kinds = {
            k.kind
            for k in (
                await s.execute(select(APIKey).where(APIKey.tenant_id == tenant.id))
            ).scalars()
        }
        assert kinds == {"search", "admin"}
