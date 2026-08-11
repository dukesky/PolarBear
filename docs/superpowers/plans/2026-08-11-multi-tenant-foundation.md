# Multi-Tenant Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn PolarBear from a single-tenant demo into a multi-tenant platform: registered merchants get isolated indexes, two API keys, and durable index storage — the prerequisite for the embeddable search widget (sub-project C).

**Architecture:** One account = one tenant. Meilisearch index per tenant (`products_{tenant_id}`), FAISS index per tenant persisted through an `IndexStorage` abstraction (local FS or GCS), account/key/analytics data in SQLAlchemy (SQLite dev / Postgres prod). Auth via fastapi-users (email+password JWT, then Google OAuth). `/search` authenticates by public search key or JWT; admin routes by JWT or admin key.

**Tech Stack:** FastAPI, fastapi-users (SQLAlchemy adapter + OAuth), SQLAlchemy 2 async (aiosqlite/asyncpg), Meilisearch, FAISS, sentence-transformers, google-cloud-storage, Next.js 16 + Tailwind 4, pytest + pytest-asyncio + httpx.

**Spec:** `docs/superpowers/specs/2026-08-11-multi-tenant-foundation-design.md`

## Global Constraints

- Python `>=3.11,<3.14`; backend deps managed with **poetry** (`cd backend && poetry add ...`).
- Backend tests: `cd backend && poetry run pytest` (asyncio_mode=auto). Integration tests marked `@pytest.mark.integration` and skipped when Meilisearch is unreachable.
- Key prefixes exactly: `pb_search_` and `pb_admin_`. Keys are 32-byte urlsafe tokens; stored as SHA-256 hex in `api_keys.key_hash`. Search-key plaintext is additionally stored (it is public by design — the dashboard and future widget snippet must display it); admin-key plaintext is shown only at creation/reset.
- Meilisearch index name per tenant: `products_{tenant_id}` (tenant_id = UUID string with dashes; valid Meilisearch uid chars).
- FAISS artifacts per tenant: `faiss.bin` + `doc_map.pkl` under `tenants/{tenant_id}/` in the configured storage.
- Frontend UI style (user requirement): clean/minimal, consistent with existing pages — white/light background, gray borders, `indigo-600` accent, Tailwind utilities only, **no new UI libraries**. Auth/Settings pages follow the Upload page's centered-card pattern.
- YAGNI (out of scope): billing, email verification, password reset, team members, quotas, Shopify sync, the widget itself, search-quality work.
- Frontend verification: `cd frontend && npm run build` must pass; manual browser checks listed per task.
- Env vars introduced: `DATABASE_URL`, `SECRET_KEY`, `INDEX_STORAGE` (`local`|`gcs`), `GCS_BUCKET`, `DATA_DIR`, `PUBLIC_BACKEND_URL`, `FRONTEND_URL`, `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`.

---

### Task 1: Repo hygiene — remove binary state files from git

**Files:**
- Delete from git (keep untracked): `backend/faiss_index.bin`, `backend/doc_map.pkl`, `backend/analytics.db`
- Modify: `.gitignore`

- [ ] **Step 1: Untrack the files**

```bash
git rm --cached backend/faiss_index.bin backend/doc_map.pkl backend/analytics.db
```

- [ ] **Step 2: Add ignore patterns**

Append to `.gitignore`:

```
# Runtime state — never commit
*.bin
*.pkl
*.db
backend/data/
data/
```

- [ ] **Step 3: Verify**

Run: `git status --short`
Expected: the three files show as `D ` (staged deletion) and are NOT re-listed as untracked additions; `git check-ignore backend/analytics.db` prints the path.

- [ ] **Step 4: Commit**

```bash
git add .gitignore
git commit -m "chore: remove runtime index/db binaries from git, ignore them"
```

---

### Task 2: Backend dependencies + test scaffolding

**Files:**
- Modify: `backend/pyproject.toml`
- Create: `backend/tests/__init__.py`, `backend/tests/conftest.py`

**Interfaces:**
- Produces: pytest runnable via `poetry run pytest`; `client` async fixture (httpx against the app, fresh tables per test, tmp DATA_DIR); env defaults for tests.

- [ ] **Step 1: Add dependencies**

```bash
cd backend
poetry add "fastapi-users[sqlalchemy,oauth]" sqlalchemy aiosqlite asyncpg greenlet google-cloud-storage
poetry add --group dev pytest pytest-asyncio httpx
```

- [ ] **Step 2: Configure pytest**

Append to `backend/pyproject.toml`:

```toml
[tool.pytest.ini_options]
asyncio_mode = "auto"
markers = ["integration: requires a running Meilisearch"]
```

- [ ] **Step 3: Write conftest**

`backend/tests/conftest.py`:

```python
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
```

