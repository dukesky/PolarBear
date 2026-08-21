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
    # Email is optional: with SMTP_HOST unset, password-reset links are written
    # to the backend log so development and self-hosted installs still work.
    SMTP_HOST: str = os.getenv("SMTP_HOST", "")
    SMTP_PORT: int = int(os.getenv("SMTP_PORT", "587"))
    SMTP_USER: str = os.getenv("SMTP_USER", "")
    SMTP_PASSWORD: str = os.getenv("SMTP_PASSWORD", "")
    SMTP_FROM: str = os.getenv("SMTP_FROM", "polarbear@localhost")
    SMTP_TLS: bool = os.getenv("SMTP_TLS", "true").lower() == "true"

    # Requests per minute per tenant on the endpoints a public search key can
    # reach. 0 disables the limit, which is what a self-hoster behind their own
    # proxy usually wants.
    RATE_LIMIT_PER_MINUTE: int = int(os.getenv("RATE_LIMIT_PER_MINUTE", "120"))


settings = Settings()
