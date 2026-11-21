"""The one embedding model the whole process shares.

The model is loaded once and reused by every request and every tenant. The
app's lifespan calls `load_model()` at startup, so Cloud Run's startup probe
only passes once the model is in memory and a cold instance never spends a
shopper's first search loading it (that used to take >30 s). `get_model()`
still loads on demand, for scripts and tests that never run the lifespan.
"""

import threading

MODEL_NAME = "all-MiniLM-L6-v2"

_model = None
_lock = threading.Lock()


def get_model():
    global _model
    if _model is None:
        # Search runs in a thread pool, so two early requests could both see
        # None. The lock makes sure the model is still only loaded once.
        with _lock:
            if _model is None:
                from sentence_transformers import SentenceTransformer

                _model = SentenceTransformer(MODEL_NAME)
    return _model


def load_model():
    """Load the model and run one tiny encode, so the first real query pays
    for neither the load nor torch's first-call setup."""
    model = get_model()
    model.encode(["warm-up"])
    return model
