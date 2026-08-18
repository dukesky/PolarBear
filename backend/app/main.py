from fastapi import FastAPI, HTTPException, Body
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
import os
from app.core.config import settings
from app.api.routes import ingestion, search, analytics, products, tenant
from fastapi.middleware.cors import CORSMiddleware
from app.core.db import create_db_and_tables
from app.core.users import auth_backend, fastapi_users, google_oauth_client, oauth_redirect_backend, get_user_manager
from app.schemas import UserCreate, UserRead, UserUpdate, UserForgotPasswordSchema
from contextlib import asynccontextmanager
from fastapi import Depends


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


@app.post("/auth/forgot-password", status_code=202, tags=["Auth"])
async def forgot_password(
    email_body: dict = Body(...),
    user_manager=Depends(get_user_manager),
):
    """Request a password reset token. Always returns 202 to avoid revealing whether email exists."""
    email = email_body.get("email")
    if not email:
        return
    try:
        user = await user_manager.get_by_email(email)
        token = user_manager.reset_password_token_secret
        reset_token = user_manager.reset_password_token_secret
        # Generate a reset token using fastapi-users' token generation
        from fastapi_users.jwt import generate_jwt
        reset_token = generate_jwt(
            {"sub": str(user.id), "aud": "fastapi-users:reset"},
            settings.SECRET_KEY,
            user_manager.reset_password_token_lifetime_seconds,
        )
        await user_manager.on_after_forgot_password(user, reset_token)
    except Exception:
        # User not found, SMTP error, or any other error - still return 202
        pass
    return {"message": "If the email exists, a password reset link has been sent"}


@app.post("/auth/reset-password", status_code=200, tags=["Auth"])
async def reset_password(
    reset_data: dict = Body(...),
    user_manager=Depends(get_user_manager),
):
    """Reset password using a reset token."""
    import uuid
    token = reset_data.get("token")
    password = reset_data.get("password")

    if not token or not password:
        raise HTTPException(status_code=400, detail="Missing token or password")

    try:
        # Verify and decode the token
        from fastapi_users.jwt import decode_jwt
        payload = decode_jwt(
            token,
            settings.SECRET_KEY,
            ["fastapi-users:reset"],
        )
        user_id_str = payload.get("sub")
        user_id = uuid.UUID(user_id_str)
        user = await user_manager.get(user_id)

        # Update the password using user_manager
        hashed_password = user_manager.password_helper.hash(password)
        await user_manager.user_db.update(user, {"hashed_password": hashed_password})

        return {"message": "Password reset successfully"}
    except Exception as e:
        print(f"Reset password error: {e}")
        raise HTTPException(status_code=400, detail="Invalid or expired token")


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
