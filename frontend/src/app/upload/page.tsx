'use client';

import { useState } from 'react';
import { authFetch, useRequireAuth } from '../../lib/api';

const TARGETS = [
  { key: 'title', label: 'Product name', required: true },
  { key: 'description', label: 'Description' },
  { key: 'price', label: 'Price' },
  { key: 'id', label: 'Product ID / SKU' },
  { key: 'category', label: 'Category' },
  { key: 'brand', label: 'Brand' },
  { key: 'tags', label: 'Tags' },
  { key: 'image_url', label: 'Image URL' },
  { key: 'url', label: 'Product page URL' },
];

interface Preview {
  columns: string[];
  sample_rows: Record<string, string>[];
  row_count: number;
  guess: Record<string, string | null>;
}

export default function UploadPage() {
  useRequireAuth();
  const [file, setFile] = useState<File | null>(null);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [mapping, setMapping] = useState<Record<string, string>>({});
  const [status, setStatus] = useState('');
  const [busy, setBusy] = useState(false);

  const reset = () => {
    setFile(null);
    setPreview(null);
    setMapping({});
  };

  const handleFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0];
    if (!f) return;
    setFile(f);
    setStatus('');
    setBusy(true);
    try {
      const form = new FormData();
      form.append('file', f);
      const res = await authFetch('/ingest/preview', { method: 'POST', body: form });
      const data = await res.json();
      if (!res.ok) {
        setStatus(`Error: ${data.detail}`);
        setFile(null);
        return;
      }
      setPreview(data);
      const initial: Record<string, string> = {};
      TARGETS.forEach((t) => {
        const g = data.guess[t.key];
        if (g) initial[t.key] = g;
      });
      setMapping(initial);
    } catch {
      setStatus('Error: Failed to connect to server.');
      setFile(null);
    } finally {
      setBusy(false);
    }
  };

  const handleImport = async () => {
    if (!file) return;
    setBusy(true);
    setStatus('Importing and indexing…');
    try {
      const form = new FormData();
      form.append('file', file);
      form.append(
        'mapping',
        JSON.stringify(
          Object.fromEntries(TARGETS.map((t) => [t.key, mapping[t.key] || null]))
        )
      );
      const res = await authFetch('/ingest/upload', { method: 'POST', body: form });
      const data = await res.json();
      if (res.ok) {
        setStatus(`Success: ${data.message}`);
        reset();
      } else {
        setStatus(`Error: ${data.detail}`);
      }
    } catch {
      setStatus('Error: Failed to connect to server.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="min-h-screen bg-gray-50 p-8">
      <div className="max-w-2xl mx-auto bg-white rounded-xl shadow-md p-6">
        <div className="uppercase tracking-wide text-sm text-indigo-500 font-semibold mb-2">
          Data Ingestion
        </div>
        <h1 className="text-lg font-medium text-black mb-6">Upload Product Catalog</h1>

        {!preview && (
          <>
            <div className="bg-blue-50 p-4 rounded-lg text-sm text-blue-800 mb-6">
              <p className="font-medium mb-1">Bring the file you already have.</p>
              <p>
                Export from Shopify, WooCommerce, or your own spreadsheet — we read the
                columns and let you confirm what they mean. Only a product name is
                required.
              </p>
            </div>

            <label className="block text-gray-700 text-sm font-bold mb-2" htmlFor="file-upload">
              Select CSV or Excel file
            </label>
            <input
              type="file"
              id="file-upload"
              accept=".csv, .xls, .xlsx"
              onChange={handleFileChange}
              disabled={busy}
              className="block w-full text-sm text-gray-500
                file:mr-4 file:py-2 file:px-4 file:rounded-full file:border-0
                file:text-sm file:font-semibold file:bg-indigo-50 file:text-indigo-700
                hover:file:bg-indigo-100"
            />
            {busy && <p className="mt-3 text-sm text-gray-500">Reading your file…</p>}
          </>
        )}

        {preview && (
          <>
            <div className="mb-4 text-sm text-gray-600">
              <span className="font-medium text-gray-900">{file?.name}</span> ·{' '}
              {preview.row_count} rows · {preview.columns.length} columns
            </div>

            <h2 className="text-sm font-semibold text-gray-900 mb-1">
              Confirm what each column means
            </h2>
            <p className="text-xs text-gray-500 mb-4">
              We guessed from your column names. Change anything that looks wrong.
            </p>

            <div className="space-y-3 mb-5">
              {TARGETS.map((t) => (
                <div key={t.key} className="flex items-center gap-3">
                  <label className="w-40 text-sm text-gray-700" htmlFor={`map-${t.key}`}>
                    {t.label}
                    {t.required && <span className="text-indigo-600"> *</span>}
                  </label>
                  <select
                    id={`map-${t.key}`}
                    value={mapping[t.key] || ''}
                    onChange={(e) =>
                      setMapping({ ...mapping, [t.key]: e.target.value })
                    }
                    className="flex-1 border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
                  >
                    <option value="">— not in my file —</option>
                    {preview.columns.map((c) => (
                      <option key={c} value={c}>
                        {c}
                      </option>
                    ))}
                  </select>
                </div>
              ))}
            </div>

            {!mapping.id && (
              <div className="mb-5 p-3 rounded bg-amber-50 text-amber-800 text-xs">
                No product ID column selected — we&apos;ll number your products
                automatically. If you rename a product later, it will be added as a new
                one rather than updating the old entry.
              </div>
            )}

            <div className="mb-5">
              <h3 className="text-xs font-semibold text-gray-700 mb-2">
                Preview of the first rows
              </h3>
              <div className="overflow-x-auto border border-gray-200 rounded">
                <table className="w-full text-xs">
                  <thead className="bg-gray-50 text-gray-500">
                    <tr>
                      {TARGETS.filter((t) => mapping[t.key]).map((t) => (
                        <th key={t.key} className="px-3 py-2 text-left font-medium">
                          {t.label}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-100">
                    {preview.sample_rows.map((row, i) => (
                      <tr key={i}>
                        {TARGETS.filter((t) => mapping[t.key]).map((t) => (
                          <td key={t.key} className="px-3 py-2 text-gray-700 truncate max-w-[180px]">
                            {String(row[mapping[t.key]] ?? '')}
                          </td>
                        ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>

            <div className="flex gap-3">
              <button
                onClick={handleImport}
                disabled={busy || !mapping.title}
                className={`flex-1 py-2 px-4 rounded-md text-sm font-medium text-white ${
                  busy || !mapping.title
                    ? 'bg-gray-400 cursor-not-allowed'
                    : 'bg-indigo-600 hover:bg-indigo-700'
                }`}
              >
                {busy ? 'Importing…' : `Import ${preview.row_count} products`}
              </button>
              <button
                onClick={reset}
                disabled={busy}
                className="py-2 px-4 rounded-md text-sm font-medium border border-gray-300 text-gray-700 hover:bg-gray-50"
              >
                Choose a different file
              </button>
            </div>
          </>
        )}

        {status && (
          <div
            className={`mt-4 p-3 rounded text-sm ${
              status.startsWith('Error')
                ? 'bg-red-100 text-red-700'
                : 'bg-green-100 text-green-700'
            }`}
          >
            {status}
          </div>
        )}
      </div>
    </div>
  );
}
