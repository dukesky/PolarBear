# Implementation Plan - Phase 3: Search Interface & Logic

## Goal Description
Implement the user-facing Search functionality. This involves a unified Backend API that queries both Meilisearch (Keyword) and FAISS (Vector), merges the results, and serves them to a new Frontend Search Page.

## User Review Required
> [!IMPORTANT]
> **Hybrid Strategy**: For this MVP, we will use a **Linear Combination** approach.
> 1. Normalize scores from Meilisearch and FAISS (roughly).
> 2. Combine results: `Final Score = (Keyword Score * 0.3) + (Vector Score * 0.7)`.
> *Note: Weights are adjustable.*

## Proposed Changes

### Backend (`backend/`)
#### [NEW] `app/services/search/searcher.py`
- `HybridSearcher` class.
- `search(query: str, limit: int)` method:
    - Parallel/Sequential calls to `meili_client.search` and `faiss_index.search`.
    - Result merging and de-duplication logic.
    - ID-to-Data mapping (retrieving full object details).

#### [NEW] `app/api/routes/search.py`
- `GET /search`: Accepts `q` (query string) and `limit`.
- Returns a list of ranked products.

#### [MODIFY] `app/main.py`
- Register `search` router.

### Frontend (`frontend/`)
#### [NEW] `src/app/search/page.tsx`
- **Search Bar**: Input field with "Search" button.
- **Results Grid**: Display product cards (Image placeholder, Title, Description, Price, Tags).
- **Loading State**: Skeletons or spinner while searching.

## Verification Plan

### Automated Tests
- **Unit Tests**: Test `HybridSearcher` merging logic with mock data.

### Manual Verification
1.  **Search UI**: Go to `/search`.
2.  **Test Queries**:
    - "shirt" (Keyword match -> should find "PolarBear T-Shirt").
    - "something warm" (Vector match -> should find "Winter Jacket").
3.  **Verify Results**: Check if the returned items match expectations.
