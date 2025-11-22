'use client';

import { useState, useEffect } from 'react';

interface AnalyticsData {
    total_searches: number;
    top_queries: { query: string; count: number }[];
    zero_results: { query: string; count: number }[];
    product_stats: { product_id: string; title: string; clicks: number; orders: number }[];
}

export default function InsightsPage() {
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
                        <h1 className="text-3xl font-bold text-gray-900">Insights Dashboard</h1>
                        <p className="text-gray-600">Search Analytics & Product Performance</p>
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

                {/* Product Performance */}
                <div className="mt-10 bg-white rounded-xl shadow-sm border border-gray-100 overflow-hidden">
                    <div className="p-6 border-b border-gray-100">
                        <h3 className="text-lg font-semibold text-gray-900">Product Performance</h3>
                        <p className="text-sm text-gray-500 mt-1">Clicks and Orders tracking.</p>
                    </div>
                    <table className="w-full text-left">
                        <thead>
                            <tr className="bg-gray-50 text-gray-500 text-sm">
                                <th className="px-6 py-3 font-medium">Product</th>
                                <th className="px-6 py-3 font-medium text-right">Clicks</th>
                                <th className="px-6 py-3 font-medium text-right">Orders</th>
                                <th className="px-6 py-3 font-medium text-right">Conversion Rate</th>
                            </tr>
                        </thead>
                        <tbody className="divide-y divide-gray-100">
                            {data.product_stats.length === 0 ? (
                                <tr>
                                    <td colSpan={4} className="px-6 py-4 text-center text-gray-500">No product activity yet.</td>
                                </tr>
                            ) : (
                                data.product_stats.map((item) => (
                                    <tr key={item.product_id} className="hover:bg-gray-50">
                                        <td className="px-6 py-4 text-gray-900 font-medium">{item.title}</td>
                                        <td className="px-6 py-4 text-right text-gray-600">{item.clicks}</td>
                                        <td className="px-6 py-4 text-right text-green-600 font-medium">{item.orders}</td>
                                        <td className="px-6 py-4 text-right text-gray-600">
                                            {item.clicks > 0 ? ((item.orders / item.clicks) * 100).toFixed(1) : '0.0'}%
                                        </td>
                                    </tr>
                                ))
                            )}
                        </tbody>
                    </table>
                </div>
            </div>

            {/* Product Catalog Section */}
            <ProductCatalog />
        </div>
    );
}

