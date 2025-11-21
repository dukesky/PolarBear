# PolarBear 🐻‍❄️

**Open-Source Hybrid Search System for SMEs**

PolarBear is a no-code, cloud-enabled, AI-powered search engine designed specifically for small and medium-sized businesses. It allows business owners to easily create powerful search functionality for their products, menus, inventory, or service catalogs — without any technical knowledge.

## 🚀 Features

- **Hybrid Search**: Combines keyword matching (BM25 via Meilisearch) with semantic search (Embeddings via FAISS) for superior relevance.
- **No-Code Setup**: Upload data via CSV, Excel, or Google Sheets.
- **Cloud-Native**: Built to run on Google Cloud Platform (Cloud Run), but fully open-source and self-hostable.
- **AI-Powered**: Includes an AI assistant for search health diagnostics and catalog optimization.

## 🛠️ Tech Stack

- **Frontend**: Next.js (React), Tailwind CSS
- **Backend**: Python FastAPI
- **Search Engine**: Meilisearch (Keyword), FAISS (Vector)
- **Infrastructure**: Docker Compose

## 🏁 Getting Started

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [Node.js](https://nodejs.org/) (v18+)
- [Python](https://www.python.org/) (v3.11+)
- [Poetry](https://python-poetry.org/) (Python dependency manager)

   ```
   Frontend Dashboard will be available at `http://localhost:3000`.

## 📁 Project Structure

- `frontend/`: Next.js Admin Dashboard
- `backend/`: FastAPI Search & Ingestion Engine
- `infrastructure/`: Docker configuration
