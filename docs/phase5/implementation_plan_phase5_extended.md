# Implementation Plan - Phase 5 Extended: Images & Management

## Goal Description
1.  **Product Images**: Support product images via CSV (`image_url` column) or manual file upload.
2.  **Product Management**: Add a "Product Catalog" section to the **Insights Dashboard** where users can view and edit individual products (including uploading images).

## User Review Required
> [!IMPORTANT]
> **Image Storage**:
> -   **External URLs**: If provided in CSV, we use them directly.
> -   **Uploaded Files**: We will store them locally in `backend/static/images/`.
> -   **Serving**: The backend will serve these static files at `http://localhost:8000/static/images/...`.

## Proposed Changes

### Backend (`backend/`)
#### [MODIFY] `app/main.py`
-   Mount `StaticFiles` to serve `app/static` directory.

#### [MODIFY] `app/services/ingestion/parser.py`
-   Update schema to include optional `image_url`.

#### [MODIFY] `app/services/search/indexer.py`
-   Update Meilisearch settings to include `image_url`.
-   Update `index_data` to preserve `image_url` during merge.

#### [NEW] `app/api/routes/products.py`
-   `GET /products`: List all products (paginated).
-   `PUT /products/{id}`: Update product details.
-   `POST /products/{id}/image`: Upload image file -> Save to disk -> Update product `image_url`.

### Frontend (`frontend/`)
#### [MODIFY] `src/types/index.ts` (or wherever Product is defined)
-   Add `image_url?: string` to `Product` interface.

#### [MODIFY] `src/app/search/page.tsx`
-   Display product image in the result card. Fallback to a placeholder if missing.

#### [MODIFY] `src/app/insights/page.tsx`
-   Add **Product Catalog** section.
-   Table listing all products.
-   **Edit Mode**:
    -   Click "Edit" to show a form.
    -   Inputs: Title, Description, Price, Image URL.
    -   **File Upload**: Button to upload an image file (calls `POST /products/{id}/image`).

## Verification Plan

### Manual Verification
1.  **CSV Upload**: Upload CSV with `image_url`. Verify image shows in Search.
2.  **Manual Upload**:
    -   Go to Insights.
    -   Edit a product.
    -   Upload an image file.
    -   Verify image updates in Search.
3.  **Edit Details**: Change title/price in Insights, verify change in Search.
