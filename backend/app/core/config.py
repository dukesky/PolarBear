import os


class Settings:
    PROJECT_NAME: str = "PolarBear"
    MEILI_HOST: str = os.getenv("MEILI_HOST", "http://localhost:7700")
    MEILI_MASTER_KEY: str = os.getenv("MEILI_MASTER_KEY", "masterKey")
    DATABASE_URL: str = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./polarbear.db")
    SECRET_KEY: str = os.getenv("SECRET_KEY", "dev-secret-change-me")
    INDEX_STORAGE: str = os.getenv("INDEX_STORAGE", "local")  # "local" | "gcs"
    GCS_BUCKET: str = os.getenv("GCS_BUCKET", "")
    # Public bucket for merchant images (world-readable). Keep separate from
    # GCS_BUCKET, which holds private per-tenant indexes. Falls back to
    # GCS_BUCKET when unset.
    GCS_PUBLIC_BUCKET: str = os.getenv("GCS_PUBLIC_BUCKET", "")
    DATA_DIR: str = os.getenv("DATA_DIR", "./data")
    PUBLIC_BACKEND_URL: str = os.getenv("PUBLIC_BACKEND_URL", "http://localhost:8000")
    FRONTEND_URL: str = os.getenv("FRONTEND_URL", "http://localhost:3000")
    GOOGLE_OAUTH_CLIENT_ID: str = os.getenv("GOOGLE_OAUTH_CLIENT_ID", "")
    GOOGLE_OAUTH_CLIENT_SECRET: str = os.getenv("GOOGLE_OAUTH_CLIENT_SECRET", "")


settings = Settings()
