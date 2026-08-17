'use client';

import { useEffect, useState } from 'react';
import { authFetch, getToken } from '../lib/api';

export default function InstallStatusLine() {
  const [verdict, setVerdict] = useState<string | null>(null);
  const [origin, setOrigin] = useState<string | null>(null);

  useEffect(() => {
    if (!getToken()) return;
    authFetch('/tenant/install-status')
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => {
        if (!d) return;
        setVerdict(d.verdict);
        setOrigin(d.web?.origin ?? null);
      })
      .catch(() => {});
  }, []);

  if (!verdict) return null;

  const live = verdict === 'ok' || verdict === 'api_only';
  const label =
    verdict === 'api_only' ? 'App / API integration' : origin;

  return (
    <p className="mt-6 text-sm text-gray-500">
      <span
        className={`inline-block w-2 h-2 rounded-full mr-2 align-middle ${
          live ? 'bg-green-500' : 'bg-gray-300'
        }`}
      />
      {live ? (
        <>Search live on <span className="font-medium text-gray-700">{label}</span></>
      ) : (
        <>
          Search not installed yet ·{' '}
          <a href="/settings" className="text-indigo-600 hover:underline">
            finish setup
          </a>
        </>
      )}
    </p>
  );
}
