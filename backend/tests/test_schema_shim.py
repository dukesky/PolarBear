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


async def test_a_column_added_concurrently_does_not_fail_startup(client, monkeypatch):
    """The two-worker race the except branch exists for.

    Worker B looks, sees the column missing, and by the time its ALTER runs
    worker A has already added it — so the ALTER fails with a duplicate column
    and startup has to survive it. Running the shim twice does NOT test this:
    the second pass short-circuits on the `column in existing_columns` guard
    and never enters the try at all.

    This also covers the SAVEPOINT. The whole shim runs inside one transaction,
    and on Postgres a failed statement poisons it — the except branch's own
    reflection query would then raise InFailedSqlTransaction rather than
    reporting anything. begin_nested() rolls back only the failed ALTER.
    """
    from sqlalchemy import inspect as real_inspect
    from sqlalchemy import text

    from app.core import db

    await _fresh_probe_table()
    # The column is already there, as if the other worker had just added it.
    async with db.engine.begin() as conn:
        await conn.execute(
            text("ALTER TABLE shim_probe ADD COLUMN added_later BOOLEAN DEFAULT FALSE")
        )

    monkeypatch.setattr(
        db, "MISSING_COLUMN_SHIM", [("shim_probe", "added_later", "BOOLEAN DEFAULT FALSE")]
    )

    class HidesTheColumn:
        """Worker B's pre-ALTER view: A's column is not visible yet."""

        def __init__(self, real):
            self._real = real

        def get_table_names(self):
            return self._real.get_table_names()

        def get_columns(self, table):
            return [c for c in self._real.get_columns(table) if c["name"] != "added_later"]

    calls = {"n": 0}

    def fake_inspect(conn):
        calls["n"] += 1
        real = real_inspect(conn)
        # Only the guard's inspection is stale. The except branch's fresh
        # inspection must see the truth, which is the whole point of it.
        return HidesTheColumn(real) if calls["n"] == 1 else real

    monkeypatch.setattr(db, "inspect", fake_inspect)

    async with db.engine.begin() as conn:
        await conn.run_sync(db._add_missing_columns)  # must not raise
        # The connection is still usable after the failed ALTER — without the
        # savepoint this is where a Postgres transaction would already be dead.
        assert "added_later" in await conn.run_sync(_column_names)
        await conn.execute(text("INSERT INTO shim_probe (id) VALUES (1)"))

    assert calls["n"] >= 2, "the except branch never re-inspected"
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
