from sqlalchemy import select


def test_normalize_origin_strips_scheme_www_port_and_path():
    from app.services.origins import normalize_origin

    assert normalize_origin("https://MyStore.com/shop") == "mystore.com"
    assert normalize_origin("http://www.mystore.com:8080") == "mystore.com"
    assert normalize_origin("mystore.com") == "mystore.com"
    assert normalize_origin(None) == "unknown"
    assert normalize_origin("") == "unknown"


async def test_install_ping_records_and_dedupes(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    key = (await client.get("/tenant/keys", headers=auth)).json()["search"]["key"]
    headers = {"X-PolarBear-Key": key, "Origin": "https://www.MyStore.com"}

    assert (await client.post("/analytics/install-ping", headers=headers)).status_code == 200
    assert (await client.post("/analytics/install-ping", headers=headers)).status_code == 200

    from app.core.db import async_session_maker
    from app.models import WidgetPing

    async with async_session_maker() as s:
        rows = (await s.execute(select(WidgetPing))).scalars().all()
        assert len(rows) == 1
        assert rows[0].origin == "mystore.com"
        assert rows[0].kind == "load"
        assert rows[0].count == 2


async def test_install_ping_without_origin_is_recorded_as_unknown(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    key = (await client.get("/tenant/keys", headers=auth)).json()["search"]["key"]

    r = await client.post("/analytics/install-ping", headers={"X-PolarBear-Key": key})
    assert r.status_code == 200

    from app.core.db import async_session_maker
    from app.models import WidgetPing

    async with async_session_maker() as s:
        rows = (await s.execute(select(WidgetPing))).scalars().all()
        assert [r.origin for r in rows] == ["unknown"]


async def test_install_ping_rejects_bad_key(client):
    r = await client.post(
        "/analytics/install-ping", headers={"X-PolarBear-Key": "pb_search_bogus"}
    )
    assert r.status_code == 401
    assert (await client.post("/analytics/install-ping")).status_code == 401
