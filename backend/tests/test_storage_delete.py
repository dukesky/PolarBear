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
