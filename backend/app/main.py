from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
import os
from app.core.config import settings
from app.api.routes import ingestion, search, analytics, products, tenant
from fastapi.middleware.cors import CORSMiddleware
from app.core.db import create_db_and_tables
from app.core.users import auth_backend, fastapi_users
from app.schemas import UserCreate, UserRead, UserUpdate
from contextlib import asynccontextmanager


@asynccontextmanager
async def lifespan(app: FastAPI):
    await create_db_and_tables()
    yield


app = FastAPI(title="PolarBear API", version="0.2.0", lifespan=lifespan)

# Create static directory if not exists
os.makedirs("app/static/images", exist_ok=True)

# Mount Static Files
app.mount("/static", StaticFiles(directory="app/static"), name="static")

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(fastapi_users.get_auth_router(auth_backend), prefix="/auth/jwt", tags=["Auth"])
app.include_router(fastapi_users.get_register_router(UserRead, UserCreate), prefix="/auth", tags=["Auth"])
app.include_router(fastapi_users.get_users_router(UserRead, UserUpdate), prefix="/users", tags=["Auth"])
app.include_router(ingestion.router, prefix="/ingest", tags=["Ingestion"])
app.include_router(search.router, prefix="/search", tags=["Search"])
app.include_router(analytics.router, prefix="/analytics", tags=["Analytics"])
app.include_router(products.router, prefix="/products", tags=["Products"])
app.include_router(tenant.router, prefix="/tenant", tags=["Tenant"])


@app.get("/health")
def health_check():
    return {"status": "ok"}
