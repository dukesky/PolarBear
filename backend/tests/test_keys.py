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
