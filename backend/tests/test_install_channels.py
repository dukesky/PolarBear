async def _search_key(client, token):
    r = await client.get("/tenant/keys", headers={"Authorization": f"Bearer {token}"})
    return r.json()["search"]["key"]


async def _status(client, token):
    r = await client.get(
        "/tenant/install-status", headers={"Authorization": f"Bearer {token}"}
    )
    assert r.status_code == 200, r.text
    return r.json()


async def test_app_only_merchant_is_api_only_not_not_found(registered):
    """The bug this task fixes: an app-only merchant was told to paste a snippet."""
    client, token, _ = registered
    key = await _search_key(client, token)

    # A native app sends no Origin — recorded as the "unknown" origin.
    await client.post("/analytics/install-ping", headers={"X-PolarBear-Key": key})

    body = await _status(client, token)
    assert body["verdict"] == "api_only"
    assert body["api"]["status"] == "active"
    assert body["web"]["status"] == "none"
    assert body["web"]["origin"] is None


async def test_api_only_outranks_no_website(registered, monkeypatch):
    """No website configured must not hide a working app integration."""
    client, token, _ = registered
    key = await _search_key(client, token)

    from app.api.routes import search as search_route

    class StubSearcher:
        def __init__(self, tenant_id, storage=None, meili_client=None):
            pass

        def search(self, q, limit=20):
            return []

    monkeypatch.setattr(search_route, "HybridSearcher", StubSearcher)
    await client.get("/search/", params={"q": "mug", "key": key})

    body = await _status(client, token)
    assert body["website_url"] is None
    assert body["verdict"] == "api_only"
    assert body["api"]["search_count"] >= 1


async def test_both_channels_reported_together(registered, monkeypatch):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    key = await _search_key(client, token)
    await client.put("/tenant/website", json={"website_url": "mystore.com"}, headers=auth)

    from app.api.routes import search as search_route

    class StubSearcher:
        def __init__(self, tenant_id, storage=None, meili_client=None):
            pass

        def search(self, q, limit=20):
            return []

    monkeypatch.setattr(search_route, "HybridSearcher", StubSearcher)

    # Browser install
    await client.post(
        "/analytics/install-ping",
        headers={"X-PolarBear-Key": key, "Origin": "https://mystore.com"},
    )
    # App search (no Origin)
    await client.get("/search/", params={"q": "mug", "key": key})

    body = await _status(client, token)
    assert body["verdict"] == "ok"
    assert body["web"]["status"] == "ok"
    assert body["web"]["origin"] == "mystore.com"
    assert body["api"]["status"] == "active"


async def test_browser_search_is_never_reported_as_app_traffic(registered, monkeypatch):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    key = await _search_key(client, token)
    await client.put("/tenant/website", json={"website_url": "mystore.com"}, headers=auth)

    from app.api.routes import search as search_route

    class StubSearcher:
        def __init__(self, tenant_id, storage=None, meili_client=None):
            pass

        def search(self, q, limit=20):
            return []

    monkeypatch.setattr(search_route, "HybridSearcher", StubSearcher)

    await client.post(
        "/analytics/install-ping",
        headers={"X-PolarBear-Key": key, "Origin": "https://mystore.com"},
    )
    await client.get(
        "/search/", params={"q": "mug", "key": key}, headers={"Origin": "https://mystore.com"}
    )

    body = await _status(client, token)
    assert body["verdict"] == "ok"
    assert body["api"]["status"] == "none"
    assert body["api"]["search_count"] == 0


async def test_wrong_domain_still_reported(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    key = await _search_key(client, token)
    await client.put("/tenant/website", json={"website_url": "mystore.com"}, headers=auth)

    await client.post(
        "/analytics/install-ping",
        headers={"X-PolarBear-Key": key, "Origin": "https://staging.othersite.com"},
    )

    body = await _status(client, token)
    assert body["verdict"] == "wrong_domain"
    assert body["web"]["status"] == "wrong_domain"
    assert body["web"]["origin"] == "staging.othersite.com"
    assert body["api"]["status"] == "none"


async def test_nothing_at_all_is_no_website_then_not_found(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}

    body = await _status(client, token)
    assert body["verdict"] == "no_website"
    assert body["web"]["status"] == "none"
    assert body["api"]["status"] == "none"

    await client.put("/tenant/website", json={"website_url": "mystore.com"}, headers=auth)
    assert (await _status(client, token))["verdict"] == "not_found"


async def test_search_count_accumulates(registered, monkeypatch):
    client, token, _ = registered
    key = await _search_key(client, token)

    from app.api.routes import search as search_route

    class StubSearcher:
        def __init__(self, tenant_id, storage=None, meili_client=None):
            pass

        def search(self, q, limit=20):
            return []

    monkeypatch.setattr(search_route, "HybridSearcher", StubSearcher)
    await client.get("/search/", params={"q": "a", "key": key})
    await client.get("/search/", params={"q": "b", "key": key})

    body = await _status(client, token)
    assert body["api"]["search_count"] == 2
