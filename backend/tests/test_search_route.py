from sqlalchemy import select


class StubSearcher:
    def __init__(self, tenant_id, storage=None, meili_client=None):
        StubSearcher.last_tenant = str(tenant_id)

    def search(self, q, limit=20):
        return [{"id": "1", "title": "stub"}]


async def test_search_requires_key_or_jwt(client):
    r = await client.get("/search/", params={"q": "shoe"})
    assert r.status_code == 401


async def test_search_with_invalid_key(client):
    r = await client.get("/search/", params={"q": "shoe", "key": "pb_search_bogus"})
    assert r.status_code == 401


async def test_search_with_key_and_jwt(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import search as search_route

    monkeypatch.setattr(search_route, "HybridSearcher", StubSearcher)

    # via JWT
    r = await client.get(
        "/search/", params={"q": "shoe"}, headers={"Authorization": f"Bearer {token}"}
    )
    assert r.status_code == 200
    assert r.json()["results"] == [{"id": "1", "title": "stub"}]

    # via public search key (header)
    keys = (await client.get("/tenant/keys", headers={"Authorization": f"Bearer {token}"})).json()
    search_key = keys["search"]["key"]
    r = await client.get("/search/", params={"q": "shoe"}, headers={"X-PolarBear-Key": search_key})
    assert r.status_code == 200
    assert StubSearcher.last_tenant  # tenant resolved from key

    # search was logged with the tenant id
    from app.core.db import async_session_maker
    from app.models import SearchLog

    async with async_session_maker() as s:
        logs = (await s.execute(select(SearchLog))).scalars().all()
        assert len(logs) >= 2
        assert str(logs[-1].tenant_id) == StubSearcher.last_tenant
