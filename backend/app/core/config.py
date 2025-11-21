import os

class Settings:
    PROJECT_NAME: str = "PolarBear"
    MEILI_HOST: str = os.getenv("MEILI_HOST", "http://localhost:7700")
    MEILI_MASTER_KEY: str = os.getenv("MEILI_MASTER_KEY", "masterKey")

settings = Settings()
