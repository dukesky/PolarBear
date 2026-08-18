import uuid

from fastapi import Depends, Request
from fastapi_users import BaseUserManager, FastAPIUsers, UUIDIDMixin
from fastapi_users.authentication import (
    AuthenticationBackend,
    BearerTransport,
    JWTStrategy,
)
from fastapi_users_db_sqlalchemy import SQLAlchemyUserDatabase

from app.core.config import settings
from app.core.db import async_session_maker, get_async_session
from app.models import OAuthAccount, Tenant, User
from app.services.email import send_password_reset
from app.services.keys import create_tenant_keys


async def get_user_db(session=Depends(get_async_session)):
    yield SQLAlchemyUserDatabase(session, User, OAuthAccount)


class UserManager(UUIDIDMixin, BaseUserManager[User, uuid.UUID]):
    reset_password_token_secret = settings.SECRET_KEY
    verification_token_secret = settings.SECRET_KEY
    reset_password_token_lifetime_seconds = 3600

    async def on_after_register(self, user: User, request: Request | None = None):
        async with async_session_maker() as session:
            tenant = Tenant(owner_user_id=user.id, name=user.email.split("@")[0])
            session.add(tenant)
            await session.commit()
            await create_tenant_keys(session, tenant.id)

    async def on_after_forgot_password(
        self, user: User, token: str, request: Request | None = None
    ):
        # Never let a mail failure turn into a 500 - the caller must not be able
        # to tell whether the address exists or the mailer is down.
        try:
            send_password_reset(user.email, token)
        except Exception as e:
            print(f"[auth] password reset email failed for {user.email}: {e}")


async def get_user_manager(user_db=Depends(get_user_db)):
    yield UserManager(user_db)


bearer_transport = BearerTransport(tokenUrl="auth/jwt/login")


def get_jwt_strategy() -> JWTStrategy:
    return JWTStrategy(secret=settings.SECRET_KEY, lifetime_seconds=60 * 60 * 24 * 7)


auth_backend = AuthenticationBackend(
    name="jwt", transport=bearer_transport, get_strategy=get_jwt_strategy
)

fastapi_users = FastAPIUsers[User, uuid.UUID](get_user_manager, [auth_backend])
current_active_user = fastapi_users.current_user(active=True)
optional_current_user = fastapi_users.current_user(active=True, optional=True)

from fastapi.responses import RedirectResponse
from httpx_oauth.clients.google import GoogleOAuth2

google_oauth_client = (
    GoogleOAuth2(settings.GOOGLE_OAUTH_CLIENT_ID, settings.GOOGLE_OAUTH_CLIENT_SECRET)
    if settings.GOOGLE_OAUTH_CLIENT_ID and settings.GOOGLE_OAUTH_CLIENT_SECRET
    else None
)


class FrontendRedirectTransport(BearerTransport):
    """After OAuth callback, hand the JWT to the frontend via URL fragment."""

    async def get_login_response(self, token: str):
        return RedirectResponse(
            f"{settings.FRONTEND_URL}/login#token={token}", status_code=302
        )


oauth_redirect_backend = AuthenticationBackend(
    name="jwt-oauth-redirect",
    transport=FrontendRedirectTransport(tokenUrl="auth/jwt/login"),
    get_strategy=get_jwt_strategy,
)
