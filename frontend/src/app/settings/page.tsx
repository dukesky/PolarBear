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

        <EmbedSection />
      </div>
    </div>
  );
}

const PLATFORMS = [
  {
    id: 'shopify',
    label: 'Shopify',
    steps: [
      'In your Shopify admin, go to Online Store → Themes → Customize.',
      'On the page where you want search, click Add section → Custom Liquid.',
      'Paste the code below into the Custom Liquid box and click Save.',
    ],
  },
  {
    id: 'wordpress',
    label: 'WordPress',
    steps: [
      'In WP Admin, go to Appearance → Widgets, or edit the page in the block editor.',
      'Add a "Custom HTML" block where you want the search box.',
      'Paste the code below into the block and click Update.',
    ],
  },
  {
    id: 'wix',
    label: 'Wix',
    steps: [
      'In your Wix dashboard, go to Settings → Custom Code.',
      'Click "+ Add Custom Code" and paste the code below.',
      'Choose the pages it loads on, place it in Body, and click Apply.',
    ],
  },
  {
    id: 'other',
    label: 'Other website',
    steps: [
      'Open the HTML of the page where you want the search box.',
      'Paste the code below where the box should appear.',
      'Save and reload your site.',
    ],
  },
];

function EmbedSection() {
  const [snippet, setSnippet] = useState('');
  const [platform, setPlatform] = useState('shopify');
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    authFetch('/tenant/snippet')
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => d && setSnippet(d.snippet))
      .catch(() => {});
  }, []);

  const copy = async () => {
    await navigator.clipboard.writeText(snippet);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };

  const active = PLATFORMS.find((p) => p.id === platform) ?? PLATFORMS[0];

  return (
    <div className="mt-6 p-4 border border-gray-200 rounded-lg">
      <h2 className="text-sm font-semibold text-gray-900 mb-1">Add search to your website</h2>
      <p className="text-xs text-gray-500 mb-3">
        Three steps: 1) upload your products, 2) copy the code, 3) paste it into your site.
        No coding needed — every platform below has a paste box in its settings.
      </p>

      <div className="flex gap-2 mb-3">
        {PLATFORMS.map((p) => (
          <button
            key={p.id}
            onClick={() => setPlatform(p.id)}
            className={`px-3 py-1.5 text-xs font-medium rounded-full border ${
              platform === p.id
                ? 'bg-indigo-50 border-indigo-300 text-indigo-700'
                : 'bg-white border-gray-300 text-gray-600 hover:bg-gray-50'
            }`}
          >
            {p.label}
          </button>
        ))}
      </div>

      <ol className="list-decimal list-inside space-y-1 text-xs text-gray-700 mb-3">
        {active.steps.map((s, i) => (
          <li key={i}>{s}</li>
        ))}
      </ol>

      <div className="flex items-start gap-2">
        <pre className="flex-1 text-xs bg-gray-50 border border-gray-200 rounded px-3 py-2 overflow-x-auto whitespace-pre">
          {snippet || 'Loading your embed code…'}
        </pre>
        {snippet && (
          <button
            onClick={copy}
            className="text-xs font-medium px-3 py-2 rounded bg-indigo-50 text-indigo-700 hover:bg-indigo-100"
          >
            {copied ? 'Copied!' : 'Copy'}
          </button>
        )}
      </div>
    </div>
  );
}
