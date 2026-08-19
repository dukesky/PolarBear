from sqlalchemy import func, select


class NoopIndexer:
    def __init__(self, tenant_id, storage=None, meili_client=None):
        pass

    def clear_all(self):
        return 0


async def _register(client, email):
    await client.post("/auth/register", json={"email": email, "password": "pass12345"})
    r = await client.post("/auth/jwt/login", data={"username": email, "password": "pass12345"})
    return r.json()["access_token"]


async def test_account_deletion_wipes_one_tenant_and_spares_the_other(registered, monkeypatch):
    client, token_a, email_a = registered
    from app.api.routes import tenant as tenant_routes

    monkeypatch.setattr(tenant_routes, "HybridIndexer", NoopIndexer)

    token_b = await _register(client, "keeper@shop.com")
    auth_a = {"Authorization": f"Bearer {token_a}"}
    auth_b = {"Authorization": f"Bearer {token_b}"}

    for auth in (auth_a, auth_b):
        await client.put("/tenant/website", json={"website_url": "shop.com"}, headers=auth)
        await client.post(
            "/analytics/track",
            json={"type": "click", "product_id": "p1", "title": "Thing"},
            headers=auth,
        )

    from app.core.db import async_session_maker
    from app.models import APIKey, ProductStat, Tenant, User

    async with async_session_maker() as s:
        user_a = (await s.execute(select(User).where(User.email == email_a))).unique().scalar_one()
        tenant_a = (
            await s.execute(select(Tenant).where(Tenant.owner_user_id == user_a.id))
        ).scalar_one()
        tenant_a_id = tenant_a.id

    r = await client.request("DELETE", "/tenant/account", json={"email": email_a}, headers=auth_a)
    assert r.status_code == 200, r.text

    async with async_session_maker() as s:
        tenants_left = (
            await s.execute(select(func.count()).select_from(Tenant).where(Tenant.id == tenant_a_id))
        ).scalar_one()
        assert tenants_left == 0

        for model in (APIKey, ProductStat):
            left = (
                await s.execute(
                    select(func.count()).select_from(model).where(model.tenant_id == tenant_a_id)
                )
            ).scalar_one()
            assert left == 0, f"{model.__name__} still has rows for the deleted tenant"

        users_left = (
            await s.execute(select(func.count()).select_from(User).where(User.email == email_a))
        ).scalar_one()
        assert users_left == 0

    stale = await client.post(
        "/auth/jwt/login", data={"username": email_a, "password": "pass12345"}
    )
    assert stale.status_code == 400

    keys_b = await client.get("/tenant/keys", headers=auth_b)
    assert keys_b.status_code == 200
    assert keys_b.json()["search"]["key"].startswith("pb_search_")
    stats_b = await client.get("/analytics/stats", headers=auth_b)
    assert stats_b.json()["product_stats"][0]["product_id"] == "p1"


async def test_account_deletion_requires_the_matching_email(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import tenant as tenant_routes

    monkeypatch.setattr(tenant_routes, "HybridIndexer", NoopIndexer)

    r = await client.request(
        "DELETE",
        "/tenant/account",
        json={"email": "someone-else@shop.com"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 400


async def test_account_deletion_requires_auth(client):
    r = await client.request("DELETE", "/tenant/account", json={"email": "a@b.com"})
    assert r.status_code == 401


async def test_account_deletion_survives_a_broken_storage_backend(registered, monkeypatch):
    client, token, email_addr = registered
    from app.api.routes import tenant as tenant_routes

    monkeypatch.setattr(tenant_routes, "HybridIndexer", NoopIndexer)

    class Broken:
        def delete_tenant(self, tenant_id):
            raise RuntimeError("bucket unreachable")

    monkeypatch.setattr(tenant_routes, "get_storage", lambda: Broken())

    r = await client.request(
        "DELETE",
        "/tenant/account",
        json={"email": email_addr},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200, r.text

    from app.core.db import async_session_maker
    from app.models import User

    async with async_session_maker() as s:
        left = (
            await s.execute(select(func.count()).select_from(User).where(User.email == email_addr))
        ).scalar_one()
        assert left == 0
