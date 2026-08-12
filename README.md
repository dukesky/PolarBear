<div align="center">
  <img src="PolarBear_logo.png" alt="PolarBear Logo" width="200" height="200">
  <h1>PolarBear 🐻‍❄️</h1>
  <p><strong>The Open-Source Hybrid Search Engine for SMEs</strong></p>
  
  [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
  [![Python](https://img.shields.io/badge/Python-3.11+-blue.svg)](https://www.python.org/)
  [![Next.js](https://img.shields.io/badge/Next.js-14-black)](https://nextjs.org/)
  [![Docker](https://img.shields.io/badge/Docker-Enabled-blue)](https://www.docker.com/)

  <p>
    <a href="#-features">Features</a> •
    <a href="#-getting-started">Getting Started</a> •
    <a href="#-documentation">Documentation</a> •
    <a href="#-contributing">Contributing</a>
  </p>
</div>

---

## 🌟 Introduction

**PolarBear** is a powerful, no-code, AI-enhanced search engine designed specifically for Small and Medium-sized Enterprises (SMEs). It democratizes access to advanced search technology, allowing business owners to create a professional search experience for their products, services, or inventory in minutes—completely free and open source.

Unlike complex enterprise solutions, PolarBear focuses on simplicity without compromising on power. It combines **Keyword Search** (Meilisearch) and **Semantic Vector Search** (FAISS) to deliver results that are both accurate and contextually relevant.

PolarBear is **open-core**: this repository is the complete product under the MIT license — clone it, self-host it, study it, extend it. The same codebase can also run as a hosted multi-tenant service where store owners simply register, upload their catalog, and paste two lines of code into their website.

## 🛍️ Add Search to Your Store — in 3 Steps

> **Store owner with no technical background?** This is for you.

1. **Upload your products** — a CSV with your product names, descriptions, and prices.
2. **Copy your embed code** — the Settings page generates it, with platform-specific guides for Shopify, WordPress, and Wix.
3. **Paste it into your site** — into your site builder's "custom code" box. Done.

```html
<div id="polarbear-search"></div>
<script src="https://your-polarbear-server/widget.js" data-key="pb_search_..." async></script>
```

Your shoppers get a search-as-you-type overlay with AI semantic matching ("cozy gift" finds your scented candles); you get a dashboard of what they searched and clicked.

📖 **[Full integration guide → docs/INTEGRATION.md](docs/INTEGRATION.md)** — step-by-step per platform, CSV format, widget options, API reference, self-hosting, and troubleshooting.

## 🚀 Features

- **🔍 Hybrid Search**: seamlessly blends keyword matching (BM25) with AI-powered semantic search (Embeddings) for superior result relevance.
- **⚡ No-Code Ingestion**: Upload your data via CSV, Excel, or Google Sheets. No coding required.
- **🧠 AI-Ready**: Built-in vectorization pipeline using state-of-the-art embedding models.
- **📊 Insights Dashboard**: Track user behavior, top queries, zero-result searches, and conversion metrics.
- **🛍️ Product Management**: Built-in catalog management to edit products and upload images directly.
- **🔐 Multi-Tenant**: Register an account, get isolated indexes and API keys — one deployment serves many businesses.
- **🧩 Embeddable Widget**: paste two lines into any website (Shopify, WordPress, Wix, custom) and get an AI search box for your catalog.
- **☁️ Cloud-Native**: Dockerized for easy deployment on Google Cloud Run, AWS, or your own server.
- **🔓 Open Source**: 100% free to use, modify, and distribute.

## 🛠️ Tech Stack

| Component | Technology | Description |
|-----------|------------|-------------|
| **Frontend** | Next.js (React) | Modern, responsive admin and search UI. |
| **Backend** | FastAPI (Python) | High-performance API for ingestion and search. |
| **Search** | Meilisearch | Lightning-fast keyword search engine. |
| **Vector DB** | FAISS | Efficient similarity search for embeddings. |
| **Infrastructure** | Docker | Containerized for consistent deployment. |

## 🚀 Getting Started

### Prerequisites
- **Node.js** 18+
- **Python** 3.11+
- **Docker** & **Docker Compose**

### Quick Start

1.  **Clone the Repository**
    ```bash
    git clone https://github.com/dukesky/PolarBear.git
    cd PolarBear
    ```

2.  **Start Infrastructure**
    ```bash
    cd infrastructure
    docker-compose up -d
    ```

3.  **Start Backend**
    ```bash
    cd backend
    poetry install
    poetry run uvicorn app.main:app --reload --port 8000
    ```

4.  **Start Frontend**
    ```bash
    cd frontend
    npm install
    npm run dev
    ```

5.  **Experience PolarBear**
    - **Register**: Go to `http://localhost:3000/login` and create an account.
    - **Upload Data**: Go to `http://localhost:3000/upload` and upload a CSV (e.g., `sample_products.csv`).
    - **Search**: Visit `http://localhost:3000/search` to try the hybrid search.
    - **API Keys**: Visit `http://localhost:3000/settings` to copy your public search key.
    - **Embed**: In Settings → "Add search to your website", copy the snippet into any web page — the widget talks to your backend.
    - **Insights**: Check `http://localhost:3000/insights` for analytics and product management.

> **Upgrading from a pre-multi-tenant version?** Indexes are now per-account. After
> upgrading, register an account and re-upload your CSV — old data in the shared
> `products` index is not migrated automatically.

## 📚 Documentation

**For store owners & integrators:**

- [**Integration Guide**](docs/INTEGRATION.md) — add PolarBear search to any website (Shopify, WordPress, Wix, custom) in 3 steps; CSV format, widget options, search API, self-hosting, troubleshooting.

**Development history** — detailed walkthroughs for each phase:

- [**Phase 1: Setup & MVP Core**](docs/phase1/walkthrough_phase1.md) - Infrastructure and basic search.
- [**Phase 2: Ingestion & Indexing**](docs/phase2/walkthrough_phase2.md) - CSV parsing and hybrid indexing pipeline.
- [**Phase 3: Search Interface**](docs/phase3/walkthrough_phase3.md) - Frontend UI and search logic.
- [**Phase 4: Analytics**](docs/phase4/walkthrough_phase4.md) - Tracking user queries and dashboard.
- [**Phase 5: UX & Product Mgmt**](docs/phase5/walkthrough_phase5_extended.md) - Image support, catalog editing, and advanced UX.

## 🤝 Contributing

We welcome contributions from the community! Whether it's fixing bugs, improving documentation, or suggesting new features, your help is appreciated.

1.  Fork the Project
2.  Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3.  Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4.  Push to the Branch (`git push origin feature/AmazingFeature`)
5.  Open a Pull Request

## 📄 License

Distributed under the MIT License. See `LICENSE` for more information.

## 📬 Contact

Project Link: [https://github.com/dukesky/PolarBear](https://github.com/dukesky/PolarBear)

---
<div align="center">
  Made with ❤️ for the Open Source Community
</div>
