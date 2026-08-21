import pytest


async def test_missing_columns_are_added_to_an_existing_table(client):
    """Simulate an old DB: drop the newer columns, then re-run the shim."""
    from sqlalchemy import text

    from app.core.db import create_db_and_tables, engine

    async with engine.begin() as conn:
        await conn.execute(text("ALTER TABLE tenants DROP COLUMN website_url"))
        await conn.execute(text("ALTER TABLE tenants DROP COLUMN column_mapping"))

    await create_db_and_tables()

    async with engine.begin() as conn:
        rows = await conn.execute(text("SELECT website_url, column_mapping FROM tenants"))
        rows.fetchall()  # must not raise — columns exist again


def _column_names(sync_conn):
    from sqlalchemy import inspect

    return {c["name"] for c in inspect(sync_conn).get_columns("shim_probe")}


async def _fresh_probe_table():
    from sqlalchemy import text

    from app.core.db import engine

    async with engine.begin() as conn:
        await conn.execute(text("DROP TABLE IF EXISTS shim_probe"))
        await conn.execute(text("CREATE TABLE shim_probe (id INTEGER PRIMARY KEY)"))


async def _drop_probe_table():
    from sqlalchemy import text

    from app.core.db import engine

    async with engine.begin() as conn:
        await conn.execute(text("DROP TABLE IF EXISTS shim_probe"))


async def test_add_missing_columns_adds_a_shimmed_column(client, monkeypatch):
    """The shim in isolation: a table that predates a column ends up with it."""
    from app.core import db

    await _fresh_probe_table()
    monkeypatch.setattr(
        db, "MISSING_COLUMN_SHIM", [("shim_probe", "added_later", "BOOLEAN DEFAULT FALSE")]
    )

    async with db.engine.begin() as conn:
        assert "added_later" not in await conn.run_sync(_column_names)
        await conn.run_sync(db._add_missing_columns)
        assert "added_later" in await conn.run_sync(_column_names)

    await _drop_probe_table()


async def test_add_missing_columns_is_idempotent(client, monkeypatch):
    """Two workers starting at once: a second pass must not raise."""
    from app.core import db

    await _fresh_probe_table()
    monkeypatch.setattr(
        db, "MISSING_COLUMN_SHIM", [("shim_probe", "added_later", "BOOLEAN DEFAULT FALSE")]
    )

    async with db.engine.begin() as conn:
        await conn.run_sync(db._add_missing_columns)
        await conn.run_sync(db._add_missing_columns)  # must not raise

    await _drop_probe_table()


async def test_a_shim_that_cannot_apply_fails_startup(client, monkeypatch):
    """A DDL the database rejects must take the app down rather than being
    logged and forgotten — the alternative is serving traffic against a schema
    every query will fail on."""
    from app.core import db

    await _fresh_probe_table()
    monkeypatch.setattr(
        db, "MISSING_COLUMN_SHIM", [("shim_probe", "added_later", "NOT_A_REAL_TYPE(((")]
    )

    with pytest.raises(Exception):
        async with db.engine.begin() as conn:
            await conn.run_sync(db._add_missing_columns)

    await _drop_probe_table()
