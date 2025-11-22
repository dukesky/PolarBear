'use client';

import { useState } from 'react';

export default function UploadPage() {
  const [file, setFile] = useState<File | null>(null);
  const [status, setStatus] = useState<string>('');
  const [isUploading, setIsUploading] = useState(false);

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    if (e.target.files) {
      setFile(e.target.files[0]);
    }
  };

  const handleUpload = async () => {
    if (!file) return;

    setIsUploading(true);
    setStatus('Uploading and processing...');

    const formData = new FormData();
    formData.append('file', file);

    try {
      const response = await fetch('http://localhost:8000/ingest/upload', {
        method: 'POST',
        body: formData,
      });

      const data = await response.json();

      if (response.ok) {
        setStatus(`Success: ${data.message}`);
      } else {
        setStatus(`Error: ${data.detail}`);
      }
    } catch (error) {
      setStatus('Error: Failed to connect to server.');
    } finally {
      setIsUploading(false);
    }
  };

  return (
    <div className="min-h-screen bg-gray-50 p-8">
      <div className="max-w-md mx-auto bg-white rounded-xl shadow-md overflow-hidden md:max-w-2xl p-6">
        <div className="uppercase tracking-wide text-sm text-indigo-500 font-semibold mb-4">
          Data Ingestion
        </div>
        <h1 className="block mt-1 text-lg leading-tight font-medium text-black mb-6">
          Upload Product Catalog
        </h1>

        <div className="bg-white p-8 rounded-xl shadow-sm border border-gray-100">
          <div className="mb-6">
            <h2 className="text-lg font-semibold text-gray-900 mb-2">Instructions</h2>
            <div className="bg-blue-50 p-4 rounded-lg text-sm text-blue-800">
              <p className="font-medium mb-2">Required CSV Columns:</p>
              <ul className="list-disc list-inside space-y-1">
                <li><code>id</code> (Unique ID)</li>
                <li><code>title</code> (Product Name)</li>
                <li><code>description</code> (Product Description)</li>
                <li><code>price</code> (Number)</li>
                <li><code>category</code> (e.g., Apparel)</li>
                <li><code>brand</code> (e.g., Nike)</li>
                <li><code>tags</code> (Comma-separated, e.g., "summer, cotton")</li>
              </ul>
              <p className="mt-3 text-xs text-blue-600">
                Note: Uploading a new file will <strong>merge</strong> with existing products.
                Existing IDs will be updated, and new IDs will be added.
              </p>
            </div>
          </div>

          <div className="border-2 border-dashed border-gray-300 rounded-lg p-12 text-center hover:border-indigo-500 transition-colors"></div>
        </div>

        <div className="mb-6">
          <label className="block text-gray-700 text-sm font-bold mb-2" htmlFor="file-upload">
            Select CSV or Excel File
          </label>
          <input
            type="file"
            id="file-upload"
            accept=".csv, .xls, .xlsx"
            onChange={handleFileChange}
            className="block w-full text-sm text-gray-500
              file:mr-4 file:py-2 file:px-4
              file:rounded-full file:border-0
              file:text-sm file:font-semibold
              file:bg-indigo-50 file:text-indigo-700
              hover:file:bg-indigo-100"
          />
        </div>

        <button
          onClick={handleUpload}
          disabled={!file || isUploading}
          className={`w-full py-2 px-4 border border-transparent rounded-md shadow-sm text-sm font-medium text-white 
            ${!file || isUploading ? 'bg-gray-400 cursor-not-allowed' : 'bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500'}`}
        >
          {isUploading ? 'Processing...' : 'Upload & Index'}
        </button>

        {status && (
          <div className={`mt-4 p-3 rounded ${status.startsWith('Error') ? 'bg-red-100 text-red-700' : 'bg-green-100 text-green-700'}`}>
            {status}
          </div>
        )}
      </div>
    </div>
  );
}
