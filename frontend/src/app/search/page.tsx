'use client';

import { useState } from 'react';

interface Product {
    id: string;
    title: string;
    description: string;
    price: number;
    category: string;
    brand: string;
    tags: string;
    image_url?: string;
}

interface SearchResponse {
    query: string;
    total: number;
    results: Product[];
}

export default function SearchPage() {
    const [query, setQuery] = useState('');
    const [results, setResults] = useState<Product[]>([]);
    const [isSearching, setIsSearching] = useState(false);
    const [hasSearched, setHasSearched] = useState(false);

    const handleSearch = async (e: React.FormEvent) => {
        e.preventDefault();
        if (!query.trim()) return;

        setIsSearching(true);
        setHasSearched(true);

        try {
            const response = await fetch(`http://localhost:8000/search?q=${encodeURIComponent(query)}`);
            const data: SearchResponse = await response.json();
            setResults(data.results || []);
        } catch (error) {
            console.error('Search failed:', error);
            setResults([]);
        } finally {
            setIsSearching(false);
        }
    };

    const trackEvent = async (type: 'click' | 'order', product: Product) => {
        try {
            await fetch('http://localhost:8000/analytics/track', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    type,
                    product_id: product.id,
                    title: product.title,
                }),
            });
        } catch (error) {
            console.error('Tracking failed:', error);
        }
    };

    const handleBuy = async (e: React.MouseEvent, product: Product) => {
        e.stopPropagation();
        await trackEvent('order', product);
        alert(`Order placed for ${product.title}!`);
    };

    return (
        <div className="min-h-screen bg-gray-50 p-8">
            <div className="max-w-4xl mx-auto">
                <div className="text-center mb-10">
                    <h1 className="text-3xl font-bold text-gray-900 mb-4">PolarBear Search</h1>
                    <p className="text-gray-600">Hybrid Search for your Product Catalog</p>
                    <div className="mt-4">
                        <a href="/upload" className="text-indigo-600 hover:text-indigo-800 text-sm font-medium">
                            Need to add more products? Upload CSV &rarr;
                        </a>
                    </div>
                </div>

                {/* Search Bar */}
                <form onSubmit={handleSearch} className="mb-10">
                    <div className="flex gap-4">
                        <input
                            type="text"
                            value={query}
                            onChange={(e) => setQuery(e.target.value)}
                            placeholder="Search for products (e.g., 'warm jacket' or 'shirt')..."
                            className="flex-1 p-4 rounded-lg border border-gray-300 shadow-sm focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 outline-none"
                        />
                        <button
                            type="submit"
                            disabled={isSearching}
                            className="px-8 py-4 bg-indigo-600 text-white font-medium rounded-lg hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500 disabled:bg-gray-400"
                        >
                            {isSearching ? 'Searching...' : 'Search'}
                        </button>
                    </div>
                </form>

                {/* Results */}
                <div className="space-y-6">
                    {hasSearched && results.length === 0 && !isSearching && (
                        <div className="text-center text-gray-500 py-10">
                            No results found for "{query}".
                        </div>
                    )}

                    {results.map((product) => (
                        <div
                            key={product.id}
                            onClick={() => trackEvent('click', product)}
                            className="bg-white p-6 rounded-xl shadow-sm hover:shadow-md transition-shadow border border-gray-100 cursor-pointer flex gap-6"
                        >
                            {/* Image */}
                            <div className="w-32 h-32 flex-shrink-0 bg-gray-100 rounded-lg overflow-hidden">
                                {product.image_url ? (
                                    <img src={product.image_url} alt={product.title} className="w-full h-full object-cover" />
                                ) : (
                                    <div className="w-full h-full flex items-center justify-center text-gray-400">
                                        <span className="text-xs">No Image</span>
                                    </div>
                                )}
                            </div>

                            <div className="flex-1 flex justify-between items-start">
                                <div>
                                    <h3 className="text-xl font-semibold text-gray-900 mb-2">{product.title}</h3>
                                    <p className="text-gray-600 mb-4">{product.description}</p>
                                    <div className="flex flex-wrap gap-2 mb-4">
                                        <span className="px-3 py-1 bg-blue-50 text-blue-700 rounded-full text-sm font-medium">
                                            {product.brand}
                                        </span>
                                        <span className="px-3 py-1 bg-green-50 text-green-700 rounded-full text-sm font-medium">
                                            {product.category}
                                        </span>
                                        {product.tags.split(',').map(tag => (
                                            <span key={tag} className="px-3 py-1 bg-gray-100 text-gray-600 rounded-full text-sm">
                                                #{tag.trim()}
                                            </span>
                                        ))}
                                    </div>
                                    <button
                                        onClick={(e) => handleBuy(e, product)}
                                        className="px-4 py-2 bg-green-600 text-white text-sm font-medium rounded hover:bg-green-700 transition-colors"
                                    >
                                        Buy Now
                                    </button>
                                </div>
                                <div className="text-right">
                                    <span className="text-2xl font-bold text-gray-900">${product.price}</span>
                                </div>
                            </div>
                        </div>
                    ))}
                </div>
            </div>
        </div>
    );
}
