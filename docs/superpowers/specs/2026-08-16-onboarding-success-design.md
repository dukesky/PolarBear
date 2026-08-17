# PolarBear Onboarding Success Pack — Design Spec

**Date**: 2026-08-16
**Sub-project**: C1.5 — CSV column mapping, installation self-check, send-to-developer
**Status**: Approved by user (brainstorming session 2026-08-16)
**Depends on**: Multi-tenant foundation (`e64dfef`), embeddable widget (`64d9629`), hosted deployment (2026-08-12)

## Context & Motivation

The hosted service works end to end, but two barriers stop a real non-technical
merchant from succeeding, both found by testing the live product:

1. **The CSV wall.** `DataParser` hard-requires lowercase `id` and `title`
   columns. A real Shopify product export (columns `Handle`, `Title`,
   `Body (HTML)`, `Variant Price`, `Image Src`) was uploaded to production and
   failed outright:
   `{"detail":"Missing required columns: {'id', 'title'}"}`. WooCommerce,
   Square, and hand-made spreadsheets all fail the same way. A merchant must
   open Excel and rename columns before anything works.

2. **No feedback after pasting the snippet.** The merchant pastes two lines
   into Shopify/WordPress/Wix and has no way to learn whether it worked. Unlike
   Google Analytics or Meta Pixel — which are invisible and only need to *run* —
   PolarBear's widget *renders in a specific place*, so "did it work?" has two
   parts: did the script load, and did it land where intended.

A third, smaller gap: merchants whose site was built by an agency have no admin
access and need to hand the job to someone else.

This spec closes all three. It does not attempt to remove the paste step
entirely — that is sub-project C2 (Shopify App).

## Goals

- Any reasonable product export or spreadsheet uploads successfully, with the
  merchant only confirming a pre-guessed column mapping.
- A real Shopify export uploads with zero manual edits (acceptance gate).
- A spreadsheet with no ID column uploads successfully.
- After pasting the snippet, a merchant can press one button and learn whether
  the widget is live, on which domain, and what to check if it isn't.
- A merchant who cannot edit their own site can hand off the job in one click.

## Non-Goals (YAGNI — explicitly deferred)

- Platform plan-tier warnings (Wix Premium / Squarespace Business) — user
  deferred these
- Locking a search key to the merchant's domain — the `website_url` field this
  spec adds makes it possible later; not built now
- Saved mapping templates/library, multi-file upload, scheduled re-imports
- Shopify App / automatic product sync (C2)
- Search-quality work (sub-project A)

## 1. CSV Column Mapping

Upload becomes two steps instead of one failure.

```
pick file → POST /ingest/preview → mapping screen (pre-guessed) → confirm → POST /ingest/upload → indexed
```

### `POST /ingest/preview` (new, admin auth)

Parses the file **without indexing** and returns:

```json
{
  "columns": ["Handle", "Title", "Body (HTML)", "Variant Price", "Image Src"],
  "sample_rows": [ {...}, {...}, {...} ],
  "row_count": 42,
  "guess": {"id": "Handle", "title": "Title", "description": "Body (HTML)",
            "price": "Variant Price", "image_url": "Image Src",
            "category": null, "brand": null, "tags": null, "url": null}
}
```

The file is **not** persisted server-side; the frontend re-sends it on confirm.
A 200-product CSV is tens of kilobytes, which is cheaper and simpler than
server-side temp storage with cleanup.

### Guessing

Header names are normalized (lowercase, strip spaces/underscores/punctuation)
and matched against alias lists per target field:

| Target | Aliases (normalized) |
|---|---|
| `id` | id, sku, variantsku, productid, itemid, itemnumber, code, handle, 货号, 编号 |
| `title` | title, name, productname, producttitle, product, item, itemname, 名称, 商品名, 商品名称 |
| `description` | description, desc, details, body, bodyhtml, longdescription, 描述, 详情 |
| `price` | price, variantprice, unitprice, cost, amount, 价格, 售价 |
| `category` | category, producttype, type, productcategory, collection, 分类, 类别 |
| `brand` | brand, vendor, manufacturer, supplier, 品牌 |
| `tags` | tags, keywords, labels, 标签 |
| `image_url` | imageurl, imagesrc, image, photo, picture, thumbnail, 图片 |
| `url` | url, link, producturl, productlink, permalink, 链接 |

First matching column wins; a column already claimed by an earlier field is not
reused. Unmatched targets come back `null` for the merchant to set.

### `POST /ingest/upload` (modified, admin auth)

Accepts the file plus an optional `mapping` form field (JSON string
`{target: source_column}`). Behavior:

- **With mapping**: build documents from the mapped columns only. Unmapped
  source columns are dropped (a Shopify export carries 30+ irrelevant columns).
- **Without mapping**: fall back to today's behavior (expects `id`/`title`
  directly), so the existing API contract and tests keep working.
- **Missing `id` mapping**: generate a stable id per row from the mapped title —
  slugified, lowercased, non-alphanumerics collapsed to `-`, truncated to 64
  chars, with `-2`, `-3` … suffixes for duplicates within one file. The UI
  states plainly: renaming a product later creates a new entry rather than
  updating the old one.
