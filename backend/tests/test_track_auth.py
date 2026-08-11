async def test_track_with_search_key(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    keys = (await client.get("/tenant/keys", headers=auth)).json()

    r = await client.post(
        "/analytics/track",
        json={"type": "click", "product_id": "p1", "title": "Widget Product"},
        headers={"X-PolarBear-Key": keys["search"]["key"]},
    )
    assert r.status_code == 200, r.text

    stats = (await client.get("/analytics/stats", headers=auth)).json()
    assert stats["product_stats"][0]["product_id"] == "p1"
    assert stats["product_stats"][0]["clicks"] == 1


async def test_track_rejects_missing_and_bad_key(client):
    body = {"type": "click", "product_id": "p1", "title": "X"}
    assert (await client.post("/analytics/track", json=body)).status_code == 401
    r = await client.post(
        "/analytics/track", json=body, headers={"X-PolarBear-Key": "pb_search_bogus"}
    )
    assert r.status_code == 401


async def test_track_still_works_with_jwt(registered):
    client, token, _ = registered
    r = await client.post(
        "/analytics/track",
        json={"type": "order", "product_id": "p2", "title": "Y"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200
