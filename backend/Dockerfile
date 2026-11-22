# PolarBear backend image (Cloud Run, linux/amd64, CPU only).
#
# Two stages: the first installs the locked dependencies into a virtualenv with
# Poetry, the second copies just that virtualenv into a clean image. Poetry and
# its own dependencies never reach the runtime image.
#
# poetry.lock is the source of truth. On Linux it pins the CPU-only torch wheel
# from the PyTorch CPU index (see pyproject.toml), so no CUDA/nvidia packages
# are installed - Cloud Run has no GPU.

# ---------------------------------------------------------------- build stage
FROM python:3.11-slim AS build

# Pinned to the version that wrote poetry.lock, so builds are reproducible.
ARG POETRY_VERSION=2.1.3
RUN pip install --no-cache-dir "poetry==${POETRY_VERSION}"

WORKDIR /app

# poetry.toml turns off install-time re-resolution, so the install follows the
# per-platform markers in poetry.lock exactly.
COPY pyproject.toml poetry.lock poetry.toml ./

# Runtime dependencies only (no pytest), into /app/.venv. All of them ship
# manylinux wheels, so no compiler is needed. --compile writes the .pyc files
# now; without them every cold start would recompile torch/transformers'
# Python sources (measured locally: ~4 s slower to become healthy).
RUN POETRY_VIRTUALENVS_IN_PROJECT=true poetry install --only main --no-root --compile --no-interaction --no-ansi \
    && rm -rf /root/.cache

# -------------------------------------------------------------- runtime stage
FROM python:3.11-slim

WORKDIR /app

COPY --from=build /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1

# Bake the embedding model into the image, so a cold instance never downloads it.
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L6-v2')"

# The model is in the image, so never call the Hugging Face Hub at runtime: it
# would only add network round-trips (and a dependency on the Hub being up) to
# every cold start.
ENV HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1

# Cloud Run gives this container 1 vCPU, but torch sizes its thread pool from
# the host and starts ~10 threads that then fight over that one core. Measured
# under --cpus 1: single-query encode ~110 ms -> ~10 ms, a 64-text index batch
# 1.6 s -> 0.6 s, and no case where one thread was slower.
ENV OMP_NUM_THREADS=1

# Copy application code
COPY . .

# Precompile the app's own modules too, and create the static directory
RUN python -m compileall -q app && mkdir -p app/static/images

# Expose port (Cloud Run uses 8080 by default)
ENV PORT=8080
EXPOSE 8080

# The app loads the embedding model during startup (see app/main.py lifespan),
# so the port only opens - and Cloud Run's startup probe only passes - once
# search is ready.
# Use sh to expand the PORT variable safely
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT}"]
