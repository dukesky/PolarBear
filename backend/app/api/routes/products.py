import uuid as uuid_mod
from typing import Optional

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from pydantic import BaseModel

from app.core.tenancy import resolve_admin_tenant
from app.models import Tenant
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
