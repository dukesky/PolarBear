async def test_widget_js_served_with_cache_headers(client):
    r = await client.get("/widget.js")
    assert r.status_code == 200
    assert "javascript" in r.headers["content-type"]
    assert r.headers["cache-control"] == "public, max-age=3600"
    assert len(r.content) > 200  # real artifact, not a stub
