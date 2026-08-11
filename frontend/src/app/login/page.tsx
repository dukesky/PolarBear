'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { API_URL, setToken } from '../../lib/api';

export default function LoginPage() {
  const router = useRouter();
  const [mode, setMode] = useState<'login' | 'register'>('login');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [googleEnabled, setGoogleEnabled] = useState(false);

  useEffect(() => {
    // OAuth redirect lands here with #token=<jwt>
    const hash = window.location.hash;
    if (hash.startsWith('#token=')) {
      setToken(hash.slice(7));
      router.replace('/');
      return;
    }
    fetch(`${API_URL}/auth/providers`)
      .then((r) => r.json())
      .then((d) => setGoogleEnabled(!!d.google))
      .catch(() => {});
  }, [router]);

  const doLogin = async () => {
    const body = new URLSearchParams({ username: email, password });
    const res = await fetch(`${API_URL}/auth/jwt/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
    });
    if (!res.ok) throw new Error('Invalid email or password.');
    const data = await res.json();
    setToken(data.access_token);
    router.push('/');
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setBusy(true);
    try {
      if (mode === 'register') {
        const res = await fetch(`${API_URL}/auth/register`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ email, password }),
        });
        if (!res.ok) {
          const d = await res.json().catch(() => ({}));
          throw new Error(typeof d.detail === 'string' ? d.detail : 'Registration failed.');
        }
      }
      await doLogin();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Something went wrong.');
    } finally {
      setBusy(false);
    }
  };

  const handleGoogle = async () => {
    const res = await fetch(`${API_URL}/auth/google/authorize`);
    const data = await res.json();
    window.location.href = data.authorization_url;
  };

  return (
    <div className="min-h-screen bg-gray-50 p-8">
      <div className="max-w-md mx-auto bg-white rounded-xl shadow-md p-6 mt-12">
        <div className="uppercase tracking-wide text-sm text-indigo-500 font-semibold mb-2">
          {mode === 'login' ? 'Welcome back' : 'Get started'}
        </div>
        <h1 className="text-lg font-medium text-black mb-6">
          {mode === 'login' ? 'Sign in to PolarBear' : 'Create your PolarBear account'}
        </h1>

        <form onSubmit={handleSubmit} className="space-y-4">
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
          <div>
            <label className="block text-gray-700 text-sm font-bold mb-2" htmlFor="password">
              Password
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
            {busy ? 'Please wait…' : mode === 'login' ? 'Sign in' : 'Create account'}
          </button>
        </form>

        {googleEnabled && (
          <button
            onClick={handleGoogle}
            className="w-full mt-3 py-2 px-4 rounded-md text-sm font-medium border border-gray-300 text-gray-700 hover:bg-gray-50"
          >
            Continue with Google
          </button>
        )}

        {error && (
          <div className="mt-4 p-3 rounded bg-red-100 text-red-700 text-sm">{error}</div>
        )}

        <p className="mt-6 text-sm text-gray-500 text-center">
          {mode === 'login' ? (
            <>
              New to PolarBear?{' '}
              <button onClick={() => setMode('register')} className="text-indigo-600 hover:underline">
                Create an account
              </button>
            </>
          ) : (
            <>
              Already have an account?{' '}
              <button onClick={() => setMode('login')} className="text-indigo-600 hover:underline">
                Sign in
              </button>
            </>
          )}
        </p>
      </div>
    </div>
  );
}
