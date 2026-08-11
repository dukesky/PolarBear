async def test_get_keys_requires_auth(client):
    r = await client.get("/tenant/keys")
    assert r.status_code == 401


async def test_get_and_reset_keys(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}

    r = await client.get("/tenant/keys", headers=auth)
    assert r.status_code == 200
    body = r.json()
    assert body["search"]["key"].startswith("pb_search_")
    assert body["admin"]["key"] is None  # admin plaintext never returned on GET

    r = await client.post("/tenant/keys/admin/reset", headers=auth)
    assert r.status_code == 200
    assert r.json()["key"].startswith("pb_admin_")

    r = await client.post("/tenant/keys/bogus/reset", headers=auth)
    assert r.status_code == 400
