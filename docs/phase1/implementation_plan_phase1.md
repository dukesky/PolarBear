# Implementation Plan - Phase 2: Data Ingestion & Hybrid Indexing

## Goal Description
Implement the core "Data Ingestion" and "Hybrid Indexing" pipelines. This allows users to upload product catalogs (CSV/Excel), which are then processed to populate both the Keyword Search Engine (Meilisearch) and the Vector Search Engine (FAISS).

## User Review Required
> [!IMPORTANT]
> **Embedding Model**: We will use `all-MiniLM-L6-v2` (via `sentence-transformers`) for generating embeddings locally. It is lightweight and fast for CPU usage.

- **Data Flow**:
    1.  **Upload**: User uploads file -> Saved to `backend/data/uploads`.
    2.  **Ingest**: Parse file (Pandas) -> Normalize Data.
    3.  **Index**:
        *   **Meilisearch**: Push JSON documents.
        *   **FAISS**: Generate embeddings -> Build/Save FAISS index to disk.

## Proposed Changes

### Backend (`backend/`)
#### [NEW] `app/services/ingestion/parser.py`
- Logic to parse CSV, Excel, and Google Sheets (future) into a standard list of dictionaries.
- Basic schema validation (check for `title`, `id` fields).

#### [NEW] `app/services/search/indexer.py`
- **Meilisearch Wrapper**: Functions to create index, update settings (searchable attributes), and add documents.
- **Vector Engine**:
    - Load `sentence-transformers` model.
    - Generate embeddings for `title` + `description`.
    - Build FAISS index (`IndexFlatL2` or `IndexIVFFlat`).
    - Save `faiss_index.bin` to disk.

#### [NEW] `app/api/routes/ingestion.py`
- `POST /ingest/upload`: Endpoint to accept file upload.
- `POST /ingest/process`: Endpoint to trigger parsing and indexing.

#### [MODIFY] `app/main.py`
- Register the new `ingestion` router.

### Frontend (`frontend/`)
#### [NEW] `src/app/upload/page.tsx`
- A simple UI to upload files.
- File input + "Upload" button.
- Progress bar or status indicator.

## Verification Plan

### Automated Tests
- **Unit Tests**: Test CSV parsing logic with a sample file.
- **Integration Tests**: Verify API endpoints accept files and return success.

### Manual Verification
1.  **Upload**: Use the new Frontend page to upload a sample `products.csv`.
2.  **Check Meilisearch**: Query `http://localhost:7700/indexes/products/documents` to see if data exists.
3.  **Check FAISS**: Verify `faiss_index.bin` is created in the backend directory.
