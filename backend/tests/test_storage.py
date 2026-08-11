def test_local_storage_roundtrip(tmp_path):
    from app.services.storage import LocalStorage

    s = LocalStorage(base_dir=str(tmp_path))
    assert s.read("t1", "faiss.bin") is None
    s.write("t1", "faiss.bin", b"\x01\x02")
    assert s.read("t1", "faiss.bin") == b"\x01\x02"
    assert s.read("t2", "faiss.bin") is None  # tenant separation

    url = s.write_public("t1", "img.png", b"png", "image/png")
    assert url.endswith("/static/tenants/t1/img.png")
    assert (tmp_path / "public" / "tenants" / "t1" / "img.png").read_bytes() == b"png"


def test_get_storage_local_default():
    from app.services.storage import LocalStorage, get_storage

    assert isinstance(get_storage(), LocalStorage)
