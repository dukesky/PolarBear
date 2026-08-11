async def test_snippet_requires_auth(client):
    assert (await client.get("/tenant/snippet")).status_code == 401


async def test_snippet_contains_key_and_backend_url(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    keys = (await client.get("/tenant/keys", headers=auth)).json()

    r = await client.get("/tenant/snippet", headers=auth)
    assert r.status_code == 200
    snippet = r.json()["snippet"]
    assert '<div id="polarbear-search"></div>' in snippet
    assert keys["search"]["key"] in snippet
    assert "/widget.js" in snippet
    assert "async" in snippet
