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


def test_gcs_delete_tenant_removes_blobs_from_both_buckets(monkeypatch):
    """GCS is the production backend and deletion is irreversible, so the
    prefix and the two-bucket sweep are worth pinning down."""

    class FakeBlob:
        def __init__(self, name, registry):
            self.name = name
            self._registry = registry

        def delete(self):
            self._registry.remove(self.name)

    class FakeBucket:
        def __init__(self, names):
            self.names = list(names)

        def list_blobs(self, prefix=None):
            return [FakeBlob(n, self.names) for n in list(self.names) if n.startswith(prefix)]

    from app.services.storage import GCSStorage

    private = FakeBucket(["tenants/t1/faiss.bin", "tenants/t1/doc_map.pkl", "tenants/t2/faiss.bin"])
    public = FakeBucket(["tenants/t1/images/a.png", "tenants/t2/images/b.png"])

    storage = GCSStorage.__new__(GCSStorage)  # skip __init__, which would need real credentials
    storage.bucket = private
    storage.public_bucket = public

    storage.delete_tenant("t1")

    assert private.names == ["tenants/t2/faiss.bin"]
    assert public.names == ["tenants/t2/images/b.png"]


def test_gcs_delete_tenant_prefix_does_not_match_a_similarly_named_tenant(monkeypatch):
    class FakeBlob:
        def __init__(self, name, registry):
            self.name = name
            self._registry = registry

        def delete(self):
            self._registry.remove(self.name)

    class FakeBucket:
        def __init__(self, names):
            self.names = list(names)

        def list_blobs(self, prefix=None):
            return [FakeBlob(n, self.names) for n in list(self.names) if n.startswith(prefix)]

    from app.services.storage import GCSStorage

    # "t1" must not sweep away "t1-extra" — the trailing slash in the prefix is
    # what prevents that.
    private = FakeBucket(["tenants/t1/faiss.bin", "tenants/t1-extra/faiss.bin"])
    storage = GCSStorage.__new__(GCSStorage)
    storage.bucket = private
    storage.public_bucket = FakeBucket([])

    storage.delete_tenant("t1")

    assert private.names == ["tenants/t1-extra/faiss.bin"]
