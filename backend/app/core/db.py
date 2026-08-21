from collections.abc import AsyncGenerator

from sqlalchemy import inspect, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from app.core.config import settings


class Base(DeclarativeBase):
    pass


engine = create_async_engine(settings.DATABASE_URL)
async_session_maker = async_sessionmaker(engine, expire_on_commit=False)

# `Base.metadata.create_all` only creates tables that don't exist yet — it
# never adds columns to a table that's already there. Any column added to a
# model after its table has shipped to production needs an entry here so
# existing deployments pick it up on next startup. (table, column, DDL type)
MISSING_COLUMN_SHIM: list[tuple[str, str, str]] = [
    ("tenants", "column_mapping", "TEXT"),
    ("tenants", "website_url", "VARCHAR(255)"),
    # DEFAULT FALSE, not DEFAULT 0: Postgres has no implicit cast from integer
    # to boolean in a DEFAULT expression and rejects the ALTER outright, while
    # SQLite accepts either. Both engines accept FALSE.
    ("tenants", "restrict_key_to_website", "BOOLEAN DEFAULT FALSE"),
]


def _add_missing_columns(sync_conn) -> None:
    """Idempotent `ALTER TABLE ... ADD COLUMN` for anything in
    MISSING_COLUMN_SHIM that the existing table is missing. Works on both
    SQLite and Postgres via the sync inspector; safe to run on every
    startup and never raises on a column that's already there."""
    inspector = inspect(sync_conn)
    existing_tables = set(inspector.get_table_names())
    for table, column, ddl_type in MISSING_COLUMN_SHIM:
        if table not in existing_tables:
            continue  # create_all will make the whole table, columns included
        existing_columns = {c["name"] for c in inspector.get_columns(table)}
        if column in existing_columns:
            continue
        try:
            sync_conn.execute(text(f"ALTER TABLE {table} ADD COLUMN {column} {ddl_type}"))
            print(f"[db] added missing column {table}.{column} ({ddl_type})")
        except Exception as e:
            # A schema-shim race (two workers starting at once) is survivable:
            # the other worker's ALTER already added the column, so a fresh
            # inspection finds it and there is nothing left to do. Anything
            # else means this DDL cannot apply to this database — and an app
            # that starts against a schema every query will fail on is worse
            # than one that refuses to start, so re-raise.
            fresh = inspect(sync_conn)
            if column not in {c["name"] for c in fresh.get_columns(table)}:
                print(f"[db] cannot add {table}.{column}: {e}")
                raise
            print(f"[db] {table}.{column} was added concurrently: {e}")


async def create_db_and_tables() -> None:
    from app import models  # noqa: F401  — register tables on Base

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await conn.run_sync(_add_missing_columns)


async def get_async_session() -> AsyncGenerator[AsyncSession, None]:
    async with async_session_maker() as session:
        yield session
