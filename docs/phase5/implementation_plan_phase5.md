# Implementation Plan - Phase 5: UX Improvements & Product Analytics

## Goal Description
Improve user navigation between pages and implement product-level analytics. This includes tracking "Clicks" and "Orders" for products in the search results and displaying these metrics in the Admin Dashboard alongside a full product list.

## User Review Required
> [!NOTE]
> **"Order" Tracking**: Since there is no actual checkout flow, we will simulate an order by adding a "Buy" button to the search results. Clicking it will increment the "Order" count for that product.

## Proposed Changes

### Frontend (`frontend/`)
#### [NEW] `src/components/Navbar.tsx`
- A shared navigation bar with links to: Home, Search, Upload, Admin.
- Update `src/app/layout.tsx` to include this Navbar.

#### [MODIFY] `src/app/search/page.tsx`
- Add a "Buy" button to each product card.
- Implement `handleProductClick` (tracks click) and `handleBuy` (tracks order).
- Add a link/button to the Upload page (as requested, though Navbar covers this, explicit button is good too).

#### [MODIFY] `src/app/admin/page.tsx`
- Add a "Product Performance" table.
- Columns: Product Name, Brand, Price, **Clicks**, **Orders**.

### Backend (`backend/`)
#### [MODIFY] `app/core/database.py`
- Create `product_stats` table: `product_id` (PK), `title`, `clicks` (int), `orders` (int).
- Add functions: `increment_click(product_id, title)`, `increment_order(product_id, title)`.

#### [MODIFY] `app/api/routes/analytics.py`
- `POST /analytics/track`: Endpoint to receive event (`type`: "click"|"order", `product_id`, `title`).
- Update `GET /analytics/stats`: Include `product_stats` list.

## Verification Plan

### Automated Tests
- **Unit Tests**: Verify `increment_click` and `increment_order` update the database correctly.

### Manual Verification
1.  **Navigation**: Click through all links in the new Navbar.
2.  **Tracking**:
    - Go to Search, search for "shirt".
    - Click the product card (should log click).
    - Click "Buy" (should log order).
3.  **Admin**:
    - Go to Admin Dashboard.
    - Verify "PolarBear T-Shirt" shows 1 Click and 1 Order.
