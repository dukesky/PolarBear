import sqlite3
from datetime import datetime
import os

DB_PATH = "analytics.db"

def get_db_connection():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Create search_logs table
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS search_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            query TEXT NOT NULL,
            result_count INTEGER NOT NULL,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    ''')
    
    # Create product_stats table
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS product_stats (
            product_id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            clicks INTEGER DEFAULT 0,
            orders INTEGER DEFAULT 0
        )
    ''')
    
    conn.commit()
    conn.close()

def log_search(query: str, result_count: int):
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute(
            'INSERT INTO search_logs (query, result_count) VALUES (?, ?)',
            (query, result_count)
        )
        conn.commit()
        conn.close()
    except Exception as e:
        print(f"Failed to log search: {e}")

def track_product_event(event_type: str, product_id: str, title: str):
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # Ensure product exists
        cursor.execute(
            'INSERT OR IGNORE INTO product_stats (product_id, title, clicks, orders) VALUES (?, ?, 0, 0)',
            (product_id, title)
        )
        
        if event_type == 'click':
            cursor.execute('UPDATE product_stats SET clicks = clicks + 1 WHERE product_id = ?', (product_id,))
        elif event_type == 'order':
            cursor.execute('UPDATE product_stats SET orders = orders + 1 WHERE product_id = ?', (product_id,))
            
        conn.commit()
        conn.close()
    except Exception as e:
        print(f"Failed to track product event: {e}")
