from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from app.core.database import get_db_connection, track_product_event

router = APIRouter()

class TrackEvent(BaseModel):
    type: str # 'click' or 'order'
    product_id: str
    title: str

@router.post("/track")
async def track_event(event: TrackEvent):
    """
    Tracks a product event (click or order).
    """
    if event.type not in ['click', 'order']:
        raise HTTPException(status_code=400, detail="Invalid event type")
    
    track_product_event(event.type, event.product_id, event.title)
    return {"status": "success"}

@router.get("/stats")
async def get_analytics():
    """
    Returns search analytics: total searches, top queries, zero-result queries, and product stats.
    """
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # 1. Total Searches
        cursor.execute("SELECT COUNT(*) FROM search_logs")
        total_searches = cursor.fetchone()[0]
        
        # 2. Top Queries (Most frequent)
        cursor.execute("""
            SELECT query, COUNT(*) as count 
            FROM search_logs 
            GROUP BY query 
            ORDER BY count DESC 
            LIMIT 10
        """)
        top_queries = [dict(row) for row in cursor.fetchall()]
        
        # 3. Zero Result Queries (Missed opportunities)
        cursor.execute("""
            SELECT query, COUNT(*) as count 
            FROM search_logs 
            WHERE result_count = 0
            GROUP BY query 
            ORDER BY count DESC 
            LIMIT 10
        """)
        zero_results = [dict(row) for row in cursor.fetchall()]
        
        # 4. Product Stats
        cursor.execute("""
            SELECT product_id, title, clicks, orders 
            FROM product_stats 
            ORDER BY orders DESC, clicks DESC
        """)
        product_stats = [dict(row) for row in cursor.fetchall()]
        
        conn.close()
        
        return {
            "total_searches": total_searches,
            "top_queries": top_queries,
            "zero_results": zero_results,
            "product_stats": product_stats
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
