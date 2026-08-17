import json

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import get_async_session
from app.core.tenancy import resolve_admin_tenant
from app.models import Tenant
from app.services.ingestion.mapping import build_documents, guess_mapping
from app.services.ingestion.parser import DataParser
from app.services.search.indexer import HybridIndexer

router = APIRouter()

SUPPORTED = (".csv", ".xls", ".xlsx")


def _read(file: UploadFile, content: bytes):
    if not file.filename.endswith(SUPPORTED):
        raise HTTPException(status_code=400, detail="Only CSV and Excel are supported.")
    try:
        return DataParser.read_rows(content, file.filename)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception:
        raise HTTPException(
            status_code=400, detail="File is empty or could not be parsed."
        )


@router.post("/preview")
async def preview_file(
    file: UploadFile = File(...),
    tenant: Tenant = Depends(resolve_admin_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    """Read a file's columns and a few rows so the merchant can confirm mapping."""
    columns, rows = _read(file, await file.read())
    if not rows:
        raise HTTPException(status_code=400, detail="File is empty or could not be parsed.")

    guess = guess_mapping(columns)
    if tenant.column_mapping:
        try:
            saved = json.loads(tenant.column_mapping)
        except json.JSONDecodeError:
            saved = None
        # Only reuse a remembered mapping when it still fits this file.
        if saved and all(v in columns for v in saved.values() if v):
            guess = {**guess, **saved}

    return {
        "columns": columns,
        "sample_rows": rows[:3],
        "row_count": len(rows),
        "guess": guess,
    }


@router.post("/upload")
async def upload_file(
    file: UploadFile = File(...),
    mapping: str | None = Form(default=None),
    tenant: Tenant = Depends(resolve_admin_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    """Index a product file. With `mapping`, columns are translated first;
    without it, the file must already use PolarBear's own column names."""
    content = await file.read()

    if mapping:
        try:
            mapping_dict = json.loads(mapping)
        except json.JSONDecodeError:
            raise HTTPException(status_code=400, detail="mapping must be valid JSON.")
        columns, rows = _read(file, content)
        if not rows:
            raise HTTPException(status_code=400, detail="File is empty or could not be parsed.")
        try:
            documents = build_documents(rows, mapping_dict)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))
    else:
        if not file.filename.endswith(SUPPORTED):
            raise HTTPException(status_code=400, detail="Only CSV and Excel are supported.")
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

    if mapping:
        tenant.column_mapping = json.dumps(mapping_dict)
        session.add(tenant)
        await session.commit()

    return {
        "status": "success",
        "message": f"Successfully processed {len(documents)} documents.",
        "filename": file.filename,
    }
