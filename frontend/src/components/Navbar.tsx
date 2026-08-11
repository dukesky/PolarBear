'use client';

import Link from 'next/link';
import { useEffect, useState } from 'react';
import { authFetch, clearToken, getToken } from '../lib/api';

export default function Navbar() {
  const [email, setEmail] = useState<string | null>(null);

  useEffect(() => {
    if (!getToken()) return;
    authFetch('/users/me')
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => d && setEmail(d.email))
      .catch(() => {});
  }, []);

  const signOut = () => {
    clearToken();
    window.location.href = '/login';
  };

  const links = [
    { href: '/', label: 'Home' },
    { href: '/search', label: 'Search' },
    { href: '/upload', label: 'Upload' },
    { href: '/insights', label: 'Insights' },
    { href: '/settings', label: 'Settings' },
  ];

  return (
    <nav className="bg-white border-b border-gray-200">
      <div className="max-w-6xl mx-auto px-4">
        <div className="flex justify-between h-16">
          <div className="flex">
            <div className="flex-shrink-0 flex items-center">
              <Link href="/" className="text-xl font-bold text-indigo-600">
                PolarBear
              </Link>
            </div>
            <div className="hidden sm:ml-6 sm:flex sm:space-x-8">
              {links.map((l) => (
                <Link
                  key={l.href}
                  href={l.href}
                  className="border-transparent text-gray-500 hover:border-gray-300 hover:text-gray-700 inline-flex items-center px-1 pt-1 border-b-2 text-sm font-medium"
                >
                  {l.label}
                </Link>
              ))}
            </div>
          </div>
          <div className="flex items-center space-x-4">
            {email ? (
              <>
                <span className="text-sm text-gray-500">{email}</span>
                <button
                  onClick={signOut}
                  className="text-sm font-medium text-gray-500 hover:text-gray-700"
                >
                  Sign out
                </button>
              </>
            ) : (
              <Link href="/login" className="text-sm font-medium text-indigo-600 hover:text-indigo-700">
                Sign in
              </Link>
            )}
          </div>
        </div>
      </div>
    </nav>
  );
}
