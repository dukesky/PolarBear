# PolarBear 🐻‍❄️

**Open-Source Hybrid Search System for SMEs**

PolarBear is a no-code, cloud-enabled, AI-powered search engine designed specifically for small and medium-sized businesses. It allows business owners to easily create powerful search functionality for their products, menus, inventory, or service catalogs — without any technical knowledge.

## 🚀 Features

- **Hybrid Search**: Combines keyword matching (BM25 via Meilisearch) with semantic search (Embeddings via FAISS) for superior relevance.
- **No-Code Setup**: Upload data via CSV, Excel, or Google Sheets.
- **Cloud-Native**: Built to run on Google Cloud Platform (Cloud Run), but fully open-source and self-hostable.
- **AI-Powered**: Includes an AI assistant for search health diagnostics and catalog optimization.

### Phase 3: Search Interface & Logic (Current)
- **Hybrid Search**: Combines Keyword (Meilisearch) and Vector (FAISS) scores.
- **Search UI**: User-friendly search page at `/search`.
- **API**: `GET /search` endpoint.

## 🛠️ Tech Stack

- **Frontend**: Next.js (React), Tailwind CSS
- **Backend**: Python FastAPI
- **Search Engine**: Meilisearch (Keyword), FAISS (Vector)
- **Infrastructure**: Docker Compose

## 🚀 Getting Started

### Prerequisites
- Node.js 18+
- Python 3.11+
- Docker & Docker Compose

### Quick Start

1.  **Start Infrastructure**
    ```bash
    cd infrastructure
    docker-compose up -d
    ```

2.  **Start Backend**
    ```bash
    cd backend
    poetry install
    poetry run uvicorn app.main:app --reload --port 8000
    ```

3.  **Start Frontend**
    ```bash
    cd frontend
    npm install
    npm run dev
    ```

4.  **Ingest Data**
    - Open `http://localhost:3000/upload`.
    - Upload a CSV file (e.g., `sample_products.csv`).

5.  **Search**
    - Open `http://localhost:3000/search`.
    - Type a query (e.g., "warm jacket") to see hybrid results.

## 📚 Documentation
- [Phase 1: Setup & MVP Core](docs/phase1/walkthrough_phase1.md)
- [Phase 2: Data Ingestion & Hybrid Indexing](docs/phase2/walkthrough_phase2.md)
- [Phase 3: Search Interface & Logic](docs/phase3/walkthrough_phase3.md)

## 📁 Project Structure

- `frontend/`: Next.js Admin Dashboard
- `backend/`: FastAPI Search & Ingestion Engine
- `infrastructure/`: Docker configuration
