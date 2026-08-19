'use client';

import { useState } from 'react';
import { API_URL } from '../../lib/api';

export default function ForgotPasswordPage() {
  const [email, setEmail] = useState('');
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    try {
      await fetch(`${API_URL}/auth/forgot-password`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email }),
      });
    } catch {
      /* the message below is deliberately the same either way */
    } finally {
      setBusy(false);
      setSent(true);
    }
  };

  return (
    <div className="min-h-screen bg-gray-50 p-8">
      <div className="max-w-md mx-auto bg-white rounded-xl shadow-md p-6 mt-12">
        <div className="uppercase tracking-wide text-sm text-indigo-500 font-semibold mb-2">
          Account recovery
        </div>
        <h1 className="text-lg font-medium text-black mb-6">Reset your password</h1>

        {sent ? (
          <p className="text-sm text-gray-700">
            If that address has an account, we&apos;ve sent a reset link. It expires in
            one hour.
          </p>
        ) : (
          <form onSubmit={submit} className="space-y-4">
            <div>
              <label className="block text-gray-700 text-sm font-bold mb-2" htmlFor="email">
                Email
              </label>
              <input
                id="email"
                type="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
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
              {busy ? 'Sending…' : 'Send reset link'}
            </button>
          </form>
        )}

        <p className="mt-6 text-sm text-gray-500 text-center">
          <a href="/login" className="text-indigo-600 hover:underline">
            Back to sign in
          </a>
        </p>
      </div>
    </div>
  );
}
