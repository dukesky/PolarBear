async def _key(client, token):
    r = await client.get("/tenant/keys", headers={"Authorization": f"Bearer {token}"})
    return r.json()["search"]["key"]


def _stub_searcher(monkeypatch):
    from app.api.routes import search as search_route

    class StubSearcher:
        def __init__(self, tenant_id, storage=None, meili_client=None):
            pass

        def search(self, q, limit=20):
            return []

    monkeypatch.setattr(search_route, "HybridSearcher", StubSearcher)


async def test_restriction_is_off_by_default(registered, monkeypatch):
    """An existing merchant's integration must not change behavior on deploy."""
    client, token, _ = registered
    _stub_searcher(monkeypatch)
    auth = {"Authorization": f"Bearer {token}"}
    await client.put("/tenant/website", json={"website_url": "mystore.com"}, headers=auth)
    key = await _key(client, token)

    r = await client.get(
        "/search/", params={"q": "mug", "key": key}, headers={"Origin": "https://elsewhere.com"}
    )
    assert r.status_code == 200


async def test_restriction_blocks_a_mismatched_origin(registered, monkeypatch):
    client, token, _ = registered
    _stub_searcher(monkeypatch)
    auth = {"Authorization": f"Bearer {token}"}
    r = await client.put(
        "/tenant/website",
        json={"website_url": "mystore.com", "restrict_key_to_website": True},
        headers=auth,
    )
    assert r.status_code == 200
    assert r.json()["restrict_key_to_website"] is True
    key = await _key(client, token)

    blocked = await client.get(
        "/search/", params={"q": "mug", "key": key}, headers={"Origin": "https://elsewhere.com"}
    )
    assert blocked.status_code == 403

    allowed = await client.get(
        "/search/", params={"q": "mug", "key": key}, headers={"Origin": "https://www.mystore.com"}
    )
    assert allowed.status_code == 200


async def test_restriction_still_allows_requests_with_no_origin(registered, monkeypatch):
    """Apps and servers send no Origin - restricting them would undo C1.6."""
    client, token, _ = registered
    _stub_searcher(monkeypatch)
    auth = {"Authorization": f"Bearer {token}"}
    await client.put(
        "/tenant/website",
        json={"website_url": "mystore.com", "restrict_key_to_website": True},
        headers=auth,
    )
    key = await _key(client, token)

    r = await client.get("/search/", params={"q": "mug", "key": key})
    assert r.status_code == 200


async def test_restriction_without_a_website_does_not_block(registered, monkeypatch):
    client, token, _ = registered
    _stub_searcher(monkeypatch)
    auth = {"Authorization": f"Bearer {token}"}
    await client.put(
        "/tenant/website", json={"website_url": "", "restrict_key_to_website": True}, headers=auth
    )
    key = await _key(client, token)

    r = await client.get(
        "/search/", params={"q": "mug", "key": key}, headers={"Origin": "https://anywhere.com"}
    )
    assert r.status_code == 200


async def test_install_status_reports_the_flag(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    body = (await client.get("/tenant/install-status", headers=auth)).json()
    assert body["restrict_key_to_website"] is False