function ProductCatalog() {
    const [products, setProducts] = useState<any[]>([]);
    const [editingProduct, setEditingProduct] = useState<any | null>(null);
    const [loading, setLoading] = useState(true);

    const fetchProducts = async () => {
        try {
            const res = await fetch('http://localhost:8000/products/');
            const data = await res.json();
            setProducts(data);
        } catch (e) {
            console.error(e);
        } finally {
            setLoading(false);
        }
    };

    useEffect(() => {
        fetchProducts();
    }, []);

    const handleSave = async (e: React.FormEvent) => {
        e.preventDefault();
        if (!editingProduct) return;

        try {
            await fetch(`http://localhost:8000/products/${editingProduct.id}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    title: editingProduct.title,
                    description: editingProduct.description,
                    price: parseFloat(editingProduct.price),
                    image_url: editingProduct.image_url
                })
            });
            setEditingProduct(null);
            fetchProducts(); // Refresh
        } catch (e) {
            alert('Failed to save');
        }
    };

    const handleImageUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
        if (!e.target.files || !e.target.files[0] || !editingProduct) return;
        const file = e.target.files[0];
        const formData = new FormData();
        formData.append('file', file);

        try {
            const res = await fetch(`http://localhost:8000/products/${editingProduct.id}/image`, {
                method: 'POST',
                body: formData
            });
            const data = await res.json();
            setEditingProduct({ ...editingProduct, image_url: data.image_url });
        } catch (e) {
            alert('Image upload failed');
        }
    };

    return (
        <div className="mt-10 bg-white rounded-xl shadow-sm border border-gray-100 overflow-hidden">
            <div className="p-6 border-b border-gray-100 flex justify-between items-center">
                <div>
                    <h3 className="text-lg font-semibold text-gray-900">Product Catalog</h3>
                    <p className="text-sm text-gray-500 mt-1">Manage your inventory.</p>
                </div>
                <button onClick={fetchProducts} className="text-indigo-600 hover:text-indigo-800 text-sm">Refresh</button>
            </div>

            <div className="overflow-x-auto">
                <table className="w-full text-left">
                    <thead>
                        <tr className="bg-gray-50 text-gray-500 text-sm">
                            <th className="px-6 py-3 font-medium">Image</th>
                            <th className="px-6 py-3 font-medium">Title</th>
                            <th className="px-6 py-3 font-medium">Price</th>
                            <th className="px-6 py-3 font-medium text-right">Actions</th>
                        </tr>
                    </thead>
                    <tbody className="divide-y divide-gray-100">
                        {products.map(p => (
                            <tr key={p.id} className="hover:bg-gray-50">
                                <td className="px-6 py-4">
                                    <div className="w-12 h-12 bg-gray-100 rounded overflow-hidden">
                                        {p.image_url && <img src={p.image_url} alt="" className="w-full h-full object-cover" />}
                                    </div>
                                </td>
                                <td className="px-6 py-4 font-medium text-gray-900">{p.title}</td>
                                <td className="px-6 py-4 text-gray-600">${p.price}</td>
                                <td className="px-6 py-4 text-right">
                                    <button
                                        onClick={() => setEditingProduct(p)}
                                        className="text-indigo-600 hover:text-indigo-900 font-medium"
                                    >
                                        Edit
                                    </button>
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>

            {/* Edit Modal */}
            {editingProduct && (
                <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 p-4">
                    <div className="bg-white rounded-xl max-w-lg w-full p-6 shadow-2xl">
                        <h3 className="text-xl font-bold mb-4">Edit Product</h3>
                        <form onSubmit={handleSave} className="space-y-4">
                            <div>
                                <label className="block text-sm font-medium text-gray-700">Title</label>
                                <input
                                    type="text"
                                    value={editingProduct.title}
                                    onChange={e => setEditingProduct({ ...editingProduct, title: e.target.value })}
                                    className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 border p-2"
                                />
                            </div>
                            <div>
                                <label className="block text-sm font-medium text-gray-700">Description</label>
                                <textarea
                                    value={editingProduct.description}
                                    onChange={e => setEditingProduct({ ...editingProduct, description: e.target.value })}
                                    className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 border p-2"
                                    rows={3}
                                />
                            </div>
                            <div>
                                <label className="block text-sm font-medium text-gray-700">Price</label>
                                <input
                                    type="number"
                                    value={editingProduct.price}
                                    onChange={e => setEditingProduct({ ...editingProduct, price: e.target.value })}
                                    className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 border p-2"
                                />
                            </div>
                            <div>
                                <label className="block text-sm font-medium text-gray-700">Image</label>
                                <div className="mt-1 flex items-center gap-4">
                                    {editingProduct.image_url && (
                                        <img src={editingProduct.image_url} alt="" className="w-16 h-16 object-cover rounded" />
                                    )}
                                    <input type="file" onChange={handleImageUpload} className="text-sm" />
                                </div>
                            </div>
                            <div className="flex justify-end gap-3 mt-6">
                                <button
                                    type="button"
                                    onClick={() => setEditingProduct(null)}
                                    className="px-4 py-2 text-gray-700 hover:bg-gray-100 rounded-lg"
                                >
                                    Cancel
                                </button>
                                <button
                                    type="submit"
                                    className="px-4 py-2 bg-indigo-600 text-white rounded-lg hover:bg-indigo-700"
                                >
                                    Save Changes
                                </button>
                            </div>
                        </form>
                    </div>
                </div>
            )}
        </div>
    );
}
