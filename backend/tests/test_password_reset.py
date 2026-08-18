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
