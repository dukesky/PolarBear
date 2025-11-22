# Implementation Plan - Phase 4: Admin Dashboard & Analytics

## Goal Description
Implement the **Admin Dashboard** to provide SMEs with insights into their search performance. This includes logging search queries and visualizing key metrics like "Top Queries" and "Zero-Result Queries".

## User Review Required
> [!NOTE]
> **Database**: For the MVP, we will use **SQLite** (`analytics.db`) to store search logs. This keeps the deployment simple and self-contained without needing a separate Postgres container yet.

## Proposed Changes

### Backend (`backend/`)
#### [NEW] `app/core/database.py`
- Setup SQLite connection using `sqlite3` or `SQLAlchemy` (keeping it simple with raw SQL or lightweight ORM).
- Create `search_logs` table: `id`, `query`, `timestamp`, `result_count`.

#### [MODIFY] `app/api/routes/search.py`
- Update `GET /search` to asynchronously log every query to the database.

#### [NEW] `app/api/routes/analytics.py`
- `GET /analytics/stats`: Returns total searches, top queries, and zero-result queries.

#### [MODIFY] `app/main.py`
- Register `analytics` router.

### Frontend (`frontend/`)
#### [NEW] `src/app/admin/page.tsx`
- **Dashboard Layout**: Sidebar navigation (Upload, Search, Analytics).
- **Stats Cards**: Total Searches, Total Products.
- **Tables**:
    - "Top Searches" (Query vs Count).
    - "Zero Results" (Missed opportunities).

## Verification Plan

### Automated Tests
- **Unit Tests**: Verify that calling `/search` increases the row count in `search_logs`.

### Manual Verification
1.  **Generate Traffic**: Perform 5-10 searches on the Search Page (some valid, some nonsense like "xyz123").
2.  **Check Dashboard**: Go to `/admin` and verify:
    - Total search count matches.
    - "xyz123" appears in the "Zero Results" list.
    - Valid queries appear in "Top Searches".
