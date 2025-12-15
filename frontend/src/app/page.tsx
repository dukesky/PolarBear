import Link from "next/link";
import Image from "next/image";

export default function Home() {
  return (
    <div className="min-h-screen bg-gray-50 flex flex-col items-center justify-center p-8">
      <div className="max-w-2xl text-center space-y-8 flex flex-col items-center">
        <div className="flex items-center justify-center gap-4">
          <h1 className="text-5xl font-bold text-indigo-900 tracking-tight">
            PolarBear
          </h1>
          <Image
            src="/PolarBear_logo.png"
            alt="PolarBear Logo"
            width={60}
            height={60}
            className="object-contain"
            priority
          />
        </div>
        <p className="text-xl text-gray-600">
          The Open-Source Hybrid Search Engine for SMEs.
          <br />
          Powerful, AI-enhanced, and easy to use.
        </p>

        <div className="flex flex-col sm:flex-row gap-4 justify-center mt-8">
          <Link
            href="/search"
            className="px-8 py-3 bg-indigo-600 text-white font-semibold rounded-full hover:bg-indigo-700 transition shadow-lg hover:shadow-xl"
          >
            Start Searching
          </Link>
          <Link
            href="/upload"
            className="px-8 py-3 bg-white text-indigo-600 font-semibold rounded-full border border-indigo-200 hover:bg-indigo-50 transition shadow-sm hover:shadow-md"
          >
            Upload Data
          </Link>
        </div>

        <div className="mt-16 grid grid-cols-1 md:grid-cols-3 gap-8 text-left">
          <div className="bg-white p-6 rounded-xl shadow-sm border border-gray-100">
            <h3 className="font-semibold text-gray-900 mb-2">Hybrid Search</h3>
            <p className="text-sm text-gray-500">Combines keyword and vector search for best results.</p>
          </div>
          <div className="bg-white p-6 rounded-xl shadow-sm border border-gray-100">
            <h3 className="font-semibold text-gray-900 mb-2">Analytics</h3>
            <p className="text-sm text-gray-500">Track clicks, orders, and missed searches.</p>
          </div>
          <div className="bg-white p-6 rounded-xl shadow-sm border border-gray-100">
            <h3 className="font-semibold text-gray-900 mb-2">Product Mgmt</h3>
            <p className="text-sm text-gray-500">Easily manage your catalog and images.</p>
          </div>
        </div>
      </div>
    </div>
  );
}
