from fastapi import APIRouter, Depends, File, HTTPException, UploadFile

from app.core.tenancy import resolve_admin_tenant
from app.models import Tenant
from app.services.ingestion.parser import DataParser
from app.services.search.indexer import HybridIndexer

router = APIRouter()


@router.post("/upload")
async def upload_file(
    file: UploadFile = File(...),
    tenant: Tenant = Depends(resolve_admin_tenant),
):
    """Upload a CSV/Excel file, parse it, and index it into the caller's tenant."""
    if not file.filename.endswith((".csv", ".xls", ".xlsx")):
        raise HTTPException(status_code=400, detail="Only CSV and Excel are supported.")

    content = await file.read()
    try:
        documents = DataParser.parse_file(content, file.filename)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    if not documents:
        raise HTTPException(status_code=400, detail="File is empty or could not be parsed.")

    try:
        HybridIndexer(str(tenant.id)).index_data(documents)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    return {
        "status": "success",
        "message": f"Successfully processed {len(documents)} documents.",
        "filename": file.filename,
    }
