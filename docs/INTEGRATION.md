# Add PolarBear Search to Your Website

This guide walks a store owner from zero to a working AI search box on their
website in about 10 minutes. **No coding skills are required** — if you can
copy and paste, you can do this.

PolarBear is an open-source hybrid search engine: it combines classic keyword
matching with AI semantic search, so a shopper who types “cozy gift” finds
your scented candles even though no product title contains those words.

---

## The 3-Step Overview

```
1. Upload your products  →  2. Copy your embed code  →  3. Paste it into your site
   (a CSV file)               (Settings page)             (your site builder's
                                                           custom-code box)
```

Everything below is detail on those three steps.

---

> **Want to try it before committing your own catalog?** The repo includes a
> ready-made demo storefront with 18 products — see [demo-store/](../demo-store/).
> Run `python3 -m http.server 4173` in that folder, upload its `products.csv`,
> and you can play both merchant and shopper in a couple of minutes.

## Step 0 — Get an account

- **Hosted**: register at your PolarBear provider's URL — you get an isolated
  workspace (your products and analytics are never shared with other stores).
- **Self-hosted**: see [Running PolarBear yourself](#running-polarbear-yourself)
  below, then register on your own instance.

Registering automatically creates two API keys for you (visible in
**Settings**):

| Key | Starts with | What it can do | Where it may appear |
|---|---|---|---|
| Public Search Key | `pb_search_` | Search your catalog. Read-only. | Safe in public web pages — this is the one inside your embed code |
| Admin Key | `pb_admin_` | Upload and edit products | Keep secret. Never put it in a web page |

---

## Step 1 — Upload your products

Go to **Upload** and select a CSV or Excel file — including a raw export from
Shopify, WooCommerce, or Square, or your own spreadsheet. PolarBear reads your
column names, guesses what each one means, and shows you a confirmation screen
before importing anything.

Only one column is truly required: **the product name**. Everything else is
optional and improves results:

| Column | Required? | Notes |
|---|---|---|
| `title` | **Required** | The product name |
| `id` | Optional | Your own SKU or product code. Leave it out and PolarBear numbers products for you |
| `description` | Recommended | Powers the AI semantic matching — richer is better |
| `price` | Recommended | Shown in search results |
| `category`, `brand`, `tags` | Recommended | Improve keyword matching |
| `image_url` | Optional | Product thumbnail in results |
| `url` | Optional | Link to the product page — **makes results clickable** |

**No product ID column?** That's fine — PolarBear numbers your products
automatically from their names. One consequence worth knowing: if you rename a
product and re-upload, it arrives as a new product rather than an update to the
old one.

**After you paste the snippet**, come back to **Settings → Check your
installation**. Enter your website address and press the button: it tells you
whether the search box actually loaded on your site, and what to check if it
didn't.

Example:

```csv
id,title,description,price,category,brand,tags,url,image_url
1,Lavender Soy Candle,Calming lavender soy wax candle for relaxing evenings,14,Candles,MyShop,"soy,lavender",https://myshop.com/p/lavender,https://myshop.com/img/lavender.jpg
```

Re-uploading with the same `id` merges: existing products are updated, new ones added. Without an `id`, each upload creates new products.

> **Tip:** include a `url` for every product. Without it, results display
> product information but shoppers can't click through to buy.

## Step 2 — Copy your embed code

Go to **Settings → Add search to your website**, pick your platform, and
click **Copy**. The code looks like this (yours has your real key):

```html
<div id="polarbear-search"></div>
<script src="https://YOUR-POLARBEAR-SERVER/widget.js" data-key="pb_search_..." async></script>
```

Two lines: the first is where the search box appears; the second loads the
widget (~6KB, no dependencies, doesn't slow your page down).

## Step 3 — Paste it into your site

Every major site builder has a “paste custom code” box. You never edit code
files.

### Shopify

1. In your Shopify admin, go to **Online Store → Themes → Customize**.
2. On the page where you want search, click **Add section → Custom Liquid**.
3. Paste the code into the Custom Liquid box and click **Save**.

### WordPress

1. In WP Admin, go to **Appearance → Widgets** (or edit the page in the
   block editor).
2. Add a **“Custom HTML”** block where you want the search box.
3. Paste the code into the block and click **Update**.

### Wix

1. In your Wix dashboard, go to **Settings → Custom Code**.
2. Click **“+ Add Custom Code”** and paste the code.
3. Choose which pages it loads on, place it in **Body**, and click **Apply**.

### Squarespace, Webflow, or any other builder

Find the “Embed”, “Code block”, or “Custom HTML” element, and paste the two
lines where the search box should appear.

### Hand-written HTML site

Paste the two lines into the page's HTML wherever the box should render.

**That's it.** Reload your site: a search box appears; typing opens a results
overlay with your products, ranked by combined keyword + AI relevance.

---

## What your shoppers get

- **Search-as-you-type**: results appear ~a quarter second after they stop
  typing.
- **Semantic understanding**: “warm jacket” finds your “Winter Jacket —
  insulated for cold weather” even without the word “warm” in the title.
- **Keyboard friendly**: ↑/↓ to select, Enter to open, Esc to close.
- **Style-safe**: the widget renders in a Shadow DOM — your site's CSS can't
  break it, and it can't leak styles into your site.

## What you get (the merchant)

The **Insights** dashboard shows, per your store only:

- Total searches and top search queries
- **Missed opportunities** — queries that returned zero results (restock or
  rename hints!)
- Product clicks coming from the widget on your site

---

## Widget configuration (optional)

The script tag accepts these attributes:

| Attribute | Default | Purpose |
|---|---|---|
| `data-key` | — (required) | Your public search key |
| `data-api` | the script's own origin | Point the widget at a different API host |
| `data-container` | `#polarbear-search` | CSS selector of the element to mount into |

Example with a custom container:

```html
<div class="my-header-search"></div>
<script src="https://YOUR-SERVER/widget.js" data-key="pb_search_..."
        data-container=".my-header-search" async></script>
```

## For developers: use the API directly

Prefer building your own UI? The search API is one GET request with your
public key:

```bash
curl "https://YOUR-SERVER/search/?q=warm%20jacket&key=pb_search_...&limit=8"
```

```json
{
  "query": "warm jacket",
  "total": 2,
  "results": [
    {"id": "1", "title": "Winter Jacket", "price": 120, "url": "https://...", "image_url": "https://..."}
  ]
}
```

Optional click tracking (feeds the Insights dashboard):

```bash
curl -X POST "https://YOUR-SERVER/analytics/track" \
  -H "X-PolarBear-Key: pb_search_..." \
  -H "Content-Type: application/json" \
  -d '{"type": "click", "product_id": "1", "title": "Winter Jacket"}'
```

## Use PolarBear in a mobile app

The embeddable widget is web-only — it renders into a web page. Native apps
call the same REST API directly, which takes a few dozen lines.

**iOS (Swift)**

```swift
struct Product: Decodable {
    let id: String
    let title: String
    let description: String?
    let url: String?
    let image_url: String?
}

struct SearchResponse: Decodable {
    let query: String
    let total: Int
    let results: [Product]
}

func search(_ query: String) async throws -> [Product] {
    var components = URLComponents(string: "https://YOUR-SERVER/search/")!
    components.queryItems = [
        URLQueryItem(name: "q", value: query),
        URLQueryItem(name: "key", value: "pb_search_..."),
        URLQueryItem(name: "limit", value: "8"),
    ]
    let (data, response) = try await URLSession.shared.data(from: components.url!)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
    return try JSONDecoder().decode(SearchResponse.self, from: data).results
}
```

**Android (Kotlin)**

```kotlin
@Serializable
data class Product(
    val id: String,
    val title: String,
    val description: String? = null,
    val url: String? = null,
    val image_url: String? = null,
)

@Serializable
data class SearchResponse(val query: String, val total: Int, val results: List<Product>)

suspend fun search(query: String): List<Product> = withContext(Dispatchers.IO) {
    val url = "https://YOUR-SERVER/search/?q=${URLEncoder.encode(query, "UTF-8")}" +
        "&key=pb_search_...&limit=8"
    var conn: HttpURLConnection? = null
    try {
        conn = (URL(url).openConnection() as HttpURLConnection)
        if (conn.responseCode != 200) return@withContext emptyList()
        val body = conn.inputStream.bufferedReader().readText()
        Json { ignoreUnknownKeys = true }.decodeFromString<SearchResponse>(body).results
    } catch (e: Exception) {
        emptyList()   // never let search break the screen
    } finally {
        conn?.disconnect()
    }
}
```

> **A note on `price`.** The API returns whatever your catalog holds: a number
> when your file had a price column, or an empty string when it didn't. Decode
> it tolerantly (or fetch it from your own catalog) rather than declaring it as
> a plain number — a strict `Double` decoder will fail on a price-less product.

**Is it safe to ship the key inside an app?**

Yes, for the **public search key** (`pb_search_`). It is read-only and scoped
to your catalog — the same threat model as putting it in a web page's source,
which is exactly what the widget does. Someone who extracts it can search your
catalog and post click events — exactly what any visitor to your website can
already do.

Never ship the **admin key** (`pb_admin_`) in an app. It can modify your
catalog. Keep uploads on your own server or in the dashboard.

**Practical notes**

- **Debounce** roughly 250ms after the last keystroke, like the widget does,
  instead of firing a request per character.
- **Use `limit`** — 8 results is plenty for a search-as-you-type list.
- **Track clicks** so your Insights dashboard reflects app traffic. This works
  from an app exactly as it does from a browser:

  ```bash
  curl -X POST "https://YOUR-SERVER/analytics/track" \
    -H "X-PolarBear-Key: pb_search_..." \
    -H "Content-Type: application/json" \
    -d '{"type": "click", "product_id": "SKU-1", "title": "Blue Mug"}'
  ```

- **First request after an idle period can be slow.** A scale-to-zero
  deployment cold-starts in a few seconds; show a spinner and set a generous
  timeout on the first call.
- **Fail quietly.** If search errors, show an empty state rather than an error
  dialog — the widget follows the same rule.

**How the self-check reports app integrations**

Settings → *Check your installation* reports two channels. App and server
requests arrive without a browser `Origin` header, so they appear under
**App / API**, not **Website**. If you only integrate through an app, leave the
website field empty and expect "Website: Not detected" — that is correct, not a
failure.

---

## Running PolarBear yourself

PolarBear is 100% open source (MIT). A self-hosted instance gives you the
exact same product — the widget is served by your own backend, so the embed
code just points at your server.

```bash
git clone https://github.com/dukesky/PolarBear.git
cd PolarBear/infrastructure
docker compose up -d
```

That's everything — search engine, database, API and dashboard. Open
<http://localhost:3000/login> and register.

**Before anyone else can reach it**, set a real secret:

```bash
SECRET_KEY=$(openssl rand -hex 32) docker compose up -d
```

Developing on PolarBear itself? Run `docker compose up -d meilisearch postgres`
for the infrastructure and start the backend (`cd backend && poetry install &&
poetry run uvicorn app.main:app --reload --port 8000`) and frontend
(`cd frontend && npm install && npm run dev`) yourself.

Key environment variables (see `backend/.env.example` for all of them):

| Variable | What it does |
|---|---|
| `SECRET_KEY` | JWT signing secret — **must** be changed in production |
| `PUBLIC_BACKEND_URL` | The public URL of your backend — baked into embed snippets |
| `DATABASE_URL` | SQLite by default; Postgres recommended in production |
| `INDEX_STORAGE` / `GCS_BUCKET` | Where vector indexes persist (`local` or `gcs`) |
| `GOOGLE_OAUTH_CLIENT_ID/SECRET` | Optional “Sign in with Google” |
| `RATE_LIMIT_PER_MINUTE` | Requests per minute per merchant on the public search endpoints; `0` disables it |

The widget artifact ships pre-built in the repo (`backend/app/widget/`), so
the backend needs no Node toolchain. To hack on the widget itself:
`cd widget && npm install && npm run build && npm test`.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| No search box appears | The `<div id="polarbear-search">` line is missing, or `data-container` doesn't match any element. Check the browser console for a `[PolarBear]` warning. |
| Box appears, no results | Wrong or reset `data-key` — copy a fresh snippet from Settings. Products uploaded? |
| Results not clickable | Add a `url` column to your CSV and re-upload. Only `http(s)` URLs are accepted (anything else is ignored for safety). |
| “No results” for queries that should match | Check **Insights → Missed Opportunities**; enrich product `description`s — the AI matches meaning, and one-word descriptions give it little to work with. |
| Widget looks unstyled/odd | Another script may be removing the container. The widget itself is Shadow-DOM isolated; verify the container div survives page load. |

## Security notes

- The `pb_search_` key in your page is **designed** to be public: it can only
  run searches and report clicks against your catalog.
- Never paste your `pb_admin_` key into a web page. If it leaks, reset it in
  Settings (the old key stops working immediately).
- The widget refuses to render non-`http(s)` product URLs, so a bad `url`
  value in a CSV cannot inject scripts into your site.
