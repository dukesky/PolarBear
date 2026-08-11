"""Per-tenant in-memory cache of loaded FAISS indexes: {tenant_id: (index, doc_ids)}."""

_cache: dict[str, tuple] = {}


def get(tenant_id: str):
    return _cache.get(tenant_id)


def put(tenant_id: str, index, doc_ids) -> None:
    _cache[tenant_id] = (index, doc_ids)


def invalidate(tenant_id: str) -> None:
    _cache.pop(tenant_id, None)