- **Missing `title` mapping**: 400 with a clear message. Title is the only
  irreducible requirement.
- **HTML descriptions**: strip tags from the description field (Shopify's
  `Body (HTML)` is raw HTML; indexing it leaks `<p>` into search results).
  Entities are unescaped, whitespace collapsed.
- **Price**: coerced to a number when possible (strip currency symbols and
  thousands separators); left as-is if it cannot be parsed.

### Mapping memory

The confirmed mapping is stored on the tenant (`Tenant.column_mapping`, JSON).
`/ingest/preview` returns it as the guess when the uploaded file's columns are
compatible, so a repeat upload of the same export is one click.

## 2. Installation Self-Check

### Tenant website URL

New nullable `Tenant.website_url`, editable in Settings. Stored normalized to a
bare host (`https://MyStore.com/shop` → `mystore.com`) so comparisons are
robust.

### Detection

The widget fires one fire-and-forget ping when it mounts:

```
POST /analytics/install-ping   (auth: public search key, same as /search)
```

The mount ping is essential: right after pasting, no shopper has searched yet,
so search logs alone would report a false "not installed".

The backend records the request `Origin` (falling back to `Referer`'s host,
then `"unknown"`) into a compact table:

```
WidgetPing(tenant_id, origin, kind, first_seen, last_seen, count)
  unique (tenant_id, origin, kind)
  kind: "load" | "search"
```

Upsert on each event, so the table grows with distinct domains — not with
traffic. `/search` records a `"search"` ping through the same helper.

### `GET /tenant/install-status` (new, JWT)

Returns `{website_url, pings: [{origin, kind, last_seen, count}], verdict}`
where `verdict` is one of:

| Verdict | Condition | What Settings shows |
|---|---|---|
| `ok` | a `load` ping whose origin matches `website_url` | ✅ Working — loaded on mystore.com (last seen 2 minutes ago), answered 5 searches |
| `wrong_domain` | `load` pings exist, none match `website_url` | ⚠️ Found the widget on othersite.com, but not on mystore.com |
| `not_found` | no pings at all | ❌ No sign of the widget yet + checklist |
| `no_website` | `website_url` unset | Prompt to fill it in first |

The `not_found` checklist: did you save/publish the page; is the code on a
published page rather than a draft; did you include the `<div>` line as well as
the `<script>` line; is the page the one you filled in above.

### Where it lives

- **Settings**, directly beneath the embed snippet — the merchant is standing
  there when they copy it, and comes back there to check.
- **Home page**, a one-line status summary (`Search live · mystore.com` /
  `Not installed yet`) so every login confirms it still works.

## 3. Send to Developer

A link beside the embed snippet in Settings opens a prefilled `mailto:`
(pure frontend, no backend): empty recipient, subject "Please add our product
search box to the website", body containing the full snippet, where to place
it, and a link to the integration guide. The merchant fills in their
developer's address and sends.

## 4. Error Handling & Testing

**Backend errors**

- `/ingest/preview`: non-CSV/Excel → 400; empty file → 400; duplicate header
  names → 400 naming the duplicate
- `/ingest/upload` with mapping: mapping references a column not in the file →
  400 naming it; `title` unmapped → 400
- `/analytics/install-ping`: invalid key → 401; missing Origin → recorded as
  `"unknown"`, never an error (statistics must not break a merchant's page)

**Backend tests (pytest)**

- **Acceptance gate**: a real-format Shopify export (`Handle`, `Title`,
  `Body (HTML)`, `Variant Price`, `Image Src`) → preview guesses all five
  fields → upload succeeds → indexed titles are correct and descriptions
  contain no HTML tags
- A spreadsheet with only `Product Name` and `Price` (no id) uploads; ids are
  generated and stable across two identical uploads; duplicate titles get
  distinct ids
- Unmapped columns are dropped
- Legacy path: an `id`/`title` CSV with no mapping still works (regression)
- Ping upsert: two pings from one origin produce one row with `count == 2`;
  different origins produce separate rows; search records a `search` ping
- `/tenant/install-status` returns each of the four verdicts under the right
  conditions
- Website URL normalization (`https://MyStore.com/shop` → `mystore.com`)

**Widget tests (node)**

- The mount ping fires once per mount and never throws when the endpoint fails

**Frontend**

- Upload page: preview → mapping screen → confirm flow; build passes
- Settings: install-check three states render; website URL saves
- Manual browser pass on the demo storefront: paste snippet → press check →
  `ok`; then change the website URL to a wrong domain → `wrong_domain`

## Acceptance Criteria

1. The exact Shopify export CSV that fails today uploads successfully with no
   manual editing, only a confirm click.
2. A merchant who pasted the snippet gets a definitive ✅/⚠️/❌ answer within
   seconds of pressing the check button, before any shopper has searched.
3. A merchant who cannot edit their site can produce a complete developer
   handoff email in one click.
