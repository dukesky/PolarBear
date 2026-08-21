import csv
import io
import uuid as uuid_mod
from datetime import datetime, timezone
from typing import Optional

import meilisearch.errors
from fastapi import APIRouter, Body, Depends, File, HTTPException, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel

from app.core.tenancy import resolve_admin_tenant
from app.models import Tenant
from app.services.ingestion.mapping import TARGET_FIELDS
from app.services.search.indexer import HybridIndexer
from app.services.storage import get_storage

router = APIRouter()


class ProductUpdate(BaseModel):
    title: Optional[str] = None
    description: Optional[str] = None
    price: Optional[float] = None
    image_url: Optional[str] = None


def _index_for(tenant: Tenant):
    indexer = HybridIndexer(str(tenant.id))
    return indexer.meili_client.index(indexer.index_name)


# One export walks the catalog a page at a time. A catalog that reaches the cap
# gets an error, never a short file.
#
# The cap is sized by memory, not by policy. This response is built entirely in
# RAM three times over: `documents`, then `rows` derived from it, then the whole
# CSV in a StringIO. At a conservative ~1 KB per product that is ~3 KB resident
# per product, so 50k products peaks somewhere around 150 MB — survivable on a
# normal worker. The previous 500k would have been over 1.5 GB and OOM'd the
# worker, taking every co-tenant request on that instance with it, long before
# the refusal below ever fired. Raising this without streaming the response
# first would reintroduce exactly that.
EXPORT_PAGE_SIZE = 1000
EXPORT_MAX_DOCUMENTS = 50_000


def _fetch_every_document(index) -> list[dict]:
    """Every document in the index, paged.

    A single `get_documents({"limit": 10000})` silently truncated anything
    larger, which is the one failure this feature cannot have: a merchant
    downloading their catalogue to leave with it has no way to notice that the
    file is short.
    """
    documents: list[dict] = []
    offset = 0
    while True:
        page = index.get_documents({"limit": EXPORT_PAGE_SIZE, "offset": offset})
        batch = [dict(d) for d in page.results]
        if not batch:
            return documents
        documents.extend(batch)
        offset += len(batch)

        total = getattr(page, "total", None)
        if total is not None and offset >= total:
            return documents
        # Deliberately no "short page means the end" shortcut. When `total` is
        # missing there is nothing to check a short page against, and treating
        # one as the end fails *open* — a server that returned fewer rows than
        # asked for mid-catalog would truncate the export silently, which is
        # the exact bug this function exists to remove. Only an empty page ends
        # the walk; the cap below bounds it either way.
        if offset >= EXPORT_MAX_DOCUMENTS:
            raise HTTPException(
                status_code=400,
                detail=(
                    f"This catalog is larger than {EXPORT_MAX_DOCUMENTS:,} products, "
                    "which is more than one download can handle. Contact support and "
                    "we will get you the full export."
                ),
            )


@router.get("/")
async def list_products(
    limit: int = 100, offset: int = 0, tenant: Tenant = Depends(resolve_admin_tenant)
):
    try:
        results = _index_for(tenant).get_documents({"limit": limit, "offset": offset})
        return [dict(d) for d in results.results]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/export")
async def export_products(
    format: str = "csv", tenant: Tenant = Depends(resolve_admin_tenant)
):
    """Download the catalog. The CSV uses PolarBear's own column names, so a
    merchant can re-upload the file unchanged."""
    if format not in ("csv", "json"):
        raise HTTPException(status_code=400, detail="format must be 'csv' or 'json'.")

    indexer = HybridIndexer(str(tenant.id))
    try:
        documents = _fetch_every_document(
            indexer.meili_client.index(indexer.index_name)
        )
    except meilisearch.errors.MeilisearchApiError as e:
        if getattr(e, "code", None) != "index_not_found":
            print(f"[products] export failed for tenant {tenant.id}: {e}")
            raise HTTPException(status_code=500, detail="Could not read the catalog.")
        # A merchant who has never uploaded anything has no index yet. That is
        # an empty catalog, not a failure — hand them the headers.
        documents = []
    except HTTPException:
        raise  # a deliberate refusal (e.g. too large) already says what happened
    except Exception as e:
        print(f"[products] export failed for tenant {tenant.id}: {e}")
        raise HTTPException(status_code=500, detail="Could not read the catalog.")

    rows = [{field: doc.get(field, "") for field in TARGET_FIELDS} for doc in documents]
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    if format == "json":
        return {
            "products": rows,
            "count": len(rows),
            "exported_at": datetime.now(timezone.utc).isoformat(),
        }

    buffer = io.StringIO()
    writer = csv.DictWriter(buffer, fieldnames=TARGET_FIELDS)
    writer.writeheader()
    writer.writerows(rows)
    return Response(
        content=buffer.getvalue(),
        media_type="text/csv",
        headers={
            "Content-Disposition": f'attachment; filename="polarbear-products-{stamp}.csv"'
        },
    )


@router.put("/{product_id}")
async def update_product(
    product_id: str, product: ProductUpdate, tenant: Tenant = Depends(resolve_admin_tenant)
):
    index = _index_for(tenant)
    try:
        existing = dict(index.get_document(product_id))
    except Exception:
        raise HTTPException(status_code=404, detail="Product not found")

    for field in ("title", "description", "price", "image_url"):
        value = getattr(product, field)
        if value is not None:
            existing[field] = value
    index.add_documents([existing])
    return {"status": "success", "product": existing}


@router.post("/{product_id}/image")
async def upload_product_image(
    product_id: str,
    file: UploadFile = File(...),
    tenant: Tenant = Depends(resolve_admin_tenant),
):
    if not file.content_type or not file.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="File must be an image")

    ext = file.filename.split(".")[-1] if "." in file.filename else "png"
    name = f"images/{product_id}_{uuid_mod.uuid4().hex[:8]}.{ext}"
    data = await file.read()
    image_url = get_storage().write_public(str(tenant.id), name, data, file.content_type)

    await update_product(product_id, ProductUpdate(image_url=image_url), tenant)
    return {"status": "success", "image_url": image_url}


@router.delete("/{product_id}")
async def delete_product(product_id: str, tenant: Tenant = Depends(resolve_admin_tenant)):
    """Remove one product from the catalog and the vector index."""
    try:
        removed = HybridIndexer(str(tenant.id)).delete_document(product_id)
    except Exception as e:
        print(f"[products] delete failed for tenant {tenant.id}: {e}")
        raise HTTPException(status_code=500, detail="Could not complete the deletion.")
    if not removed:
        raise HTTPException(status_code=404, detail="Product not found")
    return {"status": "success", "deleted": product_id}


@router.delete("/")
async def clear_catalog(
    confirm: str = Body(default="", embed=True),
    tenant: Tenant = Depends(resolve_admin_tenant),
):
    """Remove every product. Requires an explicit confirmation string."""
    if confirm != "delete all products":
        raise HTTPException(
            status_code=400,
            detail='Send {"confirm": "delete all products"} to clear the catalog.',
        )
    try:
        count = HybridIndexer(str(tenant.id)).clear_all()
    except Exception as e:
        print(f"[products] delete failed for tenant {tenant.id}: {e}")
        raise HTTPException(status_code=500, detail="Could not complete the deletion.")
    return {"status": "success", "deleted": count}
