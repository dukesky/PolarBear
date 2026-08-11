async def test_providers_reports_google_disabled_by_default(client):
    r = await client.get("/auth/providers")
    assert r.status_code == 200
    assert r.json() == {"google": False}


async def test_google_routes_absent_when_disabled(client):
    r = await client.get("/auth/google/authorize")
    assert r.status_code == 404
