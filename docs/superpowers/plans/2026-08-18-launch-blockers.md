# Launch Blockers (D1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the three gaps that make it irresponsible to open the hosted service to strangers — a forgotten password loses the account forever, nothing can be deleted, and the repository has no LICENSE.

**Architecture:** A dependency-free `smtplib` email module that degrades to logging the reset link when unconfigured; fastapi-users' existing reset router mounted and wired to it; three tenant-scoped delete endpoints with a storage-level `delete_tenant` so account destruction removes external objects before database rows; two new auth pages plus a Settings danger zone.

**Tech Stack:** FastAPI, fastapi-users, SQLAlchemy 2 async, Python stdlib `smtplib`, Next.js 16 + Tailwind 4, pytest.

**Spec:** `docs/superpowers/specs/2026-08-18-launch-blockers-design.md`

## Global Constraints

- Backend tests: `cd backend && poetry run pytest` (asyncio_mode=auto; existing `client` / `registered` conftest fixtures). Frontend: `cd frontend && npm run build`.
- **No new Python or npm dependencies.** Email uses stdlib `smtplib`/`email.message`.
- Email never breaks a request: a send failure is logged and swallowed, and `POST /auth/forgot-password` returns 202 whether or not the address exists — it must never reveal account existence.
- With `SMTP_HOST` unset, `send_password_reset` logs the full reset URL (`{FRONTEND_URL}/reset-password?token={token}`) and returns `False`; the flow still succeeds.
- Reset token lifetime is exactly 3600 seconds.
- Confirmation strings are exact: clearing a catalog requires body `{"confirm": "delete all products"}`; deleting an account requires body `{"email": "<the caller's own email>"}`.
- Account deletion order is external-first: Meilisearch index → storage objects (private + public) → DB rows `WidgetPing`, `SearchLog`, `ProductStat`, `APIKey`, `Tenant`, `User`. Every step is individually guarded — a failure is logged and the sequence continues.
- Deleting products must rebuild or clear the FAISS artifacts and invalidate the tenant's in-memory cache; a stale positional index would point at removed products.
- Delete endpoints use the existing `resolve_admin_tenant` (JWT or admin key; a search key gets 403, no credentials 401), except account deletion which additionally needs the signed-in `User` and so uses `current_active_user` + `get_current_tenant`.
- Frontend: Tailwind utilities only, no new packages, existing white / gray-border / `indigo-600` card style; destructive UI uses red.
- YAGNI (out of scope, D2 or later): CSV export, one-command compose, rate limiting, key domain binding, CORS tightening, email verification, soft delete.

---

### Task 1: Email service

**Files:**
- Create: `backend/app/services/email.py`
- Modify: `backend/app/core/config.py`
- Test: `backend/tests/test_email.py`

**Interfaces:**
- Produces:
  - `app.services.email`: `send_email(to: str, subject: str, body: str) -> bool`, `send_password_reset(to: str, token: str) -> bool`
  - `settings`: `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM`, `SMTP_TLS`

- [ ] **Step 1: Write the failing test**

`backend/tests/test_email.py`:

```python
def test_send_email_without_smtp_configured_returns_false(monkeypatch, capsys):
    from app.core.config import settings
    from app.services import email

    monkeypatch.setattr(settings, "SMTP_HOST", "")
    assert email.send_email("a@b.com", "Subject", "Body") is False
    assert "a@b.com" in capsys.readouterr().out


def test_password_reset_logs_the_link_when_unconfigured(monkeypatch, capsys):
    from app.core.config import settings
    from app.services import email

    monkeypatch.setattr(settings, "SMTP_HOST", "")
    monkeypatch.setattr(settings, "FRONTEND_URL", "https://app.example.com")

    assert email.send_password_reset("merchant@shop.com", "tok123") is False
    printed = capsys.readouterr().out
    assert "https://app.example.com/reset-password?token=tok123" in printed


def test_send_email_uses_smtp_when_configured(monkeypatch):
    from app.core.config import settings
    from app.services import email

    sent = {}

    class FakeSMTP:
        def __init__(self, host, port, timeout=None):
            sent["host"] = host
            sent["port"] = port

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def starttls(self):
            sent["tls"] = True

        def login(self, user, password):
            sent["login"] = user

        def send_message(self, msg):
            sent["to"] = msg["To"]
            sent["subject"] = msg["Subject"]

    monkeypatch.setattr(settings, "SMTP_HOST", "smtp.example.com")
    monkeypatch.setattr(settings, "SMTP_PORT", 587)
    monkeypatch.setattr(settings, "SMTP_USER", "user")
    monkeypatch.setattr(settings, "SMTP_PASSWORD", "pass")
    monkeypatch.setattr(settings, "SMTP_TLS", True)
    monkeypatch.setattr(email.smtplib, "SMTP", FakeSMTP)

    assert email.send_email("to@shop.com", "Hi", "Body") is True
    assert sent["host"] == "smtp.example.com"
    assert sent["tls"] is True
    assert sent["login"] == "user"
    assert sent["to"] == "to@shop.com"


def test_send_email_swallows_transport_errors(monkeypatch):
    from app.core.config import settings
    from app.services import email

    def boom(*a, **k):
        raise OSError("connection refused")

    monkeypatch.setattr(settings, "SMTP_HOST", "smtp.example.com")
    monkeypatch.setattr(email.smtplib, "SMTP", boom)

    assert email.send_email("to@shop.com", "Hi", "Body") is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_email.py -v`
