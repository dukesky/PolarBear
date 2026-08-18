from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
import os
from app.core.config import settings
from app.api.routes import ingestion, search, analytics, products, tenant
from fastapi.middleware.cors import CORSMiddleware
from app.core.db import create_db_and_tables
from app.core.users import auth_backend, fastapi_users, google_oauth_client, oauth_redirect_backend
from app.schemas import UserCreate, UserRead, UserUpdate
from contextlib import asynccontextmanager


@asynccontextmanager
async def lifespan(app: FastAPI):
    await create_db_and_tables()
    if settings.SECRET_KEY == "dev-secret-change-me":
        print("WARNING: SECRET_KEY is the insecure default — set the SECRET_KEY env var before exposing this deployment.")
    yield


app = FastAPI(title="PolarBear API", version="0.2.0", lifespan=lifespan)

# Mount Static Files
public_dir = os.path.join(settings.DATA_DIR, "public")
os.makedirs(public_dir, exist_ok=True)
app.mount("/static", StaticFiles(directory=public_dir), name="static")

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Widget file path
WIDGET_FILE = os.path.join(os.path.dirname(__file__), "widget", "polarbear-widget.js")


@app.get("/widget.js", include_in_schema=False)
def widget_js():
    if not os.path.exists(WIDGET_FILE):
        raise HTTPException(status_code=404, detail="Widget artifact missing")
    return FileResponse(
        WIDGET_FILE,
        media_type="application/javascript",
        headers={"Cache-Control": "public, max-age=3600"},
    )


app.include_router(fastapi_users.get_auth_router(auth_backend), prefix="/auth/jwt", tags=["Auth"])
app.include_router(fastapi_users.get_register_router(UserRead, UserCreate), prefix="/auth", tags=["Auth"])
app.include_router(fastapi_users.get_users_router(UserRead, UserUpdate), prefix="/users", tags=["Auth"])
app.include_router(fastapi_users.get_reset_password_router(), prefix="/auth", tags=["Auth"])
app.include_router(ingestion.router, prefix="/ingest", tags=["Ingestion"])
app.include_router(search.router, prefix="/search", tags=["Search"])
app.include_router(analytics.router, prefix="/analytics", tags=["Analytics"])
app.include_router(products.router, prefix="/products", tags=["Products"])
app.include_router(tenant.router, prefix="/tenant", tags=["Tenant"])


@app.get("/auth/providers", tags=["Auth"])
def auth_providers():
    return {"google": google_oauth_client is not None}


if google_oauth_client is not None:
    app.include_router(
        fastapi_users.get_oauth_router(
            google_oauth_client,
            oauth_redirect_backend,
            settings.SECRET_KEY,
            # associate_by_email disabled: no email verification yet — prevents pre-registration account takeover
            associate_by_email=False,
            is_verified_by_default=True,
        ),
        prefix="/auth/google",
        tags=["Auth"],
    )


@app.get("/health")
def health_check():
    return {"status": "ok"}