(The `registered` fixture will start passing after Task 5; that's expected.)

- [ ] **Step 4: Verify pytest runs**

Run: `cd backend && poetry run pytest --collect-only`
Expected: exits 0, "no tests ran" (no test files yet — scaffolding only).

- [ ] **Step 5: Commit**

```bash
git add backend/pyproject.toml backend/poetry.lock backend/tests/
git commit -m "chore: add auth/db/storage deps and pytest scaffolding"
```

---

### Task 3: Config, async DB core, and models

**Files:**
- Modify: `backend/app/core/config.py`
- Create: `backend/app/core/db.py`, `backend/app/models.py`
- Test: `backend/tests/test_models.py`

**Interfaces:**
- Produces:
  - `app.core.db`: `Base`, `engine`, `async_session_maker`, `async get_async_session() -> AsyncGenerator[AsyncSession]`, `async create_db_and_tables()`
  - `app.models`: `User`, `OAuthAccount`, `Tenant(id, name, owner_user_id)`, `APIKey(id, tenant_id, key_hash, plaintext, kind, created_at)`, `SearchLog(id, tenant_id, query, result_count, timestamp)`, `ProductStat(tenant_id, product_id, title, clicks, orders)`
  - `app.core.config.settings` with all new env-backed fields

- [ ] **Step 1: Write the failing test**

`backend/tests/test_models.py`:

```python
import uuid
from sqlalchemy import select


async def test_tables_create_and_roundtrip(client):
    from app.core.db import async_session_maker
    from app.models import Tenant, APIKey

    owner_id = uuid.uuid4()
    async with async_session_maker() as s:
        t = Tenant(name="Shop", owner_user_id=owner_id)
        s.add(t)
        await s.commit()
        s.add(APIKey(tenant_id=t.id, key_hash="a" * 64, kind="search", plaintext="pb_search_x"))
        await s.commit()

    async with async_session_maker() as s:
        got = (await s.execute(select(Tenant).where(Tenant.owner_user_id == owner_id))).scalar_one()
        assert got.name == "Shop"
        key = (await s.execute(select(APIKey).where(APIKey.tenant_id == got.id))).scalar_one()
        assert key.kind == "search" and key.plaintext == "pb_search_x"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_models.py -v`
Expected: FAIL — `ModuleNotFoundError: app.core.db` (imported via conftest's `client` fixture).

- [ ] **Step 3: Extend config**

Replace `backend/app/core/config.py`:

```python
import os


class Settings:
    PROJECT_NAME: str = "PolarBear"
    MEILI_HOST: str = os.getenv("MEILI_HOST", "http://localhost:7700")
    MEILI_MASTER_KEY: str = os.getenv("MEILI_MASTER_KEY", "masterKey")
    DATABASE_URL: str = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./polarbear.db")
    SECRET_KEY: str = os.getenv("SECRET_KEY", "dev-secret-change-me")
    INDEX_STORAGE: str = os.getenv("INDEX_STORAGE", "local")  # "local" | "gcs"
    GCS_BUCKET: str = os.getenv("GCS_BUCKET", "")
    DATA_DIR: str = os.getenv("DATA_DIR", "./data")
    PUBLIC_BACKEND_URL: str = os.getenv("PUBLIC_BACKEND_URL", "http://localhost:8000")
    FRONTEND_URL: str = os.getenv("FRONTEND_URL", "http://localhost:3000")
    GOOGLE_OAUTH_CLIENT_ID: str = os.getenv("GOOGLE_OAUTH_CLIENT_ID", "")
    GOOGLE_OAUTH_CLIENT_SECRET: str = os.getenv("GOOGLE_OAUTH_CLIENT_SECRET", "")


settings = Settings()
```

- [ ] **Step 4: Write DB core**

`backend/app/core/db.py`:

```python
from collections.abc import AsyncGenerator

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from app.core.config import settings


class Base(DeclarativeBase):
    pass


engine = create_async_engine(settings.DATABASE_URL)
async_session_maker = async_sessionmaker(engine, expire_on_commit=False)


async def create_db_and_tables() -> None:
    from app import models  # noqa: F401  — register tables on Base

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


async def get_async_session() -> AsyncGenerator[AsyncSession, None]:
    async with async_session_maker() as session:
        yield session
```

- [ ] **Step 5: Write models**

`backend/app/models.py`:

```python
import uuid
from datetime import datetime

from fastapi_users_db_sqlalchemy import (
    SQLAlchemyBaseOAuthAccountTableUUID,
    SQLAlchemyBaseUserTableUUID,
)
from sqlalchemy import DateTime, ForeignKey, Integer, String, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.db import Base


class OAuthAccount(SQLAlchemyBaseOAuthAccountTableUUID, Base):
    pass


class User(SQLAlchemyBaseUserTableUUID, Base):
    oauth_accounts: Mapped[list[OAuthAccount]] = relationship(lazy="joined")


class Tenant(Base):
    __tablename__ = "tenants"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(255), default="My Store")
    owner_user_id: Mapped[uuid.UUID] = mapped_column(unique=True, index=True)


class APIKey(Base):
    __tablename__ = "api_keys"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenants.id"), index=True)
    key_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    plaintext: Mapped[str | None] = mapped_column(String(128), default=None)  # search keys only
    kind: Mapped[str] = mapped_column(String(10))  # "search" | "admin"
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())

    __table_args__ = (UniqueConstraint("tenant_id", "kind"),)


class SearchLog(Base):
    __tablename__ = "search_logs"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    tenant_id: Mapped[uuid.UUID] = mapped_column(index=True)
    query: Mapped[str] = mapped_column(String(500))
    result_count: Mapped[int] = mapped_column(Integer)
    timestamp: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())


class ProductStat(Base):
    __tablename__ = "product_stats"

    tenant_id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    product_id: Mapped[str] = mapped_column(String(255), primary_key=True)
    title: Mapped[str] = mapped_column(String(500))
    clicks: Mapped[int] = mapped_column(Integer, default=0)
    orders: Mapped[int] = mapped_column(Integer, default=0)
```

(`Tenant.owner_user_id` is intentionally not a FK to fastapi-users' `user` table to keep table creation order simple; uniqueness enforces the 1:1.)

- [ ] **Step 6: Run test to verify it passes**

Run: `cd backend && poetry run pytest tests/test_models.py -v`
Expected: PASS. (conftest imports `app.main`, unchanged so far, which is fine.)

- [ ] **Step 7: Commit**

```bash
git add backend/app/core/config.py backend/app/core/db.py backend/app/models.py backend/tests/test_models.py
git commit -m "feat: async SQLAlchemy core and multi-tenant models"
```

---

### Task 4: API key service

**Files:**
- Create: `backend/app/services/keys.py`
- Test: `backend/tests/test_keys.py`

**Interfaces:**
- Produces: `KEY_PREFIXES: dict`, `generate_key(kind) -> tuple[plaintext, key_hash]`, `hash_key(plaintext) -> str`, `async reset_key(session, tenant_id, kind) -> str` (returns plaintext), `async create_tenant_keys(session, tenant_id) -> dict[str, str]`, `async resolve_key(session, plaintext) -> APIKey | None`

- [ ] **Step 1: Write the failing test**

`backend/tests/test_keys.py`:

```python
import uuid


def test_generate_key_prefix_and_hash():
    from app.services.keys import generate_key, hash_key

    plaintext, digest = generate_key("search")
    assert plaintext.startswith("pb_search_")
    assert len(plaintext) > 20
    assert digest == hash_key(plaintext)
    assert len(digest) == 64  # sha256 hex

    admin_plain, _ = generate_key("admin")
    assert admin_plain.startswith("pb_admin_")


async def test_create_resolve_and_reset(client):
    from app.core.db import async_session_maker
    from app.models import Tenant
    from app.services.keys import create_tenant_keys, resolve_key, reset_key

    async with async_session_maker() as s:
        t = Tenant(name="Shop", owner_user_id=uuid.uuid4())
        s.add(t)
        await s.commit()
        keys = await create_tenant_keys(s, t.id)
        assert set(keys) == {"search", "admin"}

        found = await resolve_key(s, keys["search"])
        assert found is not None and found.kind == "search" and found.tenant_id == t.id
        assert found.plaintext == keys["search"]  # search key plaintext stored

        admin = await resolve_key(s, keys["admin"])
        assert admin.plaintext is None  # admin key never stored in plaintext

        new_plain = await reset_key(s, t.id, "search")
        assert new_plain != keys["search"]
        assert await resolve_key(s, keys["search"]) is None  # old key dead
        assert (await resolve_key(s, new_plain)).kind == "search"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_keys.py -v`
Expected: FAIL — `ModuleNotFoundError: app.services.keys`.

- [ ] **Step 3: Implement**

`backend/app/services/keys.py`:

```python
import hashlib
import secrets
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import APIKey

KEY_PREFIXES = {"search": "pb_search_", "admin": "pb_admin_"}


def hash_key(plaintext: str) -> str:
    return hashlib.sha256(plaintext.encode()).hexdigest()


def generate_key(kind: str) -> tuple[str, str]:
    plaintext = KEY_PREFIXES[kind] + secrets.token_urlsafe(32)
    return plaintext, hash_key(plaintext)


async def reset_key(session: AsyncSession, tenant_id: uuid.UUID, kind: str) -> str:
    plaintext, digest = generate_key(kind)
    row = (
        await session.execute(
            select(APIKey).where(APIKey.tenant_id == tenant_id, APIKey.kind == kind)
        )
    ).scalar_one_or_none()
    if row is None:
        row = APIKey(tenant_id=tenant_id, kind=kind, key_hash=digest)
        session.add(row)
    else:
        row.key_hash = digest
    row.plaintext = plaintext if kind == "search" else None
    await session.commit()
    return plaintext


async def create_tenant_keys(session: AsyncSession, tenant_id: uuid.UUID) -> dict[str, str]:
    return {kind: await reset_key(session, tenant_id, kind) for kind in ("search", "admin")}


async def resolve_key(session: AsyncSession, plaintext: str) -> APIKey | None:
    return (
        await session.execute(select(APIKey).where(APIKey.key_hash == hash_key(plaintext)))
    ).scalar_one_or_none()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && poetry run pytest tests/test_keys.py -v`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/keys.py backend/tests/test_keys.py
git commit -m "feat: dual API key service (public search key + hashed admin key)"
```

---

### Task 5: fastapi-users auth + tenant-on-register

**Files:**
- Create: `backend/app/core/users.py`, `backend/app/schemas.py`
- Modify: `backend/app/main.py`
- Test: `backend/tests/test_auth.py`

**Interfaces:**
- Consumes: `get_async_session`, models, `create_tenant_keys` (Task 3/4)
- Produces:
  - `app.core.users`: `fastapi_users` (FastAPIUsers instance), `auth_backend`, `current_active_user`, `optional_current_user`, `get_jwt_strategy()`
  - `app.schemas`: `UserRead`, `UserCreate`, `UserUpdate`
  - Routes: `POST /auth/register`, `POST /auth/jwt/login`, `GET /users/me`
  - Registration side effect: a `Tenant` + both `APIKey` rows exist for every new user.

- [ ] **Step 1: Write the failing test**

`backend/tests/test_auth.py`:

```python
from sqlalchemy import select


async def test_register_login_me(registered):
    client, token, email = registered
    r = await client.get("/users/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    assert r.json()["email"] == email


async def test_me_requires_auth(client):
    r = await client.get("/users/me")
    assert r.status_code == 401


async def test_register_creates_tenant_and_keys(registered):
    client, token, email = registered
    from app.core.db import async_session_maker
    from app.models import APIKey, Tenant, User

    async with async_session_maker() as s:
        user = (await s.execute(select(User).where(User.email == email))).scalar_one()
        tenant = (
            await s.execute(select(Tenant).where(Tenant.owner_user_id == user.id))
        ).scalar_one()
        kinds = {
            k.kind
            for k in (
                await s.execute(select(APIKey).where(APIKey.tenant_id == tenant.id))
            ).scalars()
        }
        assert kinds == {"search", "admin"}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_auth.py -v`
Expected: FAIL — `/auth/register` returns 404 (router not mounted).

- [ ] **Step 3: Write schemas**

`backend/app/schemas.py`:

```python
import uuid

from fastapi_users import schemas


class UserRead(schemas.BaseUser[uuid.UUID]):
    pass


class UserCreate(schemas.BaseUserCreate):
    pass


class UserUpdate(schemas.BaseUserUpdate):
    pass
```

- [ ] **Step 4: Write auth core**

`backend/app/core/users.py`:

```python
import uuid

from fastapi import Depends, Request
from fastapi_users import BaseUserManager, FastAPIUsers, UUIDIDMixin
from fastapi_users.authentication import (
    AuthenticationBackend,
    BearerTransport,
    JWTStrategy,
)
from fastapi_users_db_sqlalchemy import SQLAlchemyUserDatabase

from app.core.config import settings
from app.core.db import async_session_maker, get_async_session
from app.models import OAuthAccount, Tenant, User
from app.services.keys import create_tenant_keys


async def get_user_db(session=Depends(get_async_session)):
    yield SQLAlchemyUserDatabase(session, User, OAuthAccount)


class UserManager(UUIDIDMixin, BaseUserManager[User, uuid.UUID]):
    reset_password_token_secret = settings.SECRET_KEY
    verification_token_secret = settings.SECRET_KEY

    async def on_after_register(self, user: User, request: Request | None = None):
        async with async_session_maker() as session:
            tenant = Tenant(owner_user_id=user.id, name=user.email.split("@")[0])
            session.add(tenant)
            await session.commit()
            await create_tenant_keys(session, tenant.id)


async def get_user_manager(user_db=Depends(get_user_db)):
    yield UserManager(user_db)


bearer_transport = BearerTransport(tokenUrl="auth/jwt/login")


def get_jwt_strategy() -> JWTStrategy:
    return JWTStrategy(secret=settings.SECRET_KEY, lifetime_seconds=60 * 60 * 24 * 7)


auth_backend = AuthenticationBackend(
    name="jwt", transport=bearer_transport, get_strategy=get_jwt_strategy
)

fastapi_users = FastAPIUsers[User, uuid.UUID](get_user_manager, [auth_backend])
current_active_user = fastapi_users.current_user(active=True)
optional_current_user = fastapi_users.current_user(active=True, optional=True)
```

- [ ] **Step 5: Mount routers and fix the lifespan bug**

In `backend/app/main.py`: the existing `lifespan` function is defined but **never passed to FastAPI** (pre-existing bug). Replace the app construction and add auth routers:

```python
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
import os
from app.core.config import settings
from app.api.routes import ingestion, search, analytics, products
from fastapi.middleware.cors import CORSMiddleware
from app.core.db import create_db_and_tables
from app.core.users import auth_backend, fastapi_users
from app.schemas import UserCreate, UserRead, UserUpdate
from contextlib import asynccontextmanager


@asynccontextmanager
async def lifespan(app: FastAPI):
    await create_db_and_tables()
    yield


app = FastAPI(title="PolarBear API", version="0.2.0", lifespan=lifespan)

# Create static directory if not exists
os.makedirs("app/static/images", exist_ok=True)

# Mount Static Files
app.mount("/static", StaticFiles(directory="app/static"), name="static")

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(fastapi_users.get_auth_router(auth_backend), prefix="/auth/jwt", tags=["Auth"])
app.include_router(fastapi_users.get_register_router(UserRead, UserCreate), prefix="/auth", tags=["Auth"])
app.include_router(fastapi_users.get_users_router(UserRead, UserUpdate), prefix="/users", tags=["Auth"])
app.include_router(ingestion.router, prefix="/ingest", tags=["Ingestion"])
app.include_router(search.router, prefix="/search", tags=["Search"])
app.include_router(analytics.router, prefix="/analytics", tags=["Analytics"])
app.include_router(products.router, prefix="/products", tags=["Products"])


@app.get("/health")
def health_check():
    return {"status": "ok"}
```

(Delete the old `from app.core.database import init_db` import; `app/core/database.py` itself is removed in Task 11. The static-files mount changes in Task 7.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_auth.py -v`
Expected: PASS (3 tests). Also run the full suite: `poetry run pytest` — all green.

- [ ] **Step 7: Commit**

```bash
git add backend/app/core/users.py backend/app/schemas.py backend/app/main.py backend/tests/test_auth.py
git commit -m "feat: fastapi-users auth (register/login/JWT) with tenant+keys on register"
```

---

### Task 6: Tenant dependency + `/tenant/keys` routes

**Files:**
- Create: `backend/app/core/tenancy.py`, `backend/app/api/routes/tenant.py`
- Modify: `backend/app/main.py` (mount router)
- Test: `backend/tests/test_tenant_keys.py`

**Interfaces:**
- Consumes: `current_active_user`, `optional_current_user` (Task 5); `resolve_key`, `reset_key` (Task 4)
- Produces:
  - `app.core.tenancy`: `async get_current_tenant(user, session) -> Tenant` (JWT-scoped), `async resolve_search_tenant(request, user, session) -> uuid.UUID` (search key or JWT), `async resolve_admin_tenant(request, user, session) -> Tenant` (JWT or admin key; search key → 403)
  - Routes: `GET /tenant/keys` → `{"search": {"key": str, "created_at": ...}, "admin": {"key": null, "created_at": ...}}`; `POST /tenant/keys/{kind}/reset` → `{"kind": ..., "key": <new plaintext>}`

- [ ] **Step 1: Write the failing test**

`backend/tests/test_tenant_keys.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_tenant_keys.py -v`
Expected: FAIL — 404 on `/tenant/keys`.

- [ ] **Step 3: Implement tenancy dependencies**

`backend/app/core/tenancy.py`:

```python
import uuid

from fastapi import Depends, HTTPException, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import get_async_session
from app.core.users import current_active_user, optional_current_user
from app.models import Tenant, User
from app.services.keys import resolve_key


async def _tenant_for_user(session: AsyncSession, user: User) -> Tenant | None:
    return (
        await session.execute(select(Tenant).where(Tenant.owner_user_id == user.id))
    ).scalar_one_or_none()


async def get_current_tenant(
    user: User = Depends(current_active_user),
    session: AsyncSession = Depends(get_async_session),
) -> Tenant:
    tenant = await _tenant_for_user(session, user)
    if tenant is None:
        raise HTTPException(status_code=403, detail="No tenant for user")
    return tenant


async def resolve_search_tenant(
    request: Request,
    user: User | None = Depends(optional_current_user),
    session: AsyncSession = Depends(get_async_session),
) -> uuid.UUID:
    """Tenant for /search: public search key (X-PolarBear-Key header or ?key=) or JWT."""
    raw = request.headers.get("X-PolarBear-Key") or request.query_params.get("key")
    if raw:
        api_key = await resolve_key(session, raw)
        if api_key is None:
            raise HTTPException(status_code=401, detail="Invalid API key")
        return api_key.tenant_id
    if user is not None:
        tenant = await _tenant_for_user(session, user)
        if tenant is not None:
            return tenant.id
    raise HTTPException(status_code=401, detail="Missing API key or login")


async def resolve_admin_tenant(
    request: Request,
    user: User | None = Depends(optional_current_user),
    session: AsyncSession = Depends(get_async_session),
) -> Tenant:
    """Tenant for admin routes: JWT or admin key. A search key here is 403."""
    raw = request.headers.get("X-PolarBear-Key")
    if raw:
        api_key = await resolve_key(session, raw)
        if api_key is None:
            raise HTTPException(status_code=401, detail="Invalid API key")
        if api_key.kind != "admin":
            raise HTTPException(status_code=403, detail="Search key cannot perform admin actions")
        tenant = (
            await session.execute(select(Tenant).where(Tenant.id == api_key.tenant_id))
        ).scalar_one()
        return tenant
    if user is not None:
        tenant = await _tenant_for_user(session, user)
        if tenant is not None:
            return tenant
    raise HTTPException(status_code=401, detail="Missing credentials")
```

- [ ] **Step 4: Implement the routes**

`backend/app/api/routes/tenant.py`:

```python
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import get_async_session
from app.core.tenancy import get_current_tenant
from app.models import APIKey, Tenant
from app.services.keys import reset_key

router = APIRouter()


@router.get("/keys")
async def get_keys(
    tenant: Tenant = Depends(get_current_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    keys = (
        await session.execute(select(APIKey).where(APIKey.tenant_id == tenant.id))
    ).scalars()
    return {
        k.kind: {
            "key": k.plaintext if k.kind == "search" else None,
            "created_at": k.created_at.isoformat() if k.created_at else None,
        }
        for k in keys
    }


@router.post("/keys/{kind}/reset")
async def reset(
    kind: str,
    tenant: Tenant = Depends(get_current_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    if kind not in ("search", "admin"):
        raise HTTPException(status_code=400, detail="kind must be 'search' or 'admin'")
    plaintext = await reset_key(session, tenant.id, kind)
    return {"kind": kind, "key": plaintext}
```

In `backend/app/main.py` add:

```python
from app.api.routes import tenant
app.include_router(tenant.router, prefix="/tenant", tags=["Tenant"])
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_tenant_keys.py -v`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add backend/app/core/tenancy.py backend/app/api/routes/tenant.py backend/app/main.py backend/tests/test_tenant_keys.py
git commit -m "feat: tenancy dependencies and /tenant/keys endpoints"
```

---

### Task 7: Storage abstraction (Local + GCS)

**Files:**
- Create: `backend/app/services/storage.py`
- Modify: `backend/app/main.py` (static mount serves `{DATA_DIR}/public`)
- Test: `backend/tests/test_storage.py`

**Interfaces:**
- Produces:
  - `IndexStorage` Protocol: `read(tenant_id: str, name: str) -> bytes | None`, `write(tenant_id: str, name: str, data: bytes) -> None`, `write_public(tenant_id: str, name: str, data: bytes, content_type: str) -> str` (returns a public URL)
  - `LocalStorage(base_dir: str | None = None)` — files under `{DATA_DIR}/indexes/tenants/{tid}/` and `{DATA_DIR}/public/tenants/{tid}/`
  - `GCSStorage(bucket_name: str | None = None)` — blobs under `tenants/{tid}/`
  - `get_storage() -> IndexStorage` — picks by `settings.INDEX_STORAGE`

- [ ] **Step 1: Write the failing test**

`backend/tests/test_storage.py`:

```python
def test_local_storage_roundtrip(tmp_path):
    from app.services.storage import LocalStorage

    s = LocalStorage(base_dir=str(tmp_path))
    assert s.read("t1", "faiss.bin") is None
    s.write("t1", "faiss.bin", b"\x01\x02")
    assert s.read("t1", "faiss.bin") == b"\x01\x02"
    assert s.read("t2", "faiss.bin") is None  # tenant separation

    url = s.write_public("t1", "img.png", b"png", "image/png")
    assert url.endswith("/static/tenants/t1/img.png")
    assert (tmp_path / "public" / "tenants" / "t1" / "img.png").read_bytes() == b"png"


def test_get_storage_local_default():
    from app.services.storage import LocalStorage, get_storage

    assert isinstance(get_storage(), LocalStorage)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_storage.py -v`
Expected: FAIL — `ModuleNotFoundError: app.services.storage`.

- [ ] **Step 3: Implement**

`backend/app/services/storage.py`:

```python
from pathlib import Path
from typing import Protocol

from app.core.config import settings


class IndexStorage(Protocol):
    def read(self, tenant_id: str, name: str) -> bytes | None: ...
    def write(self, tenant_id: str, name: str, data: bytes) -> None: ...
    def write_public(self, tenant_id: str, name: str, data: bytes, content_type: str) -> str: ...


class LocalStorage:
    def __init__(self, base_dir: str | None = None):
        self.base = Path(base_dir or settings.DATA_DIR)

    def _path(self, tenant_id: str, name: str, public: bool = False) -> Path:
        area = "public" if public else "indexes"
        p = self.base / area / "tenants" / tenant_id / name
        p.parent.mkdir(parents=True, exist_ok=True)
        return p

    def read(self, tenant_id: str, name: str) -> bytes | None:
        p = self._path(tenant_id, name)
        return p.read_bytes() if p.exists() else None

    def write(self, tenant_id: str, name: str, data: bytes) -> None:
        self._path(tenant_id, name).write_bytes(data)

    def write_public(self, tenant_id: str, name: str, data: bytes, content_type: str) -> str:
        self._path(tenant_id, name, public=True).write_bytes(data)
        return f"{settings.PUBLIC_BACKEND_URL}/static/tenants/{tenant_id}/{name}"


class GCSStorage:
    def __init__(self, bucket_name: str | None = None):
        from google.cloud import storage as gcs

        self.bucket = gcs.Client().bucket(bucket_name or settings.GCS_BUCKET)

    def _blob(self, tenant_id: str, name: str):
        return self.bucket.blob(f"tenants/{tenant_id}/{name}")

    def read(self, tenant_id: str, name: str) -> bytes | None:
        blob = self._blob(tenant_id, name)
        return blob.download_as_bytes() if blob.exists() else None

    def write(self, tenant_id: str, name: str, data: bytes) -> None:
        self._blob(tenant_id, name).upload_from_string(data)

    def write_public(self, tenant_id: str, name: str, data: bytes, content_type: str) -> str:
        blob = self._blob(tenant_id, name)
        blob.upload_from_string(data, content_type=content_type)
        return blob.public_url


def get_storage() -> IndexStorage:
    if settings.INDEX_STORAGE == "gcs":
        return GCSStorage()
    return LocalStorage()
```

- [ ] **Step 4: Point the static mount at the public data dir**

In `backend/app/main.py`, replace the static setup:

```python
public_dir = os.path.join(settings.DATA_DIR, "public")
os.makedirs(public_dir, exist_ok=True)
app.mount("/static", StaticFiles(directory=public_dir), name="static")
```

(Remove `os.makedirs("app/static/images", ...)` — the old location is dead.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_storage.py -v` then `poetry run pytest`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/app/services/storage.py backend/app/main.py backend/tests/test_storage.py
git commit -m "feat: IndexStorage abstraction with Local and GCS backends"
```

---

### Task 8: Tenant-scoped indexer (embedding singleton, storage-backed FAISS)

**Files:**
- Create: `backend/app/services/search/embedding.py`, `backend/app/services/search/cache.py`
- Modify: `backend/app/services/search/indexer.py` (full rewrite)
- Test: `backend/tests/test_indexer.py`

**Interfaces:**
- Consumes: `IndexStorage`, `get_storage` (Task 7)
- Produces:
  - `embedding.get_model()` — process-wide singleton SentenceTransformer (monkeypatchable in tests via `embedding._model`)
  - `cache.get(tenant_id) -> tuple[faiss.Index, list] | None`, `cache.put(tenant_id, index, doc_ids)`, `cache.invalidate(tenant_id)`
  - `HybridIndexer(tenant_id: str, storage: IndexStorage | None = None, meili_client=None)` with `.index_name == f"products_{tenant_id}"`, `.index_data(new_documents: list[dict])`; FAISS bytes written as `faiss.serialize_index(...)` to `faiss.bin`, pickled id list to `doc_map.pkl`; calls `cache.invalidate(tenant_id)` after writing. Constants `HybridIndexer.FAISS_FILE = "faiss.bin"`, `HybridIndexer.DOC_MAP_FILE = "doc_map.pkl"`.

- [ ] **Step 1: Write the failing test**

`backend/tests/test_indexer.py`:

```python
import pickle
import numpy as np


class FakeModel:
    def encode(self, texts):
        return np.array(
            [[(hash(t) % 97) / 97.0] * 8 for t in texts], dtype="float32"
        )


class FakeMeiliIndex:
    def __init__(self):
        self.docs: dict[str, dict] = {}
        self.settings = None

    def get_documents(self, params):
        class R:
            pass

        r = R()
        r.results = list(self.docs.values())
        return r

    def update_settings(self, s):
        self.settings = s

    def add_documents(self, docs):
        for d in docs:
            self.docs[str(d["id"])] = d


class FakeMeiliClient:
    def __init__(self):
        self.indexes: dict[str, FakeMeiliIndex] = {}

    def index(self, name):
        return self.indexes.setdefault(name, FakeMeiliIndex())


def test_indexer_is_tenant_scoped_and_persists_to_storage(tmp_path, monkeypatch):
    from app.services.search import embedding

    monkeypatch.setattr(embedding, "_model", FakeModel())

    from app.services.search.indexer import HybridIndexer
    from app.services.storage import LocalStorage

    storage = LocalStorage(base_dir=str(tmp_path))
    meili = FakeMeiliClient()
    idx = HybridIndexer("tenant-a", storage=storage, meili_client=meili)

    assert idx.index_name == "products_tenant-a"

    idx.index_data([{"id": "1", "title": "Red Shoe", "description": "running"}])

    # Meilisearch got the doc in the tenant-scoped index
    assert "1" in meili.indexes["products_tenant-a"].docs

    # FAISS + doc_map persisted through storage under the tenant prefix
    assert storage.read("tenant-a", HybridIndexer.FAISS_FILE) is not None
    doc_ids = pickle.loads(storage.read("tenant-a", HybridIndexer.DOC_MAP_FILE))
    assert doc_ids == ["1"]

    # Nothing leaked into another tenant's space
    assert storage.read("tenant-b", HybridIndexer.FAISS_FILE) is None


def test_indexer_invalidates_cache(tmp_path, monkeypatch):
    from app.services.search import cache, embedding

    monkeypatch.setattr(embedding, "_model", FakeModel())
    from app.services.search.indexer import HybridIndexer
    from app.services.storage import LocalStorage

    cache.put("tenant-a", "stale-index", ["stale"])
    idx = HybridIndexer("tenant-a", storage=LocalStorage(str(tmp_path)), meili_client=FakeMeiliClient())
    idx.index_data([{"id": "1", "title": "X", "description": ""}])
    assert cache.get("tenant-a") is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_indexer.py -v`
Expected: FAIL — no `embedding` module / `HybridIndexer` signature mismatch.

- [ ] **Step 3: Implement embedding singleton and cache**

`backend/app/services/search/embedding.py`:

```python
_model = None


def get_model():
    global _model
    if _model is None:
        from sentence_transformers import SentenceTransformer

        _model = SentenceTransformer("all-MiniLM-L6-v2")
    return _model
```

`backend/app/services/search/cache.py`:

```python
"""Per-tenant in-memory cache of loaded FAISS indexes: {tenant_id: (index, doc_ids)}."""

_cache: dict[str, tuple] = {}


def get(tenant_id: str):
    return _cache.get(tenant_id)


def put(tenant_id: str, index, doc_ids) -> None:
    _cache[tenant_id] = (index, doc_ids)


def invalidate(tenant_id: str) -> None:
    _cache.pop(tenant_id, None)
```

- [ ] **Step 4: Rewrite the indexer**

Replace `backend/app/services/search/indexer.py`:

```python
import pickle

import faiss
import meilisearch
import numpy as np

from app.core.config import settings
from app.services.search import cache
from app.services.search.embedding import get_model
from app.services.storage import IndexStorage, get_storage


class HybridIndexer:
    FAISS_FILE = "faiss.bin"
    DOC_MAP_FILE = "doc_map.pkl"

    def __init__(self, tenant_id: str, storage: IndexStorage | None = None, meili_client=None):
        self.tenant_id = str(tenant_id)
        self.storage = storage or get_storage()
        self.meili_client = meili_client or meilisearch.Client(
            settings.MEILI_HOST, settings.MEILI_MASTER_KEY
        )
        self.index_name = f"products_{self.tenant_id}"

    def index_data(self, new_documents: list[dict]) -> None:
        """Merge new docs with existing ones, re-index Meilisearch, rebuild FAISS."""
        existing_docs: list[dict] = []
        try:
            results = self.meili_client.index(self.index_name).get_documents({"limit": 10000})
            existing_docs = [dict(d) for d in results.results]
        except Exception:
            existing_docs = []  # empty/new index

        merged = {str(d["id"]): d for d in existing_docs}
        for doc in new_documents:
            merged[str(doc["id"])] = doc
        all_documents = list(merged.values())

        index = self.meili_client.index(self.index_name)
        index.update_settings(
            {
                "searchableAttributes": ["title", "description", "brand", "category"],
                "filterableAttributes": ["brand", "category", "price", "tags"],
                "displayedAttributes": ["*"],
            }
        )
        index.add_documents(all_documents)

        texts = [f"{d.get('title', '')} {d.get('description', '')}" for d in all_documents]
        embeddings = np.array(get_model().encode(texts)).astype("float32")
        faiss_index = faiss.IndexFlatL2(embeddings.shape[1])
        faiss_index.add(embeddings)

        self.storage.write(
            self.tenant_id, self.FAISS_FILE, faiss.serialize_index(faiss_index).tobytes()
        )
        self.storage.write(
            self.tenant_id, self.DOC_MAP_FILE, pickle.dumps([d["id"] for d in all_documents])
        )
        cache.invalidate(self.tenant_id)
```

(The old `search_vectors` method is deleted — the searcher owns querying.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_indexer.py -v`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add backend/app/services/search/embedding.py backend/app/services/search/cache.py backend/app/services/search/indexer.py backend/tests/test_indexer.py
git commit -m "feat: tenant-scoped indexer with storage-backed FAISS and shared embedding model"
```

---

### Task 9: Tenant-scoped searcher with in-memory cache and degradation

**Files:**
- Modify: `backend/app/services/search/searcher.py` (full rewrite)
- Test: `backend/tests/test_searcher.py`

**Interfaces:**
- Consumes: `cache`, `embedding.get_model()`, `IndexStorage`, `HybridIndexer.FAISS_FILE/DOC_MAP_FILE` names (Tasks 7–8)
- Produces: `HybridSearcher(tenant_id: str, storage: IndexStorage | None = None, meili_client=None)` with `.search(query: str, limit: int = 20) -> list[dict]`. Loads FAISS via cache→storage; if storage/FAISS fails, returns keyword-only results (never raises for that path).

- [ ] **Step 1: Write the failing test**

`backend/tests/test_searcher.py`:

```python
import pickle
import numpy as np
from tests.test_indexer import FakeMeiliClient, FakeModel


class SearchableFakeIndex:
    """Extends the fake with search/get_document used by the searcher."""

    def __init__(self, docs):
        self.docs = docs

    def search(self, query, params):
        hits = [d for d in self.docs.values() if query.lower() in d["title"].lower()]
        return {"hits": hits[: params.get("limit", 20)]}

    def get_document(self, pid):
        if str(pid) in self.docs:
            return self.docs[str(pid)]
        raise KeyError(pid)


class SearchableFakeClient:
    def __init__(self, docs):
        self._index = SearchableFakeIndex(docs)

    def index(self, name):
        self.last_index_name = name
        return self._index


def _build_tenant_index(tmp_path, tenant_id, docs, monkeypatch):
    """Index docs for a tenant using the real indexer with fakes."""
    from app.services.search import embedding

    monkeypatch.setattr(embedding, "_model", FakeModel())
    from app.services.search.indexer import HybridIndexer
    from app.services.storage import LocalStorage

    storage = LocalStorage(str(tmp_path))
    fake = FakeMeiliClient()
    HybridIndexer(tenant_id, storage=storage, meili_client=fake).index_data(docs)
    return storage


def test_search_returns_tenant_results(tmp_path, monkeypatch):
    docs = {
        "1": {"id": "1", "title": "Red Running Shoe", "description": "fast"},
        "2": {"id": "2", "title": "Blue Hat", "description": "warm"},
    }
    storage = _build_tenant_index(tmp_path, "tenant-a", list(docs.values()), monkeypatch)

    from app.services.search.searcher import HybridSearcher

    s = HybridSearcher("tenant-a", storage=storage, meili_client=SearchableFakeClient(docs))
    results = s.search("shoe", limit=5)
    ids = [r["id"] for r in results]
    assert "1" in ids
    assert s.meili_client.last_index_name == "products_tenant-a"


def test_search_uses_cache_after_first_load(tmp_path, monkeypatch):
    docs = {"1": {"id": "1", "title": "Shoe", "description": ""}}
    storage = _build_tenant_index(tmp_path, "tenant-a", list(docs.values()), monkeypatch)

    from app.services.search import cache
    from app.services.search.searcher import HybridSearcher

    s = HybridSearcher("tenant-a", storage=storage, meili_client=SearchableFakeClient(docs))
    s.search("shoe")
    assert cache.get("tenant-a") is not None  # loaded and cached

    reads = []
    original_read = storage.read
    monkeypatch.setattr(
        storage, "read", lambda t, n: (reads.append(n), original_read(t, n))[1]
    )
    s.search("shoe")
    assert reads == []  # second search served from cache


def test_search_degrades_to_keyword_only_when_storage_fails(tmp_path, monkeypatch):
    docs = {"1": {"id": "1", "title": "Shoe", "description": ""}}

    from app.services.search import embedding
    monkeypatch.setattr(embedding, "_model", FakeModel())

    class BrokenStorage:
        def read(self, t, n):
            raise RuntimeError("gcs down")

        def write(self, t, n, d):
            raise RuntimeError("gcs down")

        def write_public(self, t, n, d, c):
            raise RuntimeError("gcs down")

    from app.services.search.searcher import HybridSearcher

    s = HybridSearcher("tenant-a", storage=BrokenStorage(), meili_client=SearchableFakeClient(docs))
    results = s.search("shoe")  # must NOT raise
    assert [r["id"] for r in results] == ["1"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_searcher.py -v`
Expected: FAIL — `HybridSearcher.__init__` signature mismatch (old version takes no tenant).

- [ ] **Step 3: Rewrite the searcher**

Replace `backend/app/services/search/searcher.py`:

```python
import pickle

import faiss
import meilisearch
import numpy as np

from app.core.config import settings
from app.services.search import cache
from app.services.search.embedding import get_model
from app.services.search.indexer import HybridIndexer
from app.services.storage import IndexStorage, get_storage

KEYWORD_WEIGHT = 0.3
VECTOR_WEIGHT = 0.7


class HybridSearcher:
    def __init__(self, tenant_id: str, storage: IndexStorage | None = None, meili_client=None):
        self.tenant_id = str(tenant_id)
        self.storage = storage or get_storage()
        self.meili_client = meili_client or meilisearch.Client(
            settings.MEILI_HOST, settings.MEILI_MASTER_KEY
        )
        self.index_name = f"products_{self.tenant_id}"

    def _load_faiss(self):
        """Return (faiss_index, doc_ids) from cache or storage; None if unavailable."""
        cached = cache.get(self.tenant_id)
        if cached is not None:
            return cached
        try:
            index_bytes = self.storage.read(self.tenant_id, HybridIndexer.FAISS_FILE)
            map_bytes = self.storage.read(self.tenant_id, HybridIndexer.DOC_MAP_FILE)
            if index_bytes is None or map_bytes is None:
                return None
            index = faiss.deserialize_index(np.frombuffer(index_bytes, dtype="uint8"))
            doc_ids = pickle.loads(map_bytes)
            cache.put(self.tenant_id, index, doc_ids)
            return index, doc_ids
        except Exception as e:
            print(f"WARNING: vector index unavailable for {self.tenant_id}: {e}")
            return None

    def search(self, query: str, limit: int = 20) -> list[dict]:
        # 1. Keyword search (Meilisearch)
        try:
            keyword_hits = self.meili_client.index(self.index_name).search(
                query, {"limit": limit}
            ).get("hits", [])
        except Exception as e:
            print(f"Meilisearch error for {self.tenant_id}: {e}")
            keyword_hits = []

        # 2. Vector search (FAISS) — degrade silently to keyword-only on failure
        vector_hits = []
        loaded = self._load_faiss()
        if loaded is not None:
            index, doc_ids = loaded
            try:
                query_vector = get_model().encode([query])
                query_vector = np.array(query_vector).astype("float32")
                distances, indices = index.search(query_vector, limit)
                for dist, idx in zip(distances[0], indices[0]):
                    if idx != -1 and idx < len(doc_ids):
                        vector_hits.append({"id": doc_ids[idx], "distance": float(dist)})
            except Exception as e:
                print(f"FAISS search error for {self.tenant_id}: {e}")

        # 3. Fuse scores
        scores: dict[str, dict] = {}
        for i, hit in enumerate(keyword_hits):
            pid = str(hit["id"])
            scores[pid] = {"score": (1.0 / (i + 1)) * KEYWORD_WEIGHT, "doc": hit}

        for hit in vector_hits:
            pid = str(hit["id"])
            v_score = (1.0 / (1.0 + hit["distance"])) * VECTOR_WEIGHT
            if pid in scores:
                scores[pid]["score"] += v_score
            else:
                try:
                    doc = self.meili_client.index(self.index_name).get_document(pid)
                    scores[pid] = {"score": v_score, "doc": dict(doc) if not isinstance(doc, dict) else doc}
                except Exception:
                    continue  # doc missing from keyword index; skip

        ranked = sorted(scores.values(), key=lambda s: s["score"], reverse=True)
        return [s["doc"] for s in ranked][:limit]
```

(Scoring math is intentionally unchanged from today — improving fusion is sub-project A. This rewrite only adds tenancy, caching, and degradation, and deletes the dead half-written merge block.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_searcher.py -v` then `poetry run pytest`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/search/searcher.py backend/tests/test_searcher.py
git commit -m "feat: tenant-scoped searcher with FAISS cache and keyword-only degradation"
```

---

### Task 10: Search route — key/JWT auth + async search logging

**Files:**
- Modify: `backend/app/api/routes/search.py` (full rewrite)
- Create: `backend/app/services/analytics_db.py` (async log helpers; full analytics move completes in Task 11)
- Test: `backend/tests/test_search_route.py`

**Interfaces:**
- Consumes: `resolve_search_tenant` (Task 6), `HybridSearcher` (Task 9)
- Produces:
  - `GET /search?q=...` honoring `X-PolarBear-Key` header, `?key=`, or JWT; 401 otherwise
  - `app.services.analytics_db`: `async log_search(tenant_id: uuid.UUID, query: str, result_count: int)`, `async track_product_event(tenant_id, event_type, product_id, title)`

- [ ] **Step 1: Write the failing test**

`backend/tests/test_search_route.py`:

```python
from sqlalchemy import select


class StubSearcher:
    def __init__(self, tenant_id, storage=None, meili_client=None):
        StubSearcher.last_tenant = str(tenant_id)

    def search(self, q, limit=20):
        return [{"id": "1", "title": "stub"}]


async def test_search_requires_key_or_jwt(client):
    r = await client.get("/search", params={"q": "shoe"})
    assert r.status_code == 401


async def test_search_with_invalid_key(client):
    r = await client.get("/search", params={"q": "shoe", "key": "pb_search_bogus"})
    assert r.status_code == 401


async def test_search_with_key_and_jwt(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import search as search_route

    monkeypatch.setattr(search_route, "HybridSearcher", StubSearcher)

    # via JWT
    r = await client.get(
        "/search", params={"q": "shoe"}, headers={"Authorization": f"Bearer {token}"}
    )
    assert r.status_code == 200
    assert r.json()["results"] == [{"id": "1", "title": "stub"}]

    # via public search key (header)
    keys = (await client.get("/tenant/keys", headers={"Authorization": f"Bearer {token}"})).json()
    search_key = keys["search"]["key"]
    r = await client.get("/search", params={"q": "shoe"}, headers={"X-PolarBear-Key": search_key})
    assert r.status_code == 200
    assert StubSearcher.last_tenant  # tenant resolved from key

    # search was logged with the tenant id
    from app.core.db import async_session_maker
    from app.models import SearchLog

    async with async_session_maker() as s:
        logs = (await s.execute(select(SearchLog))).scalars().all()
        assert len(logs) >= 2
        assert str(logs[-1].tenant_id) == StubSearcher.last_tenant
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_search_route.py -v`
Expected: FAIL — current `/search` has no auth (200 without key) and imports the old searcher signature.

- [ ] **Step 3: Implement async analytics helpers**

`backend/app/services/analytics_db.py`:

```python
import uuid

from sqlalchemy import select

from app.core.db import async_session_maker
from app.models import ProductStat, SearchLog


async def log_search(tenant_id: uuid.UUID, query: str, result_count: int) -> None:
    try:
        async with async_session_maker() as session:
            session.add(SearchLog(tenant_id=tenant_id, query=query, result_count=result_count))
            await session.commit()
    except Exception as e:
        print(f"Failed to log search: {e}")


async def track_product_event(
    tenant_id: uuid.UUID, event_type: str, product_id: str, title: str
) -> None:
    try:
        async with async_session_maker() as session:
            stat = (
                await session.execute(
                    select(ProductStat).where(
                        ProductStat.tenant_id == tenant_id,
                        ProductStat.product_id == product_id,
                    )
                )
            ).scalar_one_or_none()
            if stat is None:
                stat = ProductStat(
                    tenant_id=tenant_id, product_id=product_id, title=title, clicks=0, orders=0
                )
                session.add(stat)
            if event_type == "click":
                stat.clicks += 1
            elif event_type == "order":
                stat.orders += 1
            await session.commit()
    except Exception as e:
        print(f"Failed to track product event: {e}")
```

- [ ] **Step 4: Rewrite the search route**

Replace `backend/app/api/routes/search.py`:

```python
import uuid

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query

from app.core.tenancy import resolve_search_tenant
from app.services.analytics_db import log_search
from app.services.search.searcher import HybridSearcher

router = APIRouter()


@router.get("/")
async def search(
    background_tasks: BackgroundTasks,
    q: str = Query(..., min_length=1),
    limit: int = 20,
    tenant_id: uuid.UUID = Depends(resolve_search_tenant),
):
    """Hybrid search scoped to the tenant resolved from the search key or JWT."""
    searcher = HybridSearcher(str(tenant_id))
    try:
        results = searcher.search(q, limit)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    background_tasks.add_task(log_search, tenant_id, q, len(results))
    return {"query": q, "limit": limit, "total": len(results), "results": results}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_search_route.py -v`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add backend/app/api/routes/search.py backend/app/services/analytics_db.py backend/tests/test_search_route.py
git commit -m "feat: search route auth via search key or JWT, tenant-scoped logging"
```

---

### Task 11: Admin routes — ingestion, products (images via storage), analytics

**Files:**
- Modify: `backend/app/api/routes/ingestion.py`, `backend/app/api/routes/products.py`, `backend/app/api/routes/analytics.py` (full rewrites)
- Delete: `backend/app/core/database.py` (old sqlite layer)
- Test: `backend/tests/test_admin_routes.py`

**Interfaces:**
- Consumes: `resolve_admin_tenant`, `get_current_tenant` (Task 6), `HybridIndexer` (Task 8), `analytics_db` (Task 10), `storage.write_public` (Task 7)
- Produces: all admin routes require JWT or admin key; analytics queries filtered by `tenant_id`; product image upload returns a storage-backed public URL (no more hardcoded `http://localhost:8000`).

- [ ] **Step 1: Write the failing test**

`backend/tests/test_admin_routes.py`:

```python
import io


class RecordingIndexer:
    instances: list = []

    def __init__(self, tenant_id, storage=None, meili_client=None):
        self.tenant_id = str(tenant_id)
        RecordingIndexer.instances.append(self)

    def index_data(self, docs):
        self.docs = docs


CSV = b"id,title,description\n1,Red Shoe,fast\n"


async def test_ingest_requires_auth(client):
    files = {"file": ("p.csv", io.BytesIO(CSV), "text/csv")}
    r = await client.post("/ingest/upload", files=files)
    assert r.status_code == 401


async def test_search_key_rejected_on_admin_route(registered):
    client, token, _ = registered
    keys = (await client.get("/tenant/keys", headers={"Authorization": f"Bearer {token}"})).json()
    files = {"file": ("p.csv", io.BytesIO(CSV), "text/csv")}
    r = await client.post(
        "/ingest/upload", files=files, headers={"X-PolarBear-Key": keys["search"]["key"]}
    )
    assert r.status_code == 403


async def test_ingest_scopes_to_tenant(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import ingestion

    monkeypatch.setattr(ingestion, "HybridIndexer", RecordingIndexer)
    files = {"file": ("p.csv", io.BytesIO(CSV), "text/csv")}
    r = await client.post(
        "/ingest/upload", files=files, headers={"Authorization": f"Bearer {token}"}
    )
    assert r.status_code == 200, r.text
    assert len(RecordingIndexer.instances[-1].docs) == 1
    assert RecordingIndexer.instances[-1].tenant_id  # a real tenant uuid string


async def test_analytics_scoped_and_authed(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}

    assert (await client.get("/analytics/stats")).status_code == 401

    r = await client.post(
        "/analytics/track",
        json={"type": "click", "product_id": "1", "title": "Red Shoe"},
        headers=auth,
    )
    assert r.status_code == 200

    r = await client.get("/analytics/stats", headers=auth)
    assert r.status_code == 200
    body = r.json()
    assert body["product_stats"][0]["product_id"] == "1"
    assert body["product_stats"][0]["clicks"] == 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_admin_routes.py -v`
Expected: FAIL — routes currently unauthenticated (200/500 instead of 401/403).

- [ ] **Step 3: Rewrite ingestion route**

Replace `backend/app/api/routes/ingestion.py`:

```python
from fastapi import APIRouter, Depends, File, HTTPException, UploadFile

from app.core.tenancy import resolve_admin_tenant
from app.models import Tenant
from app.services.ingestion.parser import DataParser
from app.services.search.indexer import HybridIndexer

router = APIRouter()


@router.post("/upload")
async def upload_file(
    file: UploadFile = File(...),
    tenant: Tenant = Depends(resolve_admin_tenant),
):
    """Upload a CSV/Excel file, parse it, and index it into the caller's tenant."""
    if not file.filename.endswith((".csv", ".xls", ".xlsx")):
        raise HTTPException(status_code=400, detail="Only CSV and Excel are supported.")

    content = await file.read()
    try:
        documents = DataParser.parse_file(content, file.filename)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    if not documents:
        raise HTTPException(status_code=400, detail="File is empty or could not be parsed.")

    try:
        HybridIndexer(str(tenant.id)).index_data(documents)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    return {
        "status": "success",
        "message": f"Successfully processed {len(documents)} documents.",
        "filename": file.filename,
    }
```

- [ ] **Step 4: Rewrite products route**

Replace `backend/app/api/routes/products.py`:

```python
import uuid as uuid_mod
from typing import Optional

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from pydantic import BaseModel

from app.core.tenancy import resolve_admin_tenant
from app.models import Tenant
from app.services.search.indexer import HybridIndexer
from app.services.storage import get_storage

router = APIRouter()


class ProductUpdate(BaseModel):
    title: Optional[str] = None
    description: Optional[str] = None
    price: Optional[float] = None
    image_url: Optional[str] = None


def _index_for(tenant: Tenant):
    indexer = HybridIndexer(str(tenant.id))
    return indexer.meili_client.index(indexer.index_name)


@router.get("/")
async def list_products(
    limit: int = 100, offset: int = 0, tenant: Tenant = Depends(resolve_admin_tenant)
):
    try:
        results = _index_for(tenant).get_documents({"limit": limit, "offset": offset})
        return [dict(d) for d in results.results]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/{product_id}")
async def update_product(
    product_id: str, product: ProductUpdate, tenant: Tenant = Depends(resolve_admin_tenant)
):
    index = _index_for(tenant)
    try:
        existing = dict(index.get_document(product_id))
    except Exception:
        raise HTTPException(status_code=404, detail="Product not found")

    for field in ("title", "description", "price", "image_url"):
        value = getattr(product, field)
        if value is not None:
            existing[field] = value
    index.add_documents([existing])
    return {"status": "success", "product": existing}


@router.post("/{product_id}/image")
async def upload_product_image(
    product_id: str,
    file: UploadFile = File(...),
    tenant: Tenant = Depends(resolve_admin_tenant),
):
    if not file.content_type or not file.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="File must be an image")

    ext = file.filename.split(".")[-1] if "." in file.filename else "png"
    name = f"images/{product_id}_{uuid_mod.uuid4().hex[:8]}.{ext}"
    data = await file.read()
    image_url = get_storage().write_public(str(tenant.id), name, data, file.content_type)

    await update_product(product_id, ProductUpdate(image_url=image_url), tenant)
    return {"status": "success", "image_url": image_url}
```

- [ ] **Step 5: Rewrite analytics route and delete the old sqlite layer**

Replace `backend/app/api/routes/analytics.py`:

```python
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import desc, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import get_async_session
from app.core.tenancy import get_current_tenant
from app.models import ProductStat, SearchLog, Tenant
from app.services.analytics_db import track_product_event

router = APIRouter()


class TrackEvent(BaseModel):
    type: str  # 'click' | 'order'
    product_id: str
    title: str


@router.post("/track")
async def track_event(event: TrackEvent, tenant: Tenant = Depends(get_current_tenant)):
    if event.type not in ("click", "order"):
        raise HTTPException(status_code=400, detail="Invalid event type")
    await track_product_event(tenant.id, event.type, event.product_id, event.title)
    return {"status": "success"}


@router.get("/stats")
async def get_analytics(
    tenant: Tenant = Depends(get_current_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    tid = tenant.id
    total = (
        await session.execute(
            select(func.count()).select_from(SearchLog).where(SearchLog.tenant_id == tid)
        )
    ).scalar_one()

    top_q = select(SearchLog.query, func.count().label("count")).where(
        SearchLog.tenant_id == tid
    ).group_by(SearchLog.query).order_by(desc("count")).limit(10)
    top_queries = [{"query": q, "count": c} for q, c in (await session.execute(top_q))]

    zero_q = top_q.where(SearchLog.result_count == 0)
    zero_results = [{"query": q, "count": c} for q, c in (await session.execute(zero_q))]

    stats_q = select(ProductStat).where(ProductStat.tenant_id == tid).order_by(
        desc(ProductStat.orders), desc(ProductStat.clicks)
    )
    product_stats = [
        {"product_id": p.product_id, "title": p.title, "clicks": p.clicks, "orders": p.orders}
        for p in (await session.execute(stats_q)).scalars()
    ]

    return {
        "total_searches": total,
        "top_queries": top_queries,
        "zero_results": zero_results,
        "product_stats": product_stats,
    }
```

Delete the old layer:

```bash
git rm backend/app/core/database.py
```

(Verify nothing still imports it: `grep -rn "core.database" backend/app` must return nothing.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_admin_routes.py -v` then `poetry run pytest`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add -A backend/app backend/tests/test_admin_routes.py
git commit -m "feat: tenant-scoped admin routes; analytics on SQLAlchemy; images via storage"
```

---

### Task 12: Tenant isolation integration test (acceptance gate)

**Files:**
- Test: `backend/tests/test_isolation_integration.py`

**Interfaces:**
- Consumes: the full app (register → keys → ingest → search) with a **real Meilisearch**; FAISS via LocalStorage in tmp dir; FakeModel embeddings for speed.

- [ ] **Step 1: Write the integration test**

`backend/tests/test_isolation_integration.py`:

```python
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
    r = await client.get("/search", params={"q": q, "key": key})
    assert r.status_code == 200, r.text
    return {str(hit["id"]) for hit in r.json()["results"]}


async def test_two_tenants_cannot_see_each_other(client, monkeypatch):
    from app.services.search import embedding

    monkeypatch.setattr(embedding, "_model", FakeModel())

    token_a, key_a = await _register(client, "a@shop.com")
    token_b, key_b = await _register(client, "b@shop.com")

    await _upload(client, token_a, CSV_A)
    await _upload(client, token_b, CSV_B)
    time.sleep(2)  # Meilisearch task queue is async; small settle window

    # Keyword match: each tenant sees own product, not the other's
    assert "a1" in await _search_ids(client, key_a, "parka")
    assert "b1" not in await _search_ids(client, key_a, "towel")
    assert "b1" in await _search_ids(client, key_b, "towel")
    assert "a1" not in await _search_ids(client, key_b, "parka")

    # Cross-tenant product access via admin route is denied/empty
    r = await client.get("/products/", headers={"Authorization": f"Bearer {token_a}"})
    ids = {str(p["id"]) for p in r.json()}
    assert "b1" not in ids and "a1" in ids
```

- [ ] **Step 2: Run with Meilisearch up**

```bash
cd infrastructure && docker-compose up -d meilisearch && cd ../backend
poetry run pytest tests/test_isolation_integration.py -v -m integration
```

Expected: PASS. Without Meilisearch running, the test reports SKIPPED (verify by `docker-compose stop meilisearch` and re-running).

- [ ] **Step 3: Commit**

```bash
git add backend/tests/test_isolation_integration.py
git commit -m "test: tenant isolation integration acceptance gate"
```

---

### Task 13: Google OAuth (feature-flagged)

**Files:**
- Modify: `backend/app/core/users.py`, `backend/app/main.py`
- Test: `backend/tests/test_oauth_flag.py`

**Interfaces:**
- Produces: `GET /auth/providers` → `{"google": bool}`; when `GOOGLE_OAUTH_CLIENT_ID/SECRET` are set, `/auth/google/authorize` + `/auth/google/callback` exist and the callback **302-redirects to `{FRONTEND_URL}/login#token={jwt}`**.

- [ ] **Step 1: Write the failing test**

`backend/tests/test_oauth_flag.py`:

```python
async def test_providers_reports_google_disabled_by_default(client):
    r = await client.get("/auth/providers")
    assert r.status_code == 200
    assert r.json() == {"google": False}


async def test_google_routes_absent_when_disabled(client):
    r = await client.get("/auth/google/authorize")
    assert r.status_code == 404
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_oauth_flag.py -v`
Expected: FAIL — `/auth/providers` is 404.

- [ ] **Step 3: Implement**

Append to `backend/app/core/users.py`:

```python
from fastapi.responses import RedirectResponse
from httpx_oauth.clients.google import GoogleOAuth2

google_oauth_client = (
    GoogleOAuth2(settings.GOOGLE_OAUTH_CLIENT_ID, settings.GOOGLE_OAUTH_CLIENT_SECRET)
    if settings.GOOGLE_OAUTH_CLIENT_ID and settings.GOOGLE_OAUTH_CLIENT_SECRET
    else None
)


class FrontendRedirectTransport(BearerTransport):
    """After OAuth callback, hand the JWT to the frontend via URL fragment."""

    async def get_login_response(self, token: str):
        return RedirectResponse(
            f"{settings.FRONTEND_URL}/login#token={token}", status_code=302
        )


oauth_redirect_backend = AuthenticationBackend(
    name="jwt-oauth-redirect",
    transport=FrontendRedirectTransport(tokenUrl="auth/jwt/login"),
    get_strategy=get_jwt_strategy,
)
```

In `backend/app/main.py` add:

```python
from app.core.users import google_oauth_client, oauth_redirect_backend

@app.get("/auth/providers", tags=["Auth"])
def auth_providers():
    return {"google": google_oauth_client is not None}


if google_oauth_client is not None:
    app.include_router(
        fastapi_users.get_oauth_router(
            google_oauth_client,
            oauth_redirect_backend,
            settings.SECRET_KEY,
            associate_by_email=True,
            is_verified_by_default=True,
        ),
        prefix="/auth/google",
        tags=["Auth"],
    )
```

(`on_after_register` fires for OAuth-created users too, so tenants/keys are created the same way. Manual end-to-end Google verification happens at deploy time with real credentials; unit tests cover the flag behavior.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_oauth_flag.py -v` then `poetry run pytest`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/core/users.py backend/app/main.py backend/tests/test_oauth_flag.py
git commit -m "feat: feature-flagged Google OAuth with frontend redirect transport"
```

---

### Task 14: Infrastructure & docs — Postgres in compose, env reference, migration note

**Files:**
- Modify: `infrastructure/docker-compose.yml`, `README.md`
- Create: `backend/.env.example`

- [ ] **Step 1: Add Postgres to docker-compose**

In `infrastructure/docker-compose.yml`, add under `services:` (keep meilisearch as-is):

```yaml
  postgres:
    image: postgres:16-alpine
    environment:
      - POSTGRES_USER=polarbear
      - POSTGRES_PASSWORD=polarbear
      - POSTGRES_DB=polarbear
    ports:
      - '5432:5432'
    volumes:
      - pg_data:/var/lib/postgresql/data
    restart: always
```

And add `pg_data:` under `volumes:`.

- [ ] **Step 2: Create env reference**

`backend/.env.example`:

```bash
# Database — SQLite works out of the box; Postgres for production
DATABASE_URL=sqlite+aiosqlite:///./polarbear.db
# DATABASE_URL=postgresql+asyncpg://polarbear:polarbear@localhost:5432/polarbear

# Auth — MUST be changed in production
SECRET_KEY=dev-secret-change-me

# Meilisearch
MEILI_HOST=http://localhost:7700
MEILI_MASTER_KEY=masterKey

# Index & image storage: "local" (default) or "gcs"
INDEX_STORAGE=local
DATA_DIR=./data
# GCS_BUCKET=my-polarbear-indexes

# Public URLs
PUBLIC_BACKEND_URL=http://localhost:8000
FRONTEND_URL=http://localhost:3000

# Google OAuth (optional — login button hidden when unset)
# GOOGLE_OAUTH_CLIENT_ID=
# GOOGLE_OAUTH_CLIENT_SECRET=
```

- [ ] **Step 3: Update README**

In `README.md`:
1. In **Features**, change the Product Management bullet's intro area — add a bullet: `- **🔐 Multi-Tenant**: Register an account, get isolated indexes and API keys — one deployment serves many businesses.`
2. In **Quick Start**, after the "Start Frontend" step, replace the "Experience PolarBear" step with:

```markdown
5.  **Experience PolarBear**
    - **Register**: Go to `http://localhost:3000/login` and create an account.
    - **Upload Data**: Go to `http://localhost:3000/upload` and upload a CSV (e.g., `sample_products.csv`).
    - **Search**: Visit `http://localhost:3000/search` to try the hybrid search.
    - **API Keys**: Visit `http://localhost:3000/settings` to copy your public search key.
    - **Insights**: Check `http://localhost:3000/insights` for analytics and product management.

> **Upgrading from a pre-multi-tenant version?** Indexes are now per-account. After
> upgrading, register an account and re-upload your CSV — old data in the shared
> `products` index is not migrated automatically.
```

- [ ] **Step 4: Verify compose boots**

Run: `cd infrastructure && docker-compose up -d && docker-compose ps`
Expected: `meilisearch` and `postgres` both `Up`. Then `docker-compose down` (leave meilisearch up if continuing to Task 12's integration run).

- [ ] **Step 5: Commit**

```bash
git add infrastructure/docker-compose.yml backend/.env.example README.md
git commit -m "chore: add Postgres to compose, env reference, README multi-tenant docs"
```

---

### Task 15: Frontend — auth library, login page, Navbar account state

**Files:**
- Create: `frontend/src/lib/api.ts`, `frontend/src/app/login/page.tsx`
- Modify: `frontend/src/components/Navbar.tsx`

**Interfaces:**
- Produces (used by Tasks 16–17):
  - `lib/api.ts`: `API_URL: string`, `getToken()`, `setToken(t)`, `clearToken()`, `authFetch(path: string, init?: RequestInit): Promise<Response>` (adds `Authorization: Bearer`, redirects to `/login` on 401), `useRequireAuth()` React hook (redirects unauthenticated visitors to `/login`)

- [ ] **Step 1: Write the API library**

`frontend/src/lib/api.ts`:

```typescript
'use client';

import { useEffect } from 'react';
import { useRouter } from 'next/navigation';

export const API_URL = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8000';

export function getToken(): string | null {
  if (typeof window === 'undefined') return null;
  return localStorage.getItem('pb_token');
}

export function setToken(token: string) {
  localStorage.setItem('pb_token', token);
}

export function clearToken() {
  localStorage.removeItem('pb_token');
}

export async function authFetch(path: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  const token = getToken();
  if (token) headers.set('Authorization', `Bearer ${token}`);
  const res = await fetch(`${API_URL}${path}`, { ...init, headers });
  if (res.status === 401 && typeof window !== 'undefined') {
    clearToken();
    window.location.href = '/login';
  }
  return res;
}

export function useRequireAuth() {
  const router = useRouter();
  useEffect(() => {
    if (!getToken()) router.replace('/login');
  }, [router]);
}
```

- [ ] **Step 2: Write the login/register page**

`frontend/src/app/login/page.tsx` (centered-card style matching the Upload page; indigo accent; includes Google button shown only when the backend reports it enabled; consumes `#token=` fragment from the OAuth redirect):

```tsx
'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { API_URL, setToken } from '../../lib/api';

export default function LoginPage() {
  const router = useRouter();
  const [mode, setMode] = useState<'login' | 'register'>('login');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [googleEnabled, setGoogleEnabled] = useState(false);

  useEffect(() => {
    // OAuth redirect lands here with #token=<jwt>
    const hash = window.location.hash;
    if (hash.startsWith('#token=')) {
      setToken(hash.slice(7));
      router.replace('/');
      return;
    }
    fetch(`${API_URL}/auth/providers`)
      .then((r) => r.json())
      .then((d) => setGoogleEnabled(!!d.google))
      .catch(() => {});
  }, [router]);

  const doLogin = async () => {
    const body = new URLSearchParams({ username: email, password });
    const res = await fetch(`${API_URL}/auth/jwt/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
    });
    if (!res.ok) throw new Error('Invalid email or password.');
    const data = await res.json();
    setToken(data.access_token);
    router.push('/');
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setBusy(true);
    try {
      if (mode === 'register') {
        const res = await fetch(`${API_URL}/auth/register`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ email, password }),
        });
        if (!res.ok) {
          const d = await res.json().catch(() => ({}));
          throw new Error(typeof d.detail === 'string' ? d.detail : 'Registration failed.');
        }
      }
      await doLogin();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Something went wrong.');
    } finally {
      setBusy(false);
    }
  };

  const handleGoogle = async () => {
    const res = await fetch(`${API_URL}/auth/google/authorize`);
    const data = await res.json();
    window.location.href = data.authorization_url;
  };

  return (
    <div className="min-h-screen bg-gray-50 p-8">
      <div className="max-w-md mx-auto bg-white rounded-xl shadow-md p-6 mt-12">
        <div className="uppercase tracking-wide text-sm text-indigo-500 font-semibold mb-2">
          {mode === 'login' ? 'Welcome back' : 'Get started'}
        </div>
        <h1 className="text-lg font-medium text-black mb-6">
          {mode === 'login' ? 'Sign in to PolarBear' : 'Create your PolarBear account'}
        </h1>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="block text-gray-700 text-sm font-bold mb-2" htmlFor="email">
              Email
            </label>
            <input
              id="email"
              type="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="w-full border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
            />
          </div>
          <div>
            <label className="block text-gray-700 text-sm font-bold mb-2" htmlFor="password">
              Password
            </label>
            <input
              id="password"
              type="password"
              required
              minLength={8}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="w-full border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
            />
          </div>

          <button
            type="submit"
            disabled={busy}
            className={`w-full py-2 px-4 rounded-md text-sm font-medium text-white ${
              busy ? 'bg-gray-400 cursor-not-allowed' : 'bg-indigo-600 hover:bg-indigo-700'
            }`}
          >
            {busy ? 'Please wait…' : mode === 'login' ? 'Sign in' : 'Create account'}
          </button>
        </form>

        {googleEnabled && (
          <button
            onClick={handleGoogle}
            className="w-full mt-3 py-2 px-4 rounded-md text-sm font-medium border border-gray-300 text-gray-700 hover:bg-gray-50"
          >
            Continue with Google
          </button>
        )}

        {error && (
          <div className="mt-4 p-3 rounded bg-red-100 text-red-700 text-sm">{error}</div>
        )}

        <p className="mt-6 text-sm text-gray-500 text-center">
          {mode === 'login' ? (
            <>
              New to PolarBear?{' '}
              <button onClick={() => setMode('register')} className="text-indigo-600 hover:underline">
                Create an account
              </button>
            </>
          ) : (
            <>
              Already have an account?{' '}
              <button onClick={() => setMode('login')} className="text-indigo-600 hover:underline">
                Sign in
              </button>
            </>
          )}
        </p>
      </div>
    </div>
  );
}
```

- [ ] **Step 3: Update Navbar with account state**

Replace `frontend/src/components/Navbar.tsx`:

```tsx
'use client';

import Link from 'next/link';
import { useEffect, useState } from 'react';
import { authFetch, clearToken, getToken } from '../lib/api';

export default function Navbar() {
  const [email, setEmail] = useState<string | null>(null);

  useEffect(() => {
    if (!getToken()) return;
    authFetch('/users/me')
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => d && setEmail(d.email))
      .catch(() => {});
  }, []);

  const signOut = () => {
    clearToken();
    window.location.href = '/login';
  };

  const links = [
    { href: '/', label: 'Home' },
    { href: '/search', label: 'Search' },
    { href: '/upload', label: 'Upload' },
    { href: '/insights', label: 'Insights' },
    { href: '/settings', label: 'Settings' },
  ];

  return (
    <nav className="bg-white border-b border-gray-200">
      <div className="max-w-6xl mx-auto px-4">
        <div className="flex justify-between h-16">
          <div className="flex">
            <div className="flex-shrink-0 flex items-center">
              <Link href="/" className="text-xl font-bold text-indigo-600">
                PolarBear
              </Link>
            </div>
            <div className="hidden sm:ml-6 sm:flex sm:space-x-8">
              {links.map((l) => (
                <Link
                  key={l.href}
                  href={l.href}
                  className="border-transparent text-gray-500 hover:border-gray-300 hover:text-gray-700 inline-flex items-center px-1 pt-1 border-b-2 text-sm font-medium"
                >
                  {l.label}
                </Link>
              ))}
            </div>
          </div>
          <div className="flex items-center space-x-4">
            {email ? (
              <>
                <span className="text-sm text-gray-500">{email}</span>
                <button
                  onClick={signOut}
                  className="text-sm font-medium text-gray-500 hover:text-gray-700"
                >
                  Sign out
                </button>
              </>
            ) : (
              <Link href="/login" className="text-sm font-medium text-indigo-600 hover:text-indigo-700">
                Sign in
              </Link>
            )}
          </div>
        </div>
      </div>
    </nav>
  );
}
```

- [ ] **Step 4: Verify build**

Run: `cd frontend && npm run build`
Expected: build succeeds, `/login` route listed in output.

- [ ] **Step 5: Manual check**

With backend + frontend running: visit `http://localhost:3000/login`, register `test@example.com` / `password123` → redirected to Home, Navbar shows the email and Sign out works.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/lib/api.ts frontend/src/app/login/page.tsx frontend/src/components/Navbar.tsx
git commit -m "feat(frontend): auth library, login/register page, account-aware navbar"
```

---

### Task 16: Frontend — wire auth into upload, search, insights pages

**Files:**
- Modify: `frontend/src/app/upload/page.tsx`, `frontend/src/app/search/page.tsx`, `frontend/src/app/insights/page.tsx`

**Interfaces:**
- Consumes: `authFetch`, `useRequireAuth` from `lib/api` (Task 15)

- [ ] **Step 1: Guard and wire the Upload page**

In `frontend/src/app/upload/page.tsx`:
1. Add imports: `import { authFetch, useRequireAuth } from '../../lib/api';`
2. Add `useRequireAuth();` as the first line inside `UploadPage()`.
3. Delete the local `const API_URL = ...` line.
4. Replace the fetch call:

```typescript
      const response = await authFetch('/ingest/upload', {
        method: 'POST',
        body: formData,
      });