Expected: FAIL — `ModuleNotFoundError: app.services.email`.

- [ ] **Step 3: Add the settings**

In `backend/app/core/config.py`, inside `class Settings`, after `GOOGLE_OAUTH_CLIENT_SECRET`:

```python
    # Email is optional: with SMTP_HOST unset, password-reset links are written
    # to the backend log so development and self-hosted installs still work.
    SMTP_HOST: str = os.getenv("SMTP_HOST", "")
    SMTP_PORT: int = int(os.getenv("SMTP_PORT", "587"))
    SMTP_USER: str = os.getenv("SMTP_USER", "")
    SMTP_PASSWORD: str = os.getenv("SMTP_PASSWORD", "")
    SMTP_FROM: str = os.getenv("SMTP_FROM", "polarbear@localhost")
    SMTP_TLS: bool = os.getenv("SMTP_TLS", "true").lower() == "true"
```

- [ ] **Step 4: Write the email module**

`backend/app/services/email.py`:

```python
"""Outbound email over plain SMTP.

No third-party service and no extra dependency: a self-hosted install points
this at its own mail server, and an install with nothing configured still
works because reset links are written to the log for an operator to relay.
"""

import smtplib
from email.message import EmailMessage

from app.core.config import settings


def send_email(to: str, subject: str, body: str) -> bool:
    """Returns True only when the message actually went out over SMTP."""
    if not settings.SMTP_HOST:
        print(f"[email] SMTP not configured - message for {to} not sent:\n{body}")
        return False

    message = EmailMessage()
    message["From"] = settings.SMTP_FROM
    message["To"] = to
    message["Subject"] = subject
    message.set_content(body)

    try:
        with smtplib.SMTP(settings.SMTP_HOST, settings.SMTP_PORT, timeout=10) as smtp:
            if settings.SMTP_TLS:
                smtp.starttls()
            if settings.SMTP_USER:
                smtp.login(settings.SMTP_USER, settings.SMTP_PASSWORD)
            smtp.send_message(message)
        return True
    except Exception as e:
        # A broken mailer must never break the request that triggered it.
        print(f"[email] failed to send to {to}: {e}")
        return False


def send_password_reset(to: str, token: str) -> bool:
    link = f"{settings.FRONTEND_URL}/reset-password?token={token}"
    body = (
        "Someone asked to reset the password for your PolarBear account.\n\n"
        f"Open this link to choose a new password:\n{link}\n\n"
        "The link expires in one hour. If this wasn't you, ignore this email - "
        "nothing has changed."
    )
    return send_email(to, "Reset your PolarBear password", body)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_email.py -v`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add backend/app/services/email.py backend/app/core/config.py backend/tests/test_email.py
git commit -m "feat: pluggable SMTP email that degrades to logging the link"
```

---

### Task 2: Password reset endpoints

**Files:**
- Modify: `backend/app/core/users.py`, `backend/app/main.py`
- Test: `backend/tests/test_password_reset.py`

**Interfaces:**
- Consumes: `send_password_reset(to, token)` (Task 1); `fastapi_users`, `UserManager` (existing).
- Produces: `POST /auth/forgot-password` (202 always), `POST /auth/reset-password`.

- [ ] **Step 1: Write the failing test**

`backend/tests/test_password_reset.py`:

```python
async def test_forgot_password_returns_202_and_captures_a_token(registered, monkeypatch):
    client, _, email_addr = registered
    captured = {}

    from app.core import users as users_module

    def fake_send(to, token):
        captured["to"] = to
        captured["token"] = token
        return True

    monkeypatch.setattr(users_module, "send_password_reset", fake_send)

    r = await client.post("/auth/forgot-password", json={"email": email_addr})
    assert r.status_code == 202
    assert captured["to"] == email_addr
    assert captured["token"]


async def test_reset_password_with_the_token_changes_the_password(registered, monkeypatch):
    client, _, email_addr = registered
    captured = {}

    from app.core import users as users_module

    def fake_send(to, token):
        captured["token"] = token
        return True

    monkeypatch.setattr(users_module, "send_password_reset", fake_send)

    await client.post("/auth/forgot-password", json={"email": email_addr})
    r = await client.post(
        "/auth/reset-password",
        json={"token": captured["token"], "password": "brandnewpass123"},
    )
    assert r.status_code == 200, r.text

    ok = await client.post(
        "/auth/jwt/login",
        data={"username": email_addr, "password": "brandnewpass123"},
    )
    assert ok.status_code == 200

    stale = await client.post(
        "/auth/jwt/login", data={"username": email_addr, "password": "pass12345"}
    )
    assert stale.status_code == 400


async def test_reset_password_rejects_a_garbage_token(client):
    r = await client.post(
        "/auth/reset-password", json={"token": "not-a-real-token", "password": "whatever123"}
    )
    assert r.status_code == 400


async def test_forgot_password_does_not_reveal_whether_an_account_exists(client, monkeypatch):
    from app.core import users as users_module

    calls = []

    def fake_send(to, token):
        calls.append(to)
        return True

    monkeypatch.setattr(users_module, "send_password_reset", fake_send)

    r = await client.post("/auth/forgot-password", json={"email": "nobody@nowhere.test"})
    assert r.status_code == 202
    assert calls == []  # nothing sent, but the caller cannot tell


