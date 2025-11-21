import pandas as pd
from typing import List, Dict, Any
import io

class DataParser:
    @staticmethod
    def parse_file(file_content: bytes, filename: str) -> List[Dict[str, Any]]:
        """
        Parse uploaded file content (CSV/Excel) into a list of dictionaries.
        """
        if filename.endswith('.csv'):
            df = pd.read_csv(io.BytesIO(file_content))
        elif filename.endswith(('.xls', '.xlsx')):
            df = pd.read_excel(io.BytesIO(file_content))
        else:
            raise ValueError("Unsupported file format. Please upload CSV or Excel.")

        # Basic normalization
        # 1. Fill NaNs with empty string
        df = df.fillna("")
        
        # 2. Ensure 'id' exists, if not, create one from index
        if 'id' not in df.columns:
            df['id'] = df.index.astype(str)
        else:
            df['id'] = df['id'].astype(str)

        return df.to_dict(orient='records')