```

- [ ] **Step 2: Guard and wire the Search page**

In `frontend/src/app/search/page.tsx`:
1. Add imports: `import { authFetch, useRequireAuth } from '../../lib/api';`
2. Add `useRequireAuth();` as the first line inside `SearchPage()`.
3. Delete the local `const API_URL = ...` line.
4. Replace the search fetch:

```typescript
            const response = await authFetch(`/search?q=${encodeURIComponent(query)}`);
```

5. Replace the analytics track fetch:

```typescript
            await authFetch('/analytics/track', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    type,
                    product_id: product.id,
                    title: product.title,
                }),
            });
```

- [ ] **Step 3: Guard and wire the Insights page**

In `frontend/src/app/insights/page.tsx` (339 lines — same mechanical transformation):
1. Add imports: `import { authFetch, useRequireAuth } from '../../lib/api';`
2. Add `useRequireAuth();` as the first line of the page component.
3. Delete the local `const API_URL = ...` line.
4. Replace **every** `fetch(\`${API_URL}<path>\`, opts)` call with `authFetch('<path>', opts)` — this covers the analytics stats load, product list load, product update (PUT), and product image upload (POST). Search the file for `API_URL` afterwards; zero occurrences must remain.

- [ ] **Step 4: Verify build + grep**

Run: `cd frontend && npm run build && ! grep -rn "NEXT_PUBLIC_API_URL" src/app`
Expected: build passes; no page defines its own API_URL (only `src/lib/api.ts` references the env var).

- [ ] **Step 5: Manual check**

Signed out: visiting `/upload`, `/insights` redirects to `/login`. Signed in: upload `sample_products.csv` → success; search finds products; insights loads stats and catalog.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/app
git commit -m "feat(frontend): require auth and tenant-scoped requests on all admin pages"
```

---

### Task 17: Frontend — Settings page (API keys)

**Files:**
- Create: `frontend/src/app/settings/page.tsx`

**Interfaces:**
- Consumes: `GET /tenant/keys`, `POST /tenant/keys/{kind}/reset` (Task 6); `authFetch`, `useRequireAuth` (Task 15)

- [ ] **Step 1: Write the Settings page**

`frontend/src/app/settings/page.tsx`:

```tsx
'use client';

import { useEffect, useState } from 'react';
import { authFetch, useRequireAuth } from '../../lib/api';

interface KeyInfo {
  key: string | null;
  created_at: string | null;
}

export default function SettingsPage() {
  useRequireAuth();
  const [keys, setKeys] = useState<Record<string, KeyInfo>>({});
  const [freshAdminKey, setFreshAdminKey] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);

  const load = () => {
    authFetch('/tenant/keys')
      .then((r) => (r.ok ? r.json() : {}))
      .then(setKeys)
      .catch(() => {});
  };

  useEffect(load, []);

  const copy = async (label: string, value: string) => {
    await navigator.clipboard.writeText(value);
    setCopied(label);
    setTimeout(() => setCopied(null), 1500);
  };

  const reset = async (kind: 'search' | 'admin') => {
    if (!confirm(`Reset the ${kind} key? The old key stops working immediately.`)) return;
    const r = await authFetch(`/tenant/keys/${kind}/reset`, { method: 'POST' });
    if (r.ok) {
      const d = await r.json();
      if (kind === 'admin') setFreshAdminKey(d.key);
      load();
    }
  };

  return (
    <div className="min-h-screen bg-gray-50 p-8">
      <div className="max-w-2xl mx-auto bg-white rounded-xl shadow-md p-6">
        <div className="uppercase tracking-wide text-sm text-indigo-500 font-semibold mb-2">
          Settings
        </div>
        <h1 className="text-lg font-medium text-black mb-6">API Keys</h1>

        {/* Search key — public, always visible */}
        <div className="mb-6 p-4 border border-gray-200 rounded-lg">
          <div className="flex justify-between items-center mb-2">
            <h2 className="text-sm font-semibold text-gray-900">Public Search Key</h2>
            <button onClick={() => reset('search')} className="text-xs text-gray-500 hover:text-red-600">
              Reset
            </button>
          </div>
          <p className="text-xs text-gray-500 mb-3">
            Read-only. Safe to embed in your website — it can only run searches on your catalog.
          </p>
          <div className="flex items-center gap-2">
            <code className="flex-1 text-xs bg-gray-50 border border-gray-200 rounded px-2 py-2 overflow-x-auto whitespace-nowrap">
              {keys.search?.key ?? '—'}
            </code>
            {keys.search?.key && (
              <button
                onClick={() => copy('search', keys.search!.key!)}
                className="text-xs font-medium px-3 py-2 rounded bg-indigo-50 text-indigo-700 hover:bg-indigo-100"
              >
                {copied === 'search' ? 'Copied!' : 'Copy'}
              </button>
            )}
          </div>
        </div>

        {/* Admin key — plaintext only shown right after reset */}
        <div className="p-4 border border-gray-200 rounded-lg">
          <div className="flex justify-between items-center mb-2">
            <h2 className="text-sm font-semibold text-gray-900">Admin Key</h2>
            <button onClick={() => reset('admin')} className="text-xs text-gray-500 hover:text-red-600">
              Reset
            </button>
          </div>
          <p className="text-xs text-gray-500 mb-3">
            Full access to upload and edit your catalog. Keep it secret — it is shown only once,
            right after a reset.
          </p>
          <div className="flex items-center gap-2">
            <code className="flex-1 text-xs bg-gray-50 border border-gray-200 rounded px-2 py-2 overflow-x-auto whitespace-nowrap">
              {freshAdminKey ?? 'pb_admin_••••••••••••  (reset to reveal a new key)'}
            </code>
            {freshAdminKey && (
              <button
                onClick={() => copy('admin', freshAdminKey)}
                className="text-xs font-medium px-3 py-2 rounded bg-indigo-50 text-indigo-700 hover:bg-indigo-100"
              >
                {copied === 'admin' ? 'Copied!' : 'Copy'}
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Verify build**

Run: `cd frontend && npm run build`
Expected: build passes, `/settings` route listed.

- [ ] **Step 3: Manual check**

Signed in, visit `/settings`: search key displays with working Copy; Reset admin key reveals a fresh `pb_admin_...` once; after reload it shows the masked placeholder again. Signed out, `/settings` redirects to `/login`.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/app/settings/page.tsx
git commit -m "feat(frontend): settings page with public search key and admin key management"
```

---

## Final Verification (whole plan)

- [ ] `cd backend && poetry run pytest` — all unit tests pass
- [ ] `cd infrastructure && docker-compose up -d` then `cd ../backend && poetry run pytest -m integration` — isolation gate passes
- [ ] `cd frontend && npm run build` — clean build
- [ ] Manual end-to-end: register two accounts in two browser profiles, upload `sample_products.csv` to one and `sample_products_2.csv` to the other, confirm each account searches only its own catalog
- [ ] `git log --oneline` shows one commit per task
