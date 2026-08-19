'use client';

import { useEffect, useState } from 'react';
import { authFetch, clearToken, useRequireAuth } from '../../lib/api';

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
        <DangerZone />
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
  web: { status: 'ok' | 'wrong_domain' | 'none'; origin: string | null; last_seen: string | null };
  api: { status: 'active' | 'none'; search_count: number; last_seen: string | null };
  verdict: 'ok' | 'api_only' | 'wrong_domain' | 'not_found' | 'no_website';
}

/**
 * Relative time since an install-ping's `last_seen`. The backend serializes
 * naive UTC timestamps (no timezone suffix), so we append 'Z' before parsing.
 */
function ago(iso: string | null): string {
  if (!iso) return '';
  const then = new Date(`${iso}Z`);
  const diffMin = Math.floor((Date.now() - then.getTime()) / 60000);
  if (diffMin < 1) return 'just now';
  if (diffMin < 60) return `${diffMin} minute${diffMin === 1 ? '' : 's'} ago`;
  const diffHr = Math.floor(diffMin / 60);
  if (diffHr < 24) return `${diffHr} hour${diffHr === 1 ? '' : 's'} ago`;
  const diffDay = Math.floor(diffHr / 24);
  return `${diffDay} day${diffDay === 1 ? '' : 's'} ago`;
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
        setWebsite(d.website_url ?? '');
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
      setWebsite(d.website_url ?? '');
      load();
    }
  };

  const check = async () => {
    setChecking(true);
    await new Promise((r) => setTimeout(r, 400));
    load();
    setChecking(false);
  };

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
      <p className="-mt-1 mb-3 text-xs text-gray-500">
        Only using an app or the API? Leave this empty.
      </p>

      <button
        onClick={check}
        disabled={checking}
        className={`text-sm font-medium px-4 py-2 rounded-md text-white ${
          checking ? 'bg-gray-400' : 'bg-indigo-600 hover:bg-indigo-700'
        }`}
      >
        {checking ? 'Checking…' : 'Check my installation'}
      </button>

      {status && (() => {
        const webStatus = status.web?.status ?? 'none';
        const apiStatus = status.api?.status ?? 'none';
        const searchPing = status.pings?.find(
          (p) => p.kind === 'search' && p.origin === status.web?.origin
        );
        const searchCount = status.api?.search_count ?? 0;
        const lastSeen = ago(status.api?.last_seen ?? null);

        return (
          <div className="mt-4 space-y-3">
            <div>
              <div className="text-xs font-semibold text-gray-700 mb-1">Website</div>
              {webStatus === 'ok' && (
                <div className="p-3 rounded bg-green-50 text-green-800 text-sm">
                  Search box loaded on <strong>{status.web?.origin}</strong> —{' '}
                  {searchPing
                    ? `it has answered ${searchPing.count} search${
                        searchPing.count === 1 ? '' : 'es'
                      }.`
                    : 'no shopper has searched yet.'}
                </div>
              )}
              {webStatus === 'wrong_domain' && (
                <div className="p-3 rounded bg-amber-50 text-amber-800 text-sm">
                  Found the search box on <strong>{status.web?.origin}</strong>, but not on{' '}
                  <strong>{saved ?? 'your website'}</strong>. If that&apos;s a staging site
                  you&apos;re fine — otherwise update the address above.
                </div>
              )}
              {webStatus === 'none' && (
                <div className="p-3 rounded bg-gray-50 text-gray-500 text-sm">Not detected</div>
              )}
            </div>

            <div>
              <div className="text-xs font-semibold text-gray-700 mb-1">App / API</div>
              {apiStatus === 'active' ? (
                <div className="p-3 rounded bg-green-50 text-green-800 text-sm">
                  {searchCount === 0 ? (
                    'API connection detected — no searches yet.'
                  ) : (
                    <>
                      Received <strong>{searchCount}</strong> search
                      {searchCount === 1 ? '' : 'es'} from an app or server.
                      {lastSeen && ` (last seen ${lastSeen})`}
                    </>
                  )}
                </div>
              ) : (
                <div className="p-3 rounded bg-gray-50 text-gray-500 text-sm">Not detected</div>
              )}
            </div>

            {webStatus === 'none' && apiStatus === 'none' && (
              <div className="p-3 rounded bg-red-50 text-red-700 text-sm">
                <p className="font-medium mb-1">Nothing has reached us yet.</p>
                <ul className="list-disc list-inside space-y-0.5 text-xs">
                  <li>Did you save and publish the page after pasting?</li>
                  <li>Is the code on a live page rather than a draft?</li>
                  <li>Did you paste both lines, including the one starting with &lt;div&gt;?</li>
                  <li>Open your site once — the check only sees pages that have loaded.</li>
                  <li>Integrating from an app? Run one search from it, then check again.</li>
                </ul>
              </div>
            )}
          </div>
        );
      })()}
    </div>
  );
}

function DangerZone() {
  const [email, setEmail] = useState('');
  const [expected, setExpected] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    authFetch('/users/me')
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => d && setExpected(d.email))
      .catch(() => {});
  }, []);

  const remove = async () => {
    if (!confirm('This permanently deletes your catalog, analytics and account. Continue?')) {
      return;
    }
    setBusy(true);
    setError('');
    try {
      const r = await authFetch('/tenant/account', {
        method: 'DELETE',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email }),
      });
      if (r.ok) {
        clearToken();
        window.location.href = '/login';
      } else {
        const d = await r.json().catch(() => ({}));
        setError(typeof d.detail === 'string' ? d.detail : 'Could not delete the account.');
        setBusy(false);
      }
    } catch (e) {
      setError('Could not reach the server. Check your connection and try again.');
      setBusy(false);
    }
  };

  const matches = expected !== '' && email.toLowerCase() === expected.toLowerCase();

  return (
    <div className="mt-6 p-4 border border-red-300 rounded-lg">
      <h2 className="text-sm font-semibold text-red-700 mb-1">Delete this account</h2>
      <p className="text-xs text-gray-600 mb-3">
        This removes your products, search index, images, analytics and API keys
        immediately and permanently. Your search box will stop working everywhere it is
        installed. Download anything you need first.
      </p>
      <div className="flex gap-2">
        <input
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder={expected || 'type your email to confirm'}
          className="flex-1 border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-red-500"
        />
        <button
          onClick={remove}
          disabled={busy || !matches}
          className={`text-sm font-medium px-4 py-2 rounded-md text-white ${
            busy || !matches ? 'bg-gray-400 cursor-not-allowed' : 'bg-red-600 hover:bg-red-700'
          }`}
        >
          {busy ? 'Deleting…' : 'Delete account'}
        </button>
      </div>
      {error && <div className="mt-3 p-3 rounded bg-red-100 text-red-700 text-sm">{error}</div>}
    </div>
  );
}
