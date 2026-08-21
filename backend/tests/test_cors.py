def test_cors_does_not_allow_credentials_with_a_wildcard_origin():
    """allow_origins=* with credentials is the dangerous pairing. PolarBear
    authenticates with Bearer tokens and X-PolarBear-Key, never cookies."""
    from starlette.middleware.cors import CORSMiddleware

    from app.main import app

    cors = [m for m in app.user_middleware if m.cls is CORSMiddleware]
    assert cors, "CORS middleware is not installed"
    options = cors[0].kwargs
    assert options["allow_origins"] == ["*"]
    assert options["allow_credentials"] is False


async def test_widget_origin_still_gets_cors_headers(client):
    """The widget must keep working from any merchant domain."""
    r = await client.get("/health", headers={"Origin": "https://any-merchant.example"})
    assert r.status_code == 200
    assert r.headers.get("access-control-allow-origin") == "*"
