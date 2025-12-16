from fastapi import APIRouter, UploadFile, File, HTTPException
from app.services.ingestion.parser import DataParser
from app.services.search.indexer import HybridIndexer

router = APIRouter()
_indexer = None

def get_indexer():
    global _indexer
    if _indexer is None:
        print("Initializing HybridIndexer (Lazy)...")
        _indexer = HybridIndexer()
    return _indexer

@router.post("/upload")
async def upload_file(file: UploadFile = File(...)):
    """
    Uploads a CSV/Excel file, parses it, and triggers hybrid indexing.
    """
    indexer = get_indexer()
    if not file.filename.endswith(('.csv', '.xls', '.xlsx')):
        raise HTTPException(status_code=400, detail="Invalid file format. Only CSV and Excel are supported.")
    
    try:
        content = await file.read()
        documents = DataParser.parse_file(content, file.filename)
        
        if not documents:
             raise HTTPException(status_code=400, detail="File is empty or could not be parsed.")

        # Trigger Indexing
        indexer.index_data(documents)
        
        return {
            "status": "success",
            "message": f"Successfully processed {len(documents)} documents.",
            "filename": file.filename
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
