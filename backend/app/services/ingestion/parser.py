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

        # Validate required columns
        required_columns = {'id', 'title'}
        if not required_columns.issubset(df.columns):
            raise ValueError(f"Missing required columns: {required_columns - set(df.columns)}")

        # Fill NaN
        df = df.fillna('')

        # Convert to list of dicts
        documents = df.to_dict(orient='records')

        # Ensure image_url exists
        for doc in documents:
            if 'image_url' not in doc:
                doc['image_url'] = ''

        return documents

    @staticmethod
    def read_rows(file_content: bytes, filename: str) -> tuple[list, list]:
        """Read any CSV/Excel into (columns, rows) with no required-column check."""
        if filename.endswith('.csv'):
            df = pd.read_csv(io.BytesIO(file_content))
        elif filename.endswith(('.xls', '.xlsx')):
            df = pd.read_excel(io.BytesIO(file_content))
        else:
            raise ValueError("Unsupported file format. Please upload CSV or Excel.")

        columns = [str(c) for c in df.columns]
        duplicates = {c for c in columns if columns.count(c) > 1}
        if duplicates:
            raise ValueError(f"Duplicate column names: {', '.join(sorted(duplicates))}")

        df = df.fillna('')
        return columns, df.to_dict(orient='records')
