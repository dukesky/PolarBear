# Walkthrough - Phase 5 Modifications
**Date**: 2025-11-21

## Accomplished Tasks
- **Rename**: Renamed "Admin" to "Insights" (`/insights`).
- **UX**: Added CSV instructions to the Upload page.
- **Ingestion**: Implemented "Merge & Rebuild" logic to support cumulative CSV uploads without desyncing Meilisearch and FAISS.

## Verification Results

### 1. Insights Page
Navigated to `/insights`.
**Screenshot**:
![Insights Dashboard](/Users/tianzhang/.gemini/antigravity/brain/1c54aad2-d9f4-415d-b0b0-39a1941d7cec/insights_dashboard_1763783552854.png)

### 2. Ingestion Merge Logic
1.  Uploaded `sample_products.csv` (Original).
2.  Uploaded `sample_products_2.csv` (New: Yoga Mat, Smart Watch).
3.  Searched for "shirt" (Old) -> Found ✅
4.  Searched for "yoga" (New) -> Found ✅

**Result**: The system successfully merged the new products with the existing catalog.
