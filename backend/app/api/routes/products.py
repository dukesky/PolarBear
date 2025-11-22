from fastapi import APIRouter, HTTPException, UploadFile, File, Form
from pydantic import BaseModel
from typing import Optional
import shutil
import os
import uuid
from app.services.search.indexer import HybridIndexer

router = APIRouter()
indexer = HybridIndexer()

class ProductUpdate(BaseModel):
    title: Optional[str] = None
    description: Optional[str] = None
    price: Optional[float] = None
    image_url: Optional[str] = None

@router.get("/")
async def list_products(limit: int = 100, offset: int = 0):
    """
    List products from Meilisearch.
    """
    try:
        index = indexer.meili_client.index(indexer.index_name)
        results = index.get_documents({'limit': limit, 'offset': offset})
        
        # Handle Meilisearch v0.20+ response object
        documents = []
        if hasattr(results, 'results'):
            documents = [dict(d) for d in results.results]
        else:
            documents = results
            
        return documents
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.put("/{product_id}")
async def update_product(product_id: str, product: ProductUpdate):
    """
    Update a product's details.
    """
    try:
        # 1. Get existing product
        index = indexer.meili_client.index(indexer.index_name)
        try:
            existing_doc = index.get_document(product_id)
        except:
            raise HTTPException(status_code=404, detail="Product not found")
            
        # 2. Update fields
        doc = dict(existing_doc)
        if product.title is not None: doc['title'] = product.title
        if product.description is not None: doc['description'] = product.description
        if product.price is not None: doc['price'] = product.price
        if product.image_url is not None: doc['image_url'] = product.image_url
        
        # 3. Re-index (Single item update)
        # Note: For full consistency, we should ideally re-embed and update FAISS too.
        # For MVP, we'll just update Meilisearch and assume embeddings don't change drastically 
        # or we rely on the periodic "Merge & Rebuild" for vector updates.
        # However, to keep it simple and working, we will just update Meilisearch for now.
        index.add_documents([doc])
        
        return {"status": "success", "product": doc}
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/{product_id}/image")
async def upload_product_image(product_id: str, file: UploadFile = File(...)):
    """
    Upload an image for a product.
    """
    try:
        # 1. Validate file
        if not file.content_type.startswith('image/'):
            raise HTTPException(status_code=400, detail="File must be an image")
            
        # 2. Save file
        ext = file.filename.split('.')[-1]
        filename = f"{product_id}_{uuid.uuid4().hex[:8]}.{ext}"
        file_path = f"app/static/images/{filename}"
        
        with open(file_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
            
        # 3. Update Product URL
        image_url = f"http://localhost:8000/static/images/{filename}"
        
        # Update via the update endpoint logic
        update_data = ProductUpdate(image_url=image_url)
        await update_product(product_id, update_data)
        
        return {"status": "success", "image_url": image_url}
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
