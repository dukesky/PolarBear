from fastapi import APIRouter, HTTPException
from app.core.database import get_db_connection

router = APIRouter()

@router.get("/stats")
async def get_analytics():
    """
    Returns search analytics: total searches, top queries, and zero-result queries.
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
        
        conn.close()
        
        return {
            "total_searches": total_searches,
            "top_queries": top_queries,
            "zero_results": zero_results
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
