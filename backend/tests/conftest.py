import os

os.environ["DATABASE_URL"] = "sqlite+aiosqlite:///./test_polarbear.db"
os.environ["SECRET_KEY"] = "test-secret"
os.environ["INDEX_STORAGE"] = "local"

import pytest_asyncio
from httpx import ASGITransport, AsyncClient


@pytest_asyncio.fixture
async def client(tmp_path, monkeypatch):
    from app.core.config import settings
    monkeypatch.setattr(settings, "DATA_DIR", str(tmp_path))

    from app.core.db import create_db_and_tables, engine, Base
    from app.main import app

    await create_db_and_tables()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)


@pytest_asyncio.fixture
async def registered(client):
    """Register a user, return (client, token, email)."""
    email = "owner@example.com"
    r = await client.post("/auth/register", json={"email": email, "password": "pass12345"})
    assert r.status_code == 201, r.text
    r = await client.post("/auth/jwt/login", data={"username": email, "password": "pass12345"})
    assert r.status_code == 200, r.text
    return client, r.json()["access_token"], email
