import io
import time

import httpx
import pytest

from tests.test_indexer import FakeModel

MEILI_URL = "http://localhost:7700"


def _meili_up() -> bool:
    try:
        return httpx.get(f"{MEILI_URL}/health", timeout=1).status_code == 200
    except Exception:
        return False


pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(not _meili_up(), reason="Meilisearch not running on :7700"),
]

CSV_A = b"id,title,description\na1,Arctic Parka,warm winter jacket\n"
CSV_B = b"id,title,description\nb1,Beach Towel,soft cotton towel\n"


async def _register(client, email):
    await client.post("/auth/register", json={"email": email, "password": "pass12345"})
    r = await client.post("/auth/jwt/login", data={"username": email, "password": "pass12345"})
    token = r.json()["access_token"]
    keys = (await client.get("/tenant/keys", headers={"Authorization": f"Bearer {token}"})).json()
    return token, keys["search"]["key"]


async def _upload(client, token, csv_bytes):
    files = {"file": ("p.csv", io.BytesIO(csv_bytes), "text/csv")}
    r = await client.post(
        "/ingest/upload", files=files, headers={"Authorization": f"Bearer {token}"}
    )
    assert r.status_code == 200, r.text


async def _search_ids(client, key, q):
    # The /search route is registered under prefix "/search" with path "/",
    # so the real path is "/search/" — requesting "/search" (no trailing
    # slash) triggers FastAPI's redirect_slashes 307, and httpx's AsyncClient
    # does not follow redirects by default. Use the trailing-slash form.
    r = await client.get("/search/", params={"q": q, "key": key})
    assert r.status_code == 200, r.text
    return {str(hit["id"]) for hit in r.json()["results"]}


async def _search_ids_polling(client, key, q, expected_id, retries=10, delay=0.5):
    """Poll search until expected_id shows up (or retries exhausted).

    Meilisearch indexes documents asynchronously via a task queue, so a
    search performed immediately after an upload can race the indexing
    task. Poll with bounded retries rather than a single long sleep.
    """
    ids: set[str] = set()
    for _ in range(retries):
        ids = await _search_ids(client, key, q)
        if expected_id in ids:
            return ids
        time.sleep(delay)
    return ids


async def test_two_tenants_cannot_see_each_other(client, monkeypatch):
    from app.services.search import embedding

    monkeypatch.setattr(embedding, "_model", FakeModel())

    token_a, key_a = await _register(client, "a@shop.com")
    token_b, key_b = await _register(client, "b@shop.com")

    await _upload(client, token_a, CSV_A)
    await _upload(client, token_b, CSV_B)

    # Meilisearch task queue is async; poll (bounded) instead of a fixed sleep.
    ids_a_parka = await _search_ids_polling(client, key_a, "parka", "a1")
    ids_b_towel = await _search_ids_polling(client, key_b, "towel", "b1")

    # Keyword match: each tenant sees own product, not the other's
    assert "a1" in ids_a_parka
    assert "b1" not in await _search_ids(client, key_a, "towel")
    assert "b1" in ids_b_towel
    assert "a1" not in await _search_ids(client, key_b, "parka")

    # Cross-tenant product access via admin route is denied/empty
    r = await client.get("/products/", headers={"Authorization": f"Bearer {token_a}"})
    ids = {str(p["id"]) for p in r.json()}
    assert "b1" not in ids and "a1" in ids