async def test_forgot_password_succeeds_even_when_sending_fails(registered, monkeypatch):
    client, _, email_addr = registered
    from app.core import users as users_module

    def boom(to, token):
        raise OSError("mail server down")

    monkeypatch.setattr(users_module, "send_password_reset", boom)

    r = await client.post("/auth/forgot-password", json={"email": email_addr})
    assert r.status_code == 202
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_password_reset.py -v`
Expected: FAIL — `/auth/forgot-password` is 404 (router not mounted).

- [ ] **Step 3: Wire the manager hook**

In `backend/app/core/users.py`, add the import near the other app imports:

```python
from app.services.email import send_password_reset
```

Inside `class UserManager`, alongside the existing `reset_password_token_secret`
and `verification_token_secret` class attributes, add the lifetime, then add the
hook after `on_after_register`:

```python
    reset_password_token_lifetime_seconds = 3600

    async def on_after_forgot_password(
        self, user: User, token: str, request: Request | None = None
    ):
        # Never let a mail failure turn into a 500 - the caller must not be able
        # to tell whether the address exists or the mailer is down.
        try:
            send_password_reset(user.email, token)
        except Exception as e:
            print(f"[auth] password reset email failed for {user.email}: {e}")
```

- [ ] **Step 4: Mount the router**

In `backend/app/main.py`, next to the other fastapi-users routers:

```python
app.include_router(fastapi_users.get_reset_password_router(), prefix="/auth", tags=["Auth"])
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_password_reset.py tests/test_auth.py -v`
Expected: all PASS.

- [ ] **Step 6: Run the full suite**

Run: `cd backend && poetry run pytest`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add backend/app/core/users.py backend/app/main.py backend/tests/test_password_reset.py
git commit -m "feat: password reset endpoints wired to the email service"
```

---

### Task 3: Storage tenant deletion

**Files:**
- Modify: `backend/app/services/storage.py`
- Test: `backend/tests/test_storage_delete.py`

