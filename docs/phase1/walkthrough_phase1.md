# Walkthrough - Phase 1: Setup & MVP Core

## Accomplished Tasks
- **Project Structure**: Created a monorepo with `frontend/`, `backend/`, and `infrastructure/`.
- **Frontend**: Initialized Next.js app with Tailwind CSS and TypeScript.
- **Backend**: Initialized FastAPI app with Poetry.
    - Configured dependencies: `fastapi`, `uvicorn`, `meilisearch`, `faiss-cpu`, `numpy`, `pandas`, `sentence-transformers`.
    - Created basic [app/main.py](file:///Users/tianzhang/Projects/PolarBear/backend/app/main.py) with health check.
    - Created [app/core/config.py](file:///Users/tianzhang/Projects/PolarBear/backend/app/core/config.py) for settings.
- **Infrastructure**: Created [docker-compose.yml](file:///Users/tianzhang/Projects/PolarBear/infrastructure/docker-compose.yml) for Meilisearch.

## Verification Guide

Follow these steps to verify the setup yourself.

### 1. Infrastructure (Meilisearch)
**Command**:
```bash
cd infrastructure
docker-compose up -d
```
**Verification**:
Check if Meilisearch is responding:
```bash
curl http://localhost:7700/health
# Expected Output: {"status":"available"}
```

### 2. Backend (FastAPI)
**Command**:
```bash
cd backend
poetry run uvicorn app.main:app --port 8000
```
**Verification**:
Open `http://localhost:8000/docs` in your browser. You should see the Swagger UI.

![Backend Swagger UI](/Users/tianzhang/.gemini/antigravity/brain/1c54aad2-d9f4-415d-b0b0-39a1941d7cec/backend_docs_1763763459172.png)

### 3. Frontend (Next.js)
**Command**:
```bash
cd frontend
npm run dev
```
**Verification**:
Open `http://localhost:3000` (or the port shown in your terminal, e.g., 3002) in your browser. You should see the Next.js welcome page.

![Frontend Home](/Users/tianzhang/.gemini/antigravity/brain/1c54aad2-d9f4-415d-b0b0-39a1941d7cec/frontend_home_1763763449642.png)

## Next Steps
- [x] Install Docker Desktop to run Meilisearch locally.
- Begin implementing the Data Ingestion module (CSV upload).
