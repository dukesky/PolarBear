# Implementation Plan - Phase 5 Modifications

## Goal Description
1.  **Rename "Admin" to "Insights"**: Update the UI to reflect the new naming.
2.  **Fix Ingestion Logic**: Ensure that uploading a new CSV **merges** with the existing catalog (deduplicating by ID) instead of causing a desync between the Keyword and Vector indices.

## User Review Required
> [!IMPORTANT]
> **Ingestion Strategy**: To ensure consistency between Meilisearch (Keyword) and FAISS (Vector), we will adopt a **"Merge & Rebuild"** strategy:
> 1.  Fetch all existing products from Meilisearch.
> 2.  Merge with the new CSV data (updating existing IDs, adding new ones).
> 3.  Re-index the *entire* combined dataset to Meilisearch.
> 4.  Re-build the FAISS index from scratch with the *entire* combined dataset.
>
> This guarantees that both engines are always in sync and contain all products.

## Proposed Changes

### Frontend (`frontend/`)
#### [MOVE] `src/app/admin` -> `src/app/insights`
- Rename the directory.
- Update page title to "Insights".

#### [MODIFY] `src/components/Navbar.tsx`
- Change "Admin" link to "Insights" (`/insights`).

### Backend (`backend/`)
#### [MODIFY] `app/services/search/indexer.py`
- Update `index_data` method:
    - Retrieve existing documents from Meilisearch (using `limit=10000` for MVP).
    - Create a dictionary of `{id: document}` to handle deduplication/updates.
    - Update dictionary with new documents.
    - Send *all* documents back to Meilisearch.
    - Generate embeddings for *all* documents and rebuild FAISS index.

## Verification Plan

### Manual Verification
1.  **Rename**: Verify `http://localhost:3000/insights` works and Navbar shows "Insights".
2.  **Ingestion**:
    - Upload `file1.csv` (Product A).
    - Search for Product A (should find it).
    - Upload `file2.csv` (Product B).
    - Search for Product A (should **still** find it - verifying merge).
    - Search for Product B (should find it).
