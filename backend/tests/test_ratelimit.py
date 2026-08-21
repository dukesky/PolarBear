import pytest


def test_limit_allows_up_to_the_cap_then_rejects(monkeypatch):
    from app.core import ratelimit
    from app.core.config import settings
    from fastapi import HTTPException

    monkeypatch.setattr(settings, "RATE_LIMIT_PER_MINUTE", 3)
    ratelimit.reset_limits()

    for _ in range(3):
        ratelimit.check_rate_limit("tenant-a")

    with pytest.raises(HTTPException) as exc:
        ratelimit.check_rate_limit("tenant-a")
    assert exc.value.status_code == 429
    assert "Retry-After" in exc.value.headers


def test_limit_is_per_bucket(monkeypatch):
    from app.core import ratelimit
    from app.core.config import settings

    monkeypatch.setattr(settings, "RATE_LIMIT_PER_MINUTE", 2)
    ratelimit.reset_limits()

    ratelimit.check_rate_limit("tenant-a")
    ratelimit.check_rate_limit("tenant-a")
    ratelimit.check_rate_limit("tenant-b")  # a noisy tenant must not starve another
    ratelimit.check_rate_limit("tenant-b")


def test_zero_disables_the_limit(monkeypatch):
    from app.core import ratelimit
    from app.core.config import settings

    monkeypatch.setattr(settings, "RATE_LIMIT_PER_MINUTE", 0)
    ratelimit.reset_limits()

    for _ in range(500):
        ratelimit.check_rate_limit("tenant-a")  # must not raise


def test_a_new_window_resets_the_count(monkeypatch):
    from app.core import ratelimit
    from app.core.config import settings

    monkeypatch.setattr(settings, "RATE_LIMIT_PER_MINUTE", 1)
    ratelimit.reset_limits()

    now = [1_000_000.0]
    monkeypatch.setattr(ratelimit.time, "time", lambda: now[0])

    ratelimit.check_rate_limit("tenant-a")
    now[0] += 61  # next window
    ratelimit.check_rate_limit("tenant-a")  # must not raise


async def test_search_is_rate_limited(registered, monkeypatch):
    from app.api.routes import search as search_route
    from app.core import ratelimit
    from app.core.config import settings

    class StubSearcher:
        def __init__(self, tenant_id, storage=None, meili_client=None):
            pass

        def search(self, q, limit=20):
            return []

    monkeypatch.setattr(search_route, "HybridSearcher", StubSearcher)
    monkeypatch.setattr(settings, "RATE_LIMIT_PER_MINUTE", 2)
    ratelimit.reset_limits()

    client, token, _ = registered
    key = (
        await client.get("/tenant/keys", headers={"Authorization": f"Bearer {token}"})
    ).json()["search"]["key"]

    assert (await client.get("/search/", params={"q": "a", "key": key})).status_code == 200
    assert (await client.get("/search/", params={"q": "b", "key": key})).status_code == 200
    third = await client.get("/search/", params={"q": "c", "key": key})
    assert third.status_code == 429
    assert third.headers.get("retry-after")