**Interfaces:**
- Produces: `IndexStorage.delete_tenant(tenant_id: str) -> None` implemented by `LocalStorage` (removes the tenant's index and public directories) and `GCSStorage` (deletes blobs under `tenants/{tenant_id}/` in both the private and the public bucket).

- [ ] **Step 1: Write the failing test**

`backend/tests/test_storage_delete.py`:

```python
def test_local_delete_tenant_removes_both_areas(tmp_path):
    from app.services.storage import LocalStorage

    s = LocalStorage(base_dir=str(tmp_path))
    s.write("t1", "faiss.bin", b"\x01")
    s.write_public("t1", "images/a.png", b"png", "image/png")
    s.write("t2", "faiss.bin", b"\x02")

    s.delete_tenant("t1")

    assert s.read("t1", "faiss.bin") is None
    assert not (tmp_path / "public" / "tenants" / "t1").exists()
    assert s.read("t2", "faiss.bin") == b"\x02"  # other tenants untouched


def test_local_delete_tenant_is_safe_when_nothing_exists(tmp_path):
    from app.services.storage import LocalStorage

    LocalStorage(base_dir=str(tmp_path)).delete_tenant("never-used")  # must not raise
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_storage_delete.py -v`
Expected: FAIL — `LocalStorage` has no attribute `delete_tenant`.

- [ ] **Step 3: Implement deletion**

In `backend/app/services/storage.py`, add `import shutil` at the top, then add
`delete_tenant` to the Protocol:

```python
class IndexStorage(Protocol):
    def read(self, tenant_id: str, name: str) -> bytes | None: ...
    def write(self, tenant_id: str, name: str, data: bytes) -> None: ...
    def write_public(self, tenant_id: str, name: str, data: bytes, content_type: str) -> str: ...
    def delete_tenant(self, tenant_id: str) -> None: ...
```

Add to `LocalStorage`:

```python
    def delete_tenant(self, tenant_id: str) -> None:
        """Remove every artifact belonging to one tenant."""
        for area in ("indexes", "public"):
            shutil.rmtree(self.base / area / "tenants" / tenant_id, ignore_errors=True)
```

Add to `GCSStorage`:

```python
    def delete_tenant(self, tenant_id: str) -> None:
        prefix = f"tenants/{tenant_id}/"
        for bucket in (self.bucket, self.public_bucket):
            for blob in bucket.list_blobs(prefix=prefix):
                blob.delete()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_storage_delete.py tests/test_storage.py -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/storage.py backend/tests/test_storage_delete.py
git commit -m "feat: storage-level tenant deletion for both backends"
```

---

### Task 4: Product and catalog deletion

**Files:**
- Modify: `backend/app/services/search/indexer.py`, `backend/app/api/routes/products.py`
- Test: `backend/tests/test_product_delete.py`

**Interfaces:**
- Consumes: `HybridIndexer(tenant_id, storage=None, meili_client=None)` with `index_data(docs)`, class constants `FAISS_FILE` / `DOC_MAP_FILE`, `cache.invalidate(tenant_id)` (existing); `resolve_admin_tenant` (existing).
- Produces:
  - `HybridIndexer.delete_document(product_id: str) -> bool` — removes one product and rebuilds the vector artifacts from what remains; returns False when the product was not there
  - `HybridIndexer.clear_all() -> int` — removes every product and the vector artifacts; returns how many were removed
  - `DELETE /products/{product_id}` and `DELETE /products/` (body `{"confirm": "delete all products"}`)

- [ ] **Step 1: Write the failing test**

`backend/tests/test_product_delete.py`:

```python
from tests.test_indexer import FakeModel


class DeletableFakeIndex:
    def __init__(self):
        self.docs: dict[str, dict] = {}

    def get_documents(self, params):
        class R:
            pass

        r = R()
        r.results = list(self.docs.values())
        return r

    def update_settings(self, s):
        pass

    def add_documents(self, docs):
        for d in docs:
            self.docs[str(d["id"])] = d

    def delete_document(self, pid):
        self.docs.pop(str(pid), None)

    def delete_all_documents(self):
        self.docs.clear()


class DeletableFakeClient:
    def __init__(self):
        self.indexes: dict[str, DeletableFakeIndex] = {}

    def index(self, name):
        return self.indexes.setdefault(name, DeletableFakeIndex())


def _indexer(tmp_path, monkeypatch):
    from app.services.search import embedding
    from app.services.search.indexer import HybridIndexer
    from app.services.storage import LocalStorage

    monkeypatch.setattr(embedding, "_model", FakeModel())
    return HybridIndexer(
        "tenant-a",
        storage=LocalStorage(str(tmp_path)),
        meili_client=DeletableFakeClient(),
    )


def test_delete_document_removes_it_and_rebuilds_vectors(tmp_path, monkeypatch):
    import pickle

    from app.services.search import cache
    from app.services.search.indexer import HybridIndexer

    idx = _indexer(tmp_path, monkeypatch)
    idx.index_data(
        [
            {"id": "1", "title": "Blue Mug", "description": ""},
            {"id": "2", "title": "Red Mug", "description": ""},
        ]
    )

    assert idx.delete_document("1") is True

    remaining = idx.meili_client.index(idx.index_name).docs
    assert list(remaining) == ["2"]

    doc_ids = pickle.loads(idx.storage.read("tenant-a", HybridIndexer.DOC_MAP_FILE))
    assert doc_ids == ["2"]
    assert cache.get("tenant-a") is None


def test_delete_missing_document_returns_false(tmp_path, monkeypatch):
    idx = _indexer(tmp_path, monkeypatch)
    idx.index_data([{"id": "1", "title": "Blue Mug", "description": ""}])
    assert idx.delete_document("nope") is False


def test_clear_all_empties_the_catalog_and_vectors(tmp_path, monkeypatch):
    import pickle

    from app.services.search import cache
    from app.services.search.indexer import HybridIndexer

    idx = _indexer(tmp_path, monkeypatch)
    idx.index_data(
        [
            {"id": "1", "title": "Blue Mug", "description": ""},
            {"id": "2", "title": "Red Mug", "description": ""},
        ]
    )

    assert idx.clear_all() == 2
    assert idx.meili_client.index(idx.index_name).docs == {}
    assert pickle.loads(idx.storage.read("tenant-a", HybridIndexer.DOC_MAP_FILE)) == []
    assert cache.get("tenant-a") is None


class RecordingIndexer:
    """Route-level stand-in so the tests don't need Meilisearch."""

    deleted: list = []
    cleared: list = []

    def __init__(self, tenant_id, storage=None, meili_client=None):
        self.tenant_id = str(tenant_id)

    def delete_document(self, pid):
        RecordingIndexer.deleted.append((self.tenant_id, pid))
        return pid != "missing"

    def clear_all(self):
        RecordingIndexer.cleared.append(self.tenant_id)
        return 7


async def test_delete_product_route(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import products

    monkeypatch.setattr(products, "HybridIndexer", RecordingIndexer)
    auth = {"Authorization": f"Bearer {token}"}

    r = await client.delete("/products/abc", headers=auth)
    assert r.status_code == 200, r.text
    assert RecordingIndexer.deleted[-1][1] == "abc"

    r = await client.delete("/products/missing", headers=auth)
    assert r.status_code == 404


async def test_clear_catalog_requires_the_exact_confirm_string(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import products

    monkeypatch.setattr(products, "HybridIndexer", RecordingIndexer)
    auth = {"Authorization": f"Bearer {token}"}

    r = await client.request("DELETE", "/products/", json={"confirm": "yes"}, headers=auth)
    assert r.status_code == 400

    r = await client.request(
        "DELETE", "/products/", json={"confirm": "delete all products"}, headers=auth
    )
    assert r.status_code == 200
    assert r.json()["deleted"] == 7


async def test_delete_requires_admin_credentials(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import products

    monkeypatch.setattr(products, "HybridIndexer", RecordingIndexer)
    keys = (
        await client.get("/tenant/keys", headers={"Authorization": f"Bearer {token}"})
    ).json()

    assert (await client.delete("/products/abc")).status_code == 401
    r = await client.delete("/products/abc", headers={"X-PolarBear-Key": keys["search"]["key"]})
    assert r.status_code == 403
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_product_delete.py -v`
Expected: FAIL — `HybridIndexer` has no `delete_document`, routes are 405.

- [ ] **Step 3: Add deletion to the indexer**

In `backend/app/services/search/indexer.py`, add these methods to
`HybridIndexer` after `index_data`:

```python
    def _fetch_all(self) -> list[dict]:
        """Every document currently in this tenant's keyword index."""
        try:
            results = self.meili_client.index(self.index_name).get_documents({"limit": 10000})
            return [dict(d) for d in results.results]
        except meilisearch.errors.MeilisearchApiError as e:
            if getattr(e, "code", None) != "index_not_found":
                raise
            return []

    def delete_document(self, product_id: str) -> bool:
        """Remove one product. Returns False when it wasn't there.

        The FAISS index is positional, so it must be rebuilt from what remains -
        deleting only from Meilisearch would leave vectors pointing at a product
        that no longer exists.
        """
        existing = self._fetch_all()
        remaining = [d for d in existing if str(d["id"]) != str(product_id)]
        if len(remaining) == len(existing):
            return False

        self.meili_client.index(self.index_name).delete_document(str(product_id))
        if remaining:
            self.index_data([])  # re-embeds and rewrites artifacts from what's left
        else:
            self._clear_vectors()
        cache.invalidate(self.tenant_id)
        return True

    def clear_all(self) -> int:
        """Remove every product and the vector artifacts. Returns the count removed."""
        count = len(self._fetch_all())
        try:
            self.meili_client.index(self.index_name).delete_all_documents()
        except Exception as e:
            print(f"Failed clearing Meilisearch documents for {self.tenant_id}: {e}")
        self._clear_vectors()
        cache.invalidate(self.tenant_id)
        return count

    def _clear_vectors(self) -> None:
        """Empty vector artifacts so a search finds nothing rather than ghosts."""
        self.storage.write(self.tenant_id, self.FAISS_FILE, b"")
        self.storage.write(self.tenant_id, self.DOC_MAP_FILE, pickle.dumps([]))
```

`index_data([])` merges an empty batch with what Meilisearch still holds, so it
rebuilds the artifacts from the surviving documents — exactly what
`delete_document` needs.

**Note on the empty FAISS artifact:** `_clear_vectors` writes an empty file
rather than deleting it. `HybridSearcher._load_faiss` wraps deserialization in
`try/except` and returns `None` on failure, degrading to keyword-only — so an
empty artifact is safe, and writing keeps both storage backends symmetric.

- [ ] **Step 4: Add the routes**

In `backend/app/api/routes/products.py`, add `Body` to the fastapi import and
append:

```python
@router.delete("/{product_id}")
async def delete_product(product_id: str, tenant: Tenant = Depends(resolve_admin_tenant)):
    """Remove one product from the catalog and the vector index."""
    try:
        removed = HybridIndexer(str(tenant.id)).delete_document(product_id)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    if not removed:
        raise HTTPException(status_code=404, detail="Product not found")
    return {"status": "success", "deleted": product_id}


@router.delete("/")
async def clear_catalog(
    confirm: str = Body(default="", embed=True),
    tenant: Tenant = Depends(resolve_admin_tenant),
):
    """Remove every product. Requires an explicit confirmation string."""
    if confirm != "delete all products":
        raise HTTPException(
            status_code=400,
            detail='Send {"confirm": "delete all products"} to clear the catalog.',
        )
    try:
        count = HybridIndexer(str(tenant.id)).clear_all()
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    return {"status": "success", "deleted": count}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_product_delete.py tests/test_indexer.py tests/test_admin_routes.py -v`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/app/services/search/indexer.py backend/app/api/routes/products.py backend/tests/test_product_delete.py
git commit -m "feat: delete a product or clear the whole catalog"
```

---

### Task 5: Account deletion

**Files:**
- Modify: `backend/app/api/routes/tenant.py`
- Test: `backend/tests/test_account_delete.py`

**Interfaces:**
- Consumes: `HybridIndexer` (Task 4), `get_storage().delete_tenant(tenant_id)` (Task 3), `current_active_user`, `get_current_tenant`, models `WidgetPing`, `SearchLog`, `ProductStat`, `APIKey`, `Tenant`, `User`.
- Produces: `DELETE /tenant/account` with body `{"email": "<caller's own email>"}` → `{"status": "deleted", "removed": {...}}`.

- [ ] **Step 1: Write the failing test**

`backend/tests/test_account_delete.py`:

```python
from sqlalchemy import func, select


class NoopIndexer:
    def __init__(self, tenant_id, storage=None, meili_client=None):
        pass

    def clear_all(self):
        return 0


async def _register(client, email):
    await client.post("/auth/register", json={"email": email, "password": "pass12345"})
    r = await client.post("/auth/jwt/login", data={"username": email, "password": "pass12345"})
    return r.json()["access_token"]


async def test_account_deletion_wipes_one_tenant_and_spares_the_other(registered, monkeypatch):
    client, token_a, email_a = registered
    from app.api.routes import tenant as tenant_routes

    monkeypatch.setattr(tenant_routes, "HybridIndexer", NoopIndexer)

    token_b = await _register(client, "keeper@shop.com")
    auth_a = {"Authorization": f"Bearer {token_a}"}
    auth_b = {"Authorization": f"Bearer {token_b}"}

    for auth in (auth_a, auth_b):
        await client.put("/tenant/website", json={"website_url": "shop.com"}, headers=auth)
        await client.post(
            "/analytics/track",
            json={"type": "click", "product_id": "p1", "title": "Thing"},
            headers=auth,
        )

    from app.core.db import async_session_maker
    from app.models import APIKey, ProductStat, Tenant, User

    async with async_session_maker() as s:
        user_a = (await s.execute(select(User).where(User.email == email_a))).unique().scalar_one()
        tenant_a = (
            await s.execute(select(Tenant).where(Tenant.owner_user_id == user_a.id))
        ).scalar_one()
        tenant_a_id = tenant_a.id

    r = await client.request("DELETE", "/tenant/account", json={"email": email_a}, headers=auth_a)
    assert r.status_code == 200, r.text

    async with async_session_maker() as s:
        tenants_left = (
            await s.execute(select(func.count()).select_from(Tenant).where(Tenant.id == tenant_a_id))
        ).scalar_one()
        assert tenants_left == 0

        for model in (APIKey, ProductStat):
            left = (
                await s.execute(
                    select(func.count()).select_from(model).where(model.tenant_id == tenant_a_id)
                )
            ).scalar_one()
            assert left == 0, f"{model.__name__} still has rows for the deleted tenant"

        users_left = (
            await s.execute(select(func.count()).select_from(User).where(User.email == email_a))
        ).scalar_one()
        assert users_left == 0

    stale = await client.post(
        "/auth/jwt/login", data={"username": email_a, "password": "pass12345"}
    )
    assert stale.status_code == 400

    keys_b = await client.get("/tenant/keys", headers=auth_b)
    assert keys_b.status_code == 200
    assert keys_b.json()["search"]["key"].startswith("pb_search_")
    stats_b = await client.get("/analytics/stats", headers=auth_b)
    assert stats_b.json()["product_stats"][0]["product_id"] == "p1"


async def test_account_deletion_requires_the_matching_email(registered, monkeypatch):
    client, token, _ = registered
    from app.api.routes import tenant as tenant_routes

    monkeypatch.setattr(tenant_routes, "HybridIndexer", NoopIndexer)

    r = await client.request(
        "DELETE",
        "/tenant/account",
        json={"email": "someone-else@shop.com"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 400


async def test_account_deletion_requires_auth(client):
    r = await client.request("DELETE", "/tenant/account", json={"email": "a@b.com"})
    assert r.status_code == 401


async def test_account_deletion_survives_a_broken_storage_backend(registered, monkeypatch):
    client, token, email_addr = registered
    from app.api.routes import tenant as tenant_routes

    monkeypatch.setattr(tenant_routes, "HybridIndexer", NoopIndexer)

    class Broken:
        def delete_tenant(self, tenant_id):
            raise RuntimeError("bucket unreachable")

    monkeypatch.setattr(tenant_routes, "get_storage", lambda: Broken())

    r = await client.request(
        "DELETE",
        "/tenant/account",
        json={"email": email_addr},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200, r.text

    from app.core.db import async_session_maker
    from app.models import User

    async with async_session_maker() as s:
        left = (
            await s.execute(select(func.count()).select_from(User).where(User.email == email_addr))
        ).scalar_one()
        assert left == 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_account_delete.py -v`
Expected: FAIL — `/tenant/account` is 405/404.

- [ ] **Step 3: Implement the route**

In `backend/app/api/routes/tenant.py`, add these imports:

```python
from sqlalchemy import delete as sql_delete

from app.core.users import current_active_user
from app.models import ProductStat, SearchLog, User, WidgetPing
from app.services.search.indexer import HybridIndexer
from app.services.storage import get_storage
```

Then append the route:

```python
class AccountDeletion(BaseModel):
    email: str


@router.delete("/account")
async def delete_account(
    payload: AccountDeletion,
    user: User = Depends(current_active_user),
    tenant: Tenant = Depends(get_current_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    """Destroy this tenant and every trace of its data.

    External resources go first: a half-finished delete that leaves database
    rows is recoverable, while orphaned indexes and objects are not even
    discoverable. Every step is guarded - a merchant must be able to leave even
    when an external service is down.
    """
    if payload.email.strip().lower() != user.email.lower():
        raise HTTPException(
            status_code=400, detail="Type your own email address to confirm deletion."
        )

    removed = {"search_index": False, "files": False}

    try:
        HybridIndexer(str(tenant.id)).clear_all()
        removed["search_index"] = True
    except Exception as e:
        print(f"[delete] search index for {tenant.id}: {e}")

    try:
        get_storage().delete_tenant(str(tenant.id))
        removed["files"] = True
    except Exception as e:
        print(f"[delete] stored files for {tenant.id}: {e}")

    for model in (WidgetPing, SearchLog, ProductStat, APIKey):
        await session.execute(sql_delete(model).where(model.tenant_id == tenant.id))
    await session.execute(sql_delete(Tenant).where(Tenant.id == tenant.id))
    await session.execute(sql_delete(User).where(User.id == user.id))
    await session.commit()

    removed["account"] = True
    return {"status": "deleted", "removed": removed}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_account_delete.py -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full suite**

Run: `cd backend && poetry run pytest`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add backend/app/api/routes/tenant.py backend/tests/test_account_delete.py
git commit -m "feat: account deletion that removes indexes, files and every row"
```

---

### Task 6: Frontend — reset pages and delete controls

**Files:**
- Create: `frontend/src/app/forgot-password/page.tsx`, `frontend/src/app/reset-password/page.tsx`
- Modify: `frontend/src/app/login/page.tsx`, `frontend/src/app/settings/page.tsx`, `frontend/src/app/insights/page.tsx`

**Interfaces:**
- Consumes: `POST /auth/forgot-password`, `POST /auth/reset-password` (Task 2), `DELETE /products/{id}`, `DELETE /products/` (Task 4), `DELETE /tenant/account` (Task 5); `API_URL`, `authFetch`, `clearToken` from `../../lib/api`.

- [ ] **Step 1: Create the forgot-password page**

`frontend/src/app/forgot-password/page.tsx`:

```tsx
'use client';

import { useState } from 'react';
import { API_URL } from '../../lib/api';

export default function ForgotPasswordPage() {
  const [email, setEmail] = useState('');
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    try {
      await fetch(`${API_URL}/auth/forgot-password`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email }),
      });
    } catch {
      /* the message below is deliberately the same either way */
    } finally {
      setBusy(false);
      setSent(true);
    }
  };

  return (
    <div className="min-h-screen bg-gray-50 p-8">
      <div className="max-w-md mx-auto bg-white rounded-xl shadow-md p-6 mt-12">
        <div className="uppercase tracking-wide text-sm text-indigo-500 font-semibold mb-2">
          Account recovery
        </div>
        <h1 className="text-lg font-medium text-black mb-6">Reset your password</h1>

        {sent ? (
          <p className="text-sm text-gray-700">
            If that address has an account, we&apos;ve sent a reset link. It expires in
            one hour.
          </p>
        ) : (
          <form onSubmit={submit} className="space-y-4">
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
            <button
              type="submit"
              disabled={busy}
              className={`w-full py-2 px-4 rounded-md text-sm font-medium text-white ${
                busy ? 'bg-gray-400 cursor-not-allowed' : 'bg-indigo-600 hover:bg-indigo-700'
              }`}
            >
              {busy ? 'Sending…' : 'Send reset link'}
            </button>
          </form>
        )}

        <p className="mt-6 text-sm text-gray-500 text-center">
          <a href="/login" className="text-indigo-600 hover:underline">
            Back to sign in
          </a>
        </p>
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Create the reset-password page**

`frontend/src/app/reset-password/page.tsx`:

```tsx
'use client';

import { Suspense, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { API_URL } from '../../lib/api';

function ResetForm() {
  const router = useRouter();
  const token = useSearchParams().get('token') ?? '';
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setBusy(true);
    try {
      const res = await fetch(`${API_URL}/auth/reset-password`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token, password }),
      });
      if (!res.ok) {
        setError('This reset link has expired or already been used — request a new one.');
        return;
      }
      router.push('/login');
    } catch {
      setError('Could not reach the server. Try again in a moment.');
    } finally {
      setBusy(false);
    }
  };

  if (!token) {
    return (
      <p className="text-sm text-gray-700">
        This link is missing its token.{' '}
        <a href="/forgot-password" className="text-indigo-600 hover:underline">
          Request a new one
        </a>
        .
      </p>
    );
  }

  return (
    <form onSubmit={submit} className="space-y-4">
      <div>
        <label className="block text-gray-700 text-sm font-bold mb-2" htmlFor="password">
          New password
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
        {busy ? 'Saving…' : 'Set new password'}
      </button>
      {error && <div className="p-3 rounded bg-red-100 text-red-700 text-sm">{error}</div>}
    </form>
  );
}

export default function ResetPasswordPage() {
  return (
    <div className="min-h-screen bg-gray-50 p-8">
      <div className="max-w-md mx-auto bg-white rounded-xl shadow-md p-6 mt-12">
        <div className="uppercase tracking-wide text-sm text-indigo-500 font-semibold mb-2">
          Account recovery
        </div>
        <h1 className="text-lg font-medium text-black mb-6">Choose a new password</h1>
        <Suspense fallback={<p className="text-sm text-gray-500">Loading…</p>}>
          <ResetForm />
        </Suspense>
      </div>
    </div>
  );
}
```

`useSearchParams` must sit inside a `Suspense` boundary or the Next.js build
fails during static generation — that is why the form is a separate component.

- [ ] **Step 3: Link it from the login page**

In `frontend/src/app/login/page.tsx`, directly after the submit form's closing
`</form>` tag, add:

```tsx
        <p className="mt-3 text-sm text-center">
          <a href="/forgot-password" className="text-gray-500 hover:text-indigo-600">
            Forgot your password?
          </a>
        </p>
```

- [ ] **Step 4: Add the Settings danger zone**

In `frontend/src/app/settings/page.tsx`, add `clearToken` to the existing
`../../lib/api` import, render `<DangerZone />` as the last child inside the
Settings card, and append this component to the file:

```tsx
function DangerZone() {
  const [email, setEmail] = useState('');
  const [expected, setExpected] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    authFetch('/users/me')
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => d && setExpected(d.email))
      .catch(() => {});
  }, []);

  const remove = async () => {
    if (!confirm('This permanently deletes your catalog, analytics and account. Continue?')) {
      return;
    }
    setBusy(true);
    setError('');
    const r = await authFetch('/tenant/account', {
      method: 'DELETE',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email }),
    });
    if (r.ok) {
      clearToken();
      window.location.href = '/login';
    } else {
      const d = await r.json().catch(() => ({}));
      setError(typeof d.detail === 'string' ? d.detail : 'Could not delete the account.');
      setBusy(false);
    }
  };

  const matches = expected !== '' && email.toLowerCase() === expected.toLowerCase();

  return (
    <div className="mt-6 p-4 border border-red-300 rounded-lg">
      <h2 className="text-sm font-semibold text-red-700 mb-1">Delete this account</h2>
      <p className="text-xs text-gray-600 mb-3">
        This removes your products, search index, images, analytics and API keys
        immediately and permanently. Your search box will stop working everywhere it is
        installed. Download anything you need first.
      </p>
      <div className="flex gap-2">
        <input
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder={expected || 'type your email to confirm'}
          className="flex-1 border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-red-500"
        />
        <button
          onClick={remove}
          disabled={busy || !matches}
          className={`text-sm font-medium px-4 py-2 rounded-md text-white ${
            busy || !matches ? 'bg-gray-400 cursor-not-allowed' : 'bg-red-600 hover:bg-red-700'
          }`}
        >
          {busy ? 'Deleting…' : 'Delete account'}
        </button>
      </div>
      {error && <div className="mt-3 p-3 rounded bg-red-100 text-red-700 text-sm">{error}</div>}
    </div>
  );
}
```

- [ ] **Step 5: Add delete controls to the product catalog**

In `frontend/src/app/insights/page.tsx`, inside the `ProductCatalog` component,
add these two handlers immediately before the component's `return` (use whatever
function the existing Refresh button calls in place of `load` if it differs):

```tsx
  const removeProduct = async (id: string, title: string) => {
    if (!confirm(`Delete "${title}"? This cannot be undone.`)) return;
    const r = await authFetch(`/products/${encodeURIComponent(id)}`, { method: 'DELETE' });
    if (r.ok) load();
  };

  const clearCatalog = async () => {
    if (!confirm('Delete every product in your catalog? This cannot be undone.')) return;
    const r = await authFetch('/products/', {
      method: 'DELETE',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ confirm: 'delete all products' }),
    });
    if (r.ok) load();
  };
```

In the catalog card header, next to the existing Refresh control, add:

```tsx
            <button onClick={clearCatalog} className="text-sm text-red-600 hover:text-red-800 ml-4">
              Clear catalog
            </button>
```

And in each product row's Actions cell, after the existing Edit control:

```tsx
                        <button
                          onClick={() => removeProduct(String(p.id), p.title)}
                          className="text-red-600 hover:text-red-800 ml-3"
                        >
                          Delete
                        </button>
```

- [ ] **Step 6: Verify build**

Run: `cd frontend && npm run build`
Expected: clean build listing `/forgot-password` and `/reset-password`.

- [ ] **Step 7: Commit**

```bash
git add frontend/src/app
git commit -m "feat(frontend): password reset pages, catalog deletes, account danger zone"
```

---

### Task 7: LICENSE and repository hygiene

**Files:**
- Create: `LICENSE`
- Delete: `Design Doc.gdoc`
- Modify: `README.md`, `backend/.env.example`

- [ ] **Step 1: Add the MIT LICENSE**

Create `LICENSE` at the repository root with the standard MIT text, copyright
line `Copyright (c) 2026 Tian Zhang`:

```
MIT License

Copyright (c) 2026 Tian Zhang

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Remove the Google Docs shortcut**

```bash
git rm "Design Doc.gdoc"
```

It is a 174-byte pointer that only resolves for its owner; the readable
`Design Doc.txt` stays.

- [ ] **Step 3: Document the SMTP settings**

Append to `backend/.env.example`:

```bash
# Email (optional). Without SMTP_HOST, password-reset links are written to the
# backend log instead of being emailed — fine for development and self-hosting.
# SMTP_HOST=smtp.example.com
# SMTP_PORT=587
# SMTP_USER=
# SMTP_PASSWORD=
# SMTP_FROM=polarbear@yourdomain.com
# SMTP_TLS=true
```

- [ ] **Step 4: Point the README at the license**

In `README.md`, replace the License section body with:

```markdown
Distributed under the MIT License — see [LICENSE](LICENSE) for the full text.
```

- [ ] **Step 5: Verify**

Run: `ls LICENSE && git status --short && grep -c SMTP_HOST backend/.env.example`
Expected: `LICENSE` exists, `Design Doc.gdoc` staged as deleted, the grep prints at least 1.

- [ ] **Step 6: Commit**

```bash
git add LICENSE README.md backend/.env.example
git commit -m "chore: add MIT LICENSE, document SMTP settings, drop the gdoc pointer"
```

---

## Final Verification (whole plan)

- [ ] `cd backend && poetry run pytest` — all green, including the new email, reset, storage-delete, product-delete and account-delete suites
- [ ] `cd frontend && npm run build` — clean, with `/forgot-password` and `/reset-password` in the route list
- [ ] **Acceptance gate**: with a local backend and no SMTP configured, `POST /auth/forgot-password` returns 202 and the reset URL appears in the backend log; opening that URL and setting a new password lets the account log in with it
- [ ] **Acceptance gate**: create two accounts with data, delete the first through `DELETE /tenant/account`, then confirm its login fails, its rows are gone, and the second account's keys and analytics still work
- [ ] `ls LICENSE` — present at the repository root
- [ ] `git log --oneline` shows one commit per task
