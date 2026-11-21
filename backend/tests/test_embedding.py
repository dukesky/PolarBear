"""The embedding model is loaded once per process and eagerly at startup."""

import sys
import threading
import time
import types

import pytest


class _CountingST:
    """Stands in for sentence_transformers.SentenceTransformer."""

    loads = 0
    encoded = []

    def __init__(self, name):
        type(self).loads += 1
        time.sleep(0.05)  # widen the race window for the concurrency test
        self.name = name

    def encode(self, texts):
        type(self).encoded.append(list(texts))
        return [[0.0] * 3 for _ in texts]


@pytest.fixture
def fake_st(monkeypatch):
    from app.services.search import embedding

    _CountingST.loads = 0
    _CountingST.encoded = []
    module = types.ModuleType("sentence_transformers")
    module.SentenceTransformer = _CountingST
    monkeypatch.setitem(sys.modules, "sentence_transformers", module)
    monkeypatch.setattr(embedding, "_model", None)
    return embedding


def test_get_model_loads_once_and_is_shared(fake_st):
    first = fake_st.get_model()
    assert fake_st.get_model() is first
    assert first.name == "all-MiniLM-L6-v2"
    assert _CountingST.loads == 1


def test_concurrent_first_calls_load_once(fake_st):
    results = []
    threads = [threading.Thread(target=lambda: results.append(fake_st.get_model())) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert _CountingST.loads == 1
    assert all(r is results[0] for r in results)


def test_load_model_warms_up_the_shared_model(fake_st):
    model = fake_st.load_model()
    assert model is fake_st.get_model()
    assert _CountingST.loads == 1
    assert _CountingST.encoded == [["warm-up"]]


async def test_lifespan_loads_model_before_serving(fake_st, tmp_path, monkeypatch):
    from app.core.config import settings
    from app.main import app, lifespan

    monkeypatch.setattr(settings, "DATA_DIR", str(tmp_path))
    async with lifespan(app):
        # Startup has finished: the model is already in memory.
        assert fake_st._model is not None
        assert _CountingST.loads == 1
    from app.core.db import Base, engine

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
