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
