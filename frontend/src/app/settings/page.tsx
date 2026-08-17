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
        <InstallCheck />
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

      <p className="mt-3 text-xs text-gray-500">
        Someone else maintains your site?{' '}
        <a
          className="text-indigo-600 hover:underline"
          href={`mailto:?subject=${encodeURIComponent(
            'Please add our product search box to the website'
          )}&body=${encodeURIComponent(
            `Hi,\n\nPlease add our product search to the website.\n\n` +
              `Paste these two lines where the search box should appear:\n\n${snippet}\n\n` +
              `The first line is the spot the box renders in; the second loads it.\n` +
              `Platform-by-platform instructions: https://github.com/dukesky/PolarBear/blob/main/docs/INTEGRATION.md\n\n` +
              `Thanks!`
          )}`}
        >
          Email these instructions to them
        </a>
      </p>
    </div>
  );
}

interface StatusResponse {
  website_url: string | null;
  pings: { origin: string; kind: string; count: number; last_seen: string | null }[];
  verdict: 'ok' | 'wrong_domain' | 'not_found' | 'no_website';
}

function InstallCheck() {
  const [website, setWebsite] = useState('');
  const [saved, setSaved] = useState<string | null>(null);
  const [status, setStatus] = useState<StatusResponse | null>(null);
  const [checking, setChecking] = useState(false);

  const load = () => {
    authFetch('/tenant/install-status')
      .then((r) => (r.ok ? r.json() : null))
      .then((d: StatusResponse | null) => {
        if (!d) return;
        setStatus(d);
        setSaved(d.website_url);
        if (d.website_url) setWebsite(d.website_url);
      })
      .catch(() => {});
  };

  useEffect(load, []);

  const saveWebsite = async (e: React.FormEvent) => {
    e.preventDefault();
    const r = await authFetch('/tenant/website', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ website_url: website }),
    });
    if (r.ok) {
      const d = await r.json();
      setSaved(d.website_url);
      setWebsite(d.website_url);
      load();
    }
  };

  const check = async () => {
    setChecking(true);
    await new Promise((r) => setTimeout(r, 400));
    load();
    setChecking(false);
  };

  const loadPing = status?.pings.find((p) => p.kind === 'load');
  const searchPing = status?.pings.find((p) => p.kind === 'search');

  return (
    <div className="mt-6 p-4 border border-gray-200 rounded-lg">
      <h2 className="text-sm font-semibold text-gray-900 mb-1">Check your installation</h2>
      <p className="text-xs text-gray-500 mb-3">
        After pasting the code into your site, confirm it&apos;s live here.
      </p>

      <form onSubmit={saveWebsite} className="flex gap-2 mb-3">
        <input
          value={website}
          onChange={(e) => setWebsite(e.target.value)}
          placeholder="yourstore.com"
          className="flex-1 border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
        />
        <button
          type="submit"
          className="text-xs font-medium px-3 py-2 rounded bg-indigo-50 text-indigo-700 hover:bg-indigo-100"
        >
          {saved ? 'Update' : 'Save'}
        </button>
      </form>

      <button
        onClick={check}
        disabled={checking}
        className={`text-sm font-medium px-4 py-2 rounded-md text-white ${
          checking ? 'bg-gray-400' : 'bg-indigo-600 hover:bg-indigo-700'
        }`}
      >
        {checking ? 'Checking…' : 'Check my installation'}
      </button>

      {status?.verdict === 'ok' && (
        <div className="mt-3 p-3 rounded bg-green-50 text-green-800 text-sm">
          Working — the search box loaded on <strong>{loadPing?.origin}</strong>.
          {searchPing
            ? ` It has answered ${searchPing.count} searches.`
            : ' No shopper has searched yet.'}
        </div>
      )}
      {status?.verdict === 'wrong_domain' && (
        <div className="mt-3 p-3 rounded bg-amber-50 text-amber-800 text-sm">
          Found the search box on <strong>{loadPing?.origin}</strong>, but not on{' '}
          <strong>{saved}</strong>. If that&apos;s a staging site, you&apos;re fine —
          otherwise update the address above or check which site you pasted the code
          into.
        </div>
      )}
      {status?.verdict === 'not_found' && (
        <div className="mt-3 p-3 rounded bg-red-50 text-red-700 text-sm">
          <p className="font-medium mb-1">No sign of the search box yet.</p>
          <ul className="list-disc list-inside space-y-0.5 text-xs">
            <li>Did you save and publish the page after pasting?</li>
            <li>Is the code on a live page rather than a draft?</li>
            <li>Did you paste both lines, including the one starting with &lt;div&gt;?</li>
            <li>Open your site once — the check only sees pages that have loaded.</li>
          </ul>
        </div>
      )}
      {status?.verdict === 'no_website' && (
        <div className="mt-3 p-3 rounded bg-gray-50 text-gray-600 text-sm">
          Add your website address above so we can tell you whether the box is live on
          it.
        </div>
      )}
    </div>
  );
}
