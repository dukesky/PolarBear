import uuid

from fastapi_users import schemas
from pydantic import BaseModel, Field


class UserRead(schemas.BaseUser[uuid.UUID]):
    pass


class UserCreate(schemas.BaseUserCreate):
    pass


class UserUpdate(schemas.BaseUserUpdate):
    pass


class UserForgotPasswordSchema(BaseModel):
    email: str = Field(..., description="User email address")

    class Config:
        json_schema_extra = {
            "example": {"email": "user@example.com"}
        }
