'use client';

import { Suspense, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { API_URL } from '../../lib/api';

function ResetForm() {
  const router = useRouter();
  const token = useSearchParams().get('token') ?? '';
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setBusy(true);
    try {
      const res = await fetch(`${API_URL}/auth/reset-password`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token, password }),
      });
      if (!res.ok) {
        setError('This reset link has expired or already been used — request a new one.');
        return;
      }
      router.push('/login');
    } catch {
      setError('Could not reach the server. Try again in a moment.');
    } finally {
      setBusy(false);
    }
  };

  if (!token) {
    return (
      <p className="text-sm text-gray-700">
        This link is missing its token.{' '}
        <a href="/forgot-password" className="text-indigo-600 hover:underline">
          Request a new one
        </a>
        .
      </p>
    );
  }

  return (
    <form onSubmit={submit} className="space-y-4">
      <div>
        <label className="block text-gray-700 text-sm font-bold mb-2" htmlFor="password">
          New password
        </label>
        <input
          id="password"
          type="password"
          required
          minLength={8}
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          className="w-full border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
        />
      </div>
      <button
        type="submit"
        disabled={busy}
        className={`w-full py-2 px-4 rounded-md text-sm font-medium text-white ${
          busy ? 'bg-gray-400 cursor-not-allowed' : 'bg-indigo-600 hover:bg-indigo-700'
        }`}
      >
        {busy ? 'Saving…' : 'Set new password'}
      </button>
      {error && <div className="p-3 rounded bg-red-100 text-red-700 text-sm">{error}</div>}
    </form>
  );
}

export default function ResetPasswordPage() {
  return (
    <div className="min-h-screen bg-gray-50 p-8">
      <div className="max-w-md mx-auto bg-white rounded-xl shadow-md p-6 mt-12">
        <div className="uppercase tracking-wide text-sm text-indigo-500 font-semibold mb-2">
          Account recovery
        </div>
        <h1 className="text-lg font-medium text-black mb-6">Choose a new password</h1>
        <Suspense fallback={<p className="text-sm text-gray-500">Loading…</p>}>
          <ResetForm />
        </Suspense>
      </div>
    </div>
  );
}
