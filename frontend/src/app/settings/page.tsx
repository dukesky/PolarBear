'use client';

import { useEffect, useState } from 'react';
import { authFetch, useRequireAuth } from '../../lib/api';

interface KeyInfo {
  key: string | null;
  created_at: string | null;
}

export default function SettingsPage() {
  useRequireAuth();
  const [keys, setKeys] = useState<Record<string, KeyInfo>>({});
  const [freshAdminKey, setFreshAdminKey] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);

  const load = () => {
    authFetch('/tenant/keys')
      .then((r) => (r.ok ? r.json() : {}))
      .then(setKeys)
      .catch(() => {});
  };

  useEffect(load, []);

  const copy = async (label: string, value: string) => {
    await navigator.clipboard.writeText(value);
    setCopied(label);
    setTimeout(() => setCopied(null), 1500);
  };

  const reset = async (kind: 'search' | 'admin') => {
    if (!confirm(`Reset the ${kind} key? The old key stops working immediately.`)) return;
    const r = await authFetch(`/tenant/keys/${kind}/reset`, { method: 'POST' });
    if (r.ok) {
      const d = await r.json();
      if (kind === 'admin') setFreshAdminKey(d.key);
      load();
    }
  };

  return (
    <div className="min-h-screen bg-gray-50 p-8">
      <div className="max-w-2xl mx-auto bg-white rounded-xl shadow-md p-6">
        <div className="uppercase tracking-wide text-sm text-indigo-500 font-semibold mb-2">
          Settings
        </div>
        <h1 className="text-lg font-medium text-black mb-6">API Keys</h1>

        {/* Search key — public, always visible */}
        <div className="mb-6 p-4 border border-gray-200 rounded-lg">
          <div className="flex justify-between items-center mb-2">
            <h2 className="text-sm font-semibold text-gray-900">Public Search Key</h2>
            <button onClick={() => reset('search')} className="text-xs text-gray-500 hover:text-red-600">
              Reset
            </button>
          </div>
          <p className="text-xs text-gray-500 mb-3">
            Read-only. Safe to embed in your website — it can only run searches on your catalog.
          </p>
          <div className="flex items-center gap-2">
            <code className="flex-1 text-xs bg-gray-50 border border-gray-200 rounded px-2 py-2 overflow-x-auto whitespace-nowrap">
              {keys.search?.key ?? '—'}
            </code>
            {keys.search?.key && (
              <button
                onClick={() => copy('search', keys.search!.key!)}
                className="text-xs font-medium px-3 py-2 rounded bg-indigo-50 text-indigo-700 hover:bg-indigo-100"
              >
                {copied === 'search' ? 'Copied!' : 'Copy'}
              </button>
            )}
          </div>
        </div>

        {/* Admin key — plaintext only shown right after reset */}
        <div className="p-4 border border-gray-200 rounded-lg">
          <div className="flex justify-between items-center mb-2">
            <h2 className="text-sm font-semibold text-gray-900">Admin Key</h2>
            <button onClick={() => reset('admin')} className="text-xs text-gray-500 hover:text-red-600">
              Reset
            </button>
          </div>
          <p className="text-xs text-gray-500 mb-3">
            Full access to upload and edit your catalog. Keep it secret — it is shown only once,
            right after a reset.
          </p>
          <div className="flex items-center gap-2">
            <code className="flex-1 text-xs bg-gray-50 border border-gray-200 rounded px-2 py-2 overflow-x-auto whitespace-nowrap">
              {freshAdminKey ?? 'pb_admin_••••••••••••  (reset to reveal a new key)'}
            </code>
            {freshAdminKey && (
              <button
                onClick={() => copy('admin', freshAdminKey)}
                className="text-xs font-medium px-3 py-2 rounded bg-indigo-50 text-indigo-700 hover:bg-indigo-100"
              >
                {copied === 'admin' ? 'Copied!' : 'Copy'}
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
