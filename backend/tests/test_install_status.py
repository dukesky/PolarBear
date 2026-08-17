async def _key(client, token):
    r = await client.get("/tenant/keys", headers={"Authorization": f"Bearer {token}"})
    return r.json()["search"]["key"]


async def test_status_is_no_website_then_not_found(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}

    r = await client.get("/tenant/install-status", headers=auth)
    assert r.status_code == 200
    assert r.json()["verdict"] == "no_website"

    r = await client.put(
        "/tenant/website", json={"website_url": "https://MyStore.com/shop"}, headers=auth
    )
    assert r.status_code == 200
    assert r.json()["website_url"] == "mystore.com"

    r = await client.get("/tenant/install-status", headers=auth)
    assert r.json()["verdict"] == "not_found"


async def test_status_ok_after_matching_ping(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    await client.put("/tenant/website", json={"website_url": "mystore.com"}, headers=auth)
    key = await _key(client, token)

    await client.post(
        "/analytics/install-ping",
        headers={"X-PolarBear-Key": key, "Origin": "https://www.mystore.com"},
    )

    body = (await client.get("/tenant/install-status", headers=auth)).json()
    assert body["verdict"] == "ok"
    assert body["pings"][0]["origin"] == "mystore.com"
    assert body["pings"][0]["kind"] == "load"


async def test_status_wrong_domain(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    await client.put("/tenant/website", json={"website_url": "mystore.com"}, headers=auth)
    key = await _key(client, token)

    await client.post(
        "/analytics/install-ping",
        headers={"X-PolarBear-Key": key, "Origin": "https://staging.othersite.com"},
    )

    assert (await client.get("/tenant/install-status", headers=auth)).json()[
        "verdict"
    ] == "wrong_domain"


async def test_status_requires_auth(client):
    assert (await client.get("/tenant/install-status")).status_code == 401
    assert (await client.put("/tenant/website", json={"website_url": "x.com"})).status_code == 401


async def test_blank_website_is_stored_as_null(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    r = await client.put("/tenant/website", json={"website_url": ""}, headers=auth)
    assert r.status_code == 200
    assert r.json()["website_url"] is None
    assert (await client.get("/tenant/install-status", headers=auth)).json()["verdict"] == "no_website"


async def test_unknown_origin_never_counts_as_ok(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    await client.put("/tenant/website", json={"website_url": "mystore.com"}, headers=auth)
    key = (await client.get("/tenant/keys", headers=auth)).json()["search"]["key"]
    # a ping with no Origin header is recorded as "unknown"
    await client.post("/analytics/install-ping", headers={"X-PolarBear-Key": key})
    assert (await client.get("/tenant/install-status", headers=auth)).json()["verdict"] != "ok"
