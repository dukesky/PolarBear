import csv
import io
import uuid as uuid_mod
from datetime import datetime, timezone
from typing import Optional

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
        results = indexer.meili_client.index(indexer.index_name).get_documents(
            {"limit": 10000}
        )
        documents = [dict(d) for d in results.results]
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
