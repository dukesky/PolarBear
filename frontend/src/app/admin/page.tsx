'use client';

import { useState, useEffect } from 'react';

interface AnalyticsData {
    total_searches: number;
    top_queries: { query: string; count: number }[];
    zero_results: { query: string; count: number }[];
}

export default function AdminPage() {
    const [data, setData] = useState<AnalyticsData | null>(null);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        const fetchData = async () => {
            try {
                const response = await fetch('http://localhost:8000/analytics/stats');
                const result = await response.json();
                setData(result);
            } catch (error) {
                console.error('Failed to fetch analytics:', error);
            } finally {
                setLoading(false);
            }
        };

        fetchData();
    }, []);

    if (loading) {
        return <div className="min-h-screen flex items-center justify-center">Loading...</div>;
    }

    if (!data) {
        return <div className="min-h-screen flex items-center justify-center text-red-500">Failed to load data.</div>;
    }

    return (
        <div className="min-h-screen bg-gray-50 p-8">
            <div className="max-w-6xl mx-auto">
                <div className="flex justify-between items-center mb-10">
                    <div>
                        <h1 className="text-3xl font-bold text-gray-900">Admin Dashboard</h1>
                        <p className="text-gray-600">Search Analytics & Insights</p>
                    </div>
                    <a href="/search" className="text-indigo-600 hover:text-indigo-800 font-medium">
                        Go to Search &rarr;
                    </a>
                </div>

                {/* Stats Grid */}
                <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-10">
                    <div className="bg-white p-6 rounded-xl shadow-sm border border-gray-100">
                        <h3 className="text-sm font-medium text-gray-500 uppercase tracking-wider mb-2">Total Searches</h3>
                        <p className="text-4xl font-bold text-indigo-600">{data.total_searches}</p>
                    </div>
                    {/* Add more cards here later (e.g., Total Products) */}
                </div>

                <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
                    {/* Top Queries */}
                    <div className="bg-white rounded-xl shadow-sm border border-gray-100 overflow-hidden">
                        <div className="p-6 border-b border-gray-100">
                            <h3 className="text-lg font-semibold text-gray-900">Top Search Queries</h3>
                        </div>
                        <table className="w-full text-left">
                            <thead>
                                <tr className="bg-gray-50 text-gray-500 text-sm">
                                    <th className="px-6 py-3 font-medium">Query</th>
                                    <th className="px-6 py-3 font-medium text-right">Count</th>
                                </tr>
                            </thead>
                            <tbody className="divide-y divide-gray-100">
                                {data.top_queries.length === 0 ? (
                                    <tr>
                                        <td colSpan={2} className="px-6 py-4 text-center text-gray-500">No data yet.</td>
                                    </tr>
                                ) : (
                                    data.top_queries.map((item, idx) => (
                                        <tr key={idx} className="hover:bg-gray-50">
                                            <td className="px-6 py-4 text-gray-900">{item.query}</td>
                                            <td className="px-6 py-4 text-right text-gray-600">{item.count}</td>
                                        </tr>
                                    ))
                                )}
                            </tbody>
                        </table>
                    </div>

                    {/* Zero Results */}
                    <div className="bg-white rounded-xl shadow-sm border border-gray-100 overflow-hidden">
                        <div className="p-6 border-b border-gray-100 bg-red-50">
                            <h3 className="text-lg font-semibold text-red-900">Missed Opportunities (0 Results)</h3>
                            <p className="text-sm text-red-700 mt-1">Users searched for these but found nothing.</p>
                        </div>
                        <table className="w-full text-left">
                            <thead>
                                <tr className="bg-gray-50 text-gray-500 text-sm">
                                    <th className="px-6 py-3 font-medium">Query</th>
                                    <th className="px-6 py-3 font-medium text-right">Count</th>
                                </tr>
                            </thead>
                            <tbody className="divide-y divide-gray-100">
                                {data.zero_results.length === 0 ? (
                                    <tr>
                                        <td colSpan={2} className="px-6 py-4 text-center text-gray-500">No missed searches yet.</td>
                                    </tr>
                                ) : (
                                    data.zero_results.map((item, idx) => (
                                        <tr key={idx} className="hover:bg-gray-50">
                                            <td className="px-6 py-4 text-gray-900">{item.query}</td>
                                            <td className="px-6 py-4 text-right text-gray-600">{item.count}</td>
                                        </tr>
                                    ))
                                )}
                            </tbody>
                        </table>
                    </div>
                </div>
            </div>
        </div>
    );
}
