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
