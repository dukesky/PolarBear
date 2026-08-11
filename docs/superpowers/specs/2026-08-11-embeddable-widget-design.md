# PolarBear Embeddable Search Widget — Design Spec

**Date**: 2026-08-11
**Sub-project**: C1 — Embeddable JS widget + no-code onboarding
**Status**: Approved by user (brainstorming session 2026-08-11)
**Depends on**: Multi-tenant foundation (merged, `e64dfef`) — public search keys, tenant-scoped `/search`

## Context & Motivation

The multi-tenant foundation gives every merchant a public, read-only search key
(`pb_search_...`) that is safe to appear in page source. C1 turns that into the
product's core promise: a merchant with no technical background gets AI-powered
hybrid search on their existing website by pasting two lines into their site
builder's custom-code box. This is the user's stated top priority — integration
ease over search-quality work (sub-project A, deferred).

**Roadmap**: C1 (this spec) → C2 (Shopify App: true one-click install +
automatic product sync, reusing this widget) → C3 candidate (WordPress plugin)
→ A (search quality). True zero-paste install is impossible on arbitrary
websites (nobody can inject scripts into a site they don't control); C1 gets
as close as a generic solution can, C2 closes the gap for Shopify.

## Goals

- A self-contained `widget.js` any website can load with two pasted lines —
  no build tools, no npm, no code files (site builders' custom-code UIs count
  as "no code" for our purposes).
- Search-as-you-type overlay with product results, keyboard navigation, and
  click-through to product pages.
- Style isolation both ways: merchant CSS cannot break the widget; the widget
  cannot leak styles into the page.
- Click tracking from merchant sites flows into the existing Insights
  dashboard (per tenant).
- Settings page becomes a platform-aware onboarding guide: pick your platform
  (Shopify / WordPress / Wix / Other), get illustrated 3-step instructions and
  a copy-ready snippet with your key pre-filled.
- Acceptance bar: on a fake third-party merchant page, register → upload CSV →
  paste snippet → working search in ≤ 10 minutes with zero code written.

## Non-Goals (YAGNI — explicitly deferred)

- Shopify App / WordPress plugin (C2/C3 — separate specs)
- npm/CDN publishing (backend serves the file; a CDN is just a future URL swap)
- Theming/customization beyond the built-in neutral style (no `data-color` yet)
- Autocomplete/suggestions, facets/filters, multi-language
- Search-quality changes (sub-project A)

## 1. Widget Architecture & Packaging

**Tech**: vanilla TypeScript, bundled by esbuild into ONE IIFE file
(`polarbear-widget.js`, target ≤ ~15KB minified). No runtime dependencies, no
framework. New top-level `widget/` directory:

```
widget/
  src/
    index.ts        # bootstrap: read script attrs, find container, mount
    search-box.ts   # inline input rendered into the merchant's container
    overlay.ts      # modal overlay: input mirror, results list, empty states
    api.ts          # debounced fetch to /search/, click tracking to /analytics/track
    styles.ts       # CSS string injected into the Shadow DOM
  test/
    merchant-page.html  # fake third-party page with hostile CSS for manual/e2e testing
  package.json      # esbuild + typescript only (devDependencies)
  build.mjs         # esbuild script → ../backend/app/widget/polarbear-widget.js
```

The build output goes to `backend/app/widget/polarbear-widget.js` and IS
committed to git (a single generated artifact; committing it keeps
self-hosted backend deploys free of any Node build step — `git pull &&
docker build` suffices). A test rebuilds from source and verifies the
committed artifact is current.

**Merchant snippet** (generated on the Settings page):

```html
<div id="polarbear-search"></div>
<script src="{PUBLIC_BACKEND_URL}/widget.js" data-key="pb_search_..." async></script>
```

- The script derives its API base from its own `src` origin; `data-api`
  attribute overrides it (edge deployments).
- `data-container` attribute overrides the default `#polarbear-search`
  container selector.
- If the container is missing, the widget logs one `console.warn` and does
  nothing — it must never break a merchant page.
- All UI renders inside a Shadow DOM (`mode: "open"`) attached to the
  container: two-way style isolation.

## 2. Widget Behavior

- The container gets a search input styled in PolarBear's neutral look
  (white, gray border, indigo accent) sized to its container width.
- Focusing the input opens a centered overlay (dimmed backdrop) with a large
  input (auto-focused, text carried over) and the results list.
- **Search-as-you-type**: 250ms debounce after the last keystroke; in-flight
  responses that arrive out of order are discarded (request sequence counter).
  Queries under 2 characters clear results instead of searching.
- Request: `GET {api}/search/?q={q}&key={key}&limit=8`.
- Result card: image thumbnail (if `image_url`), title, price (if present),
  first ~80 chars of description. Results with a `url` field are links
  (`target="_top"`); clicking fires click tracking first (`keepalive` fetch),
  then navigates. Results without `url` render as non-link cards.
- **Optional `url` CSV column**: the existing parser already passes extra
  columns through untouched — zero backend change; the Upload page
  instructions gain `url` (and clarify `image_url`) as optional columns.
- Keyboard: ↑/↓ move selection, Enter opens the selected result's url (if
  any), Esc closes the overlay. Clicking the backdrop closes it.
- Empty state: "No results for “{q}”". Network/API failure renders the same
  empty state silently (one `console.warn`) — never an error dialog on a
  merchant's page.
- A small "Search by PolarBear 🐻‍❄️" footer line in the overlay (open-source
  attribution, links to the repo).

## 3. Backend Changes (two, both small)

1. **Serve the widget**: `GET /widget.js` returns
   `backend/app/widget/polarbear-widget.js` with
   `Cache-Control: public, max-age=3600` and correct content type. (Mounted
   as an explicit route, not under `/static`, so the snippet URL is stable
   and independent of the data dir.)
2. **Click tracking with a search key**: `/analytics/track` currently
   requires a JWT (`get_current_tenant`). Change its dependency to accept
   **either** a valid `pb_search_` key (header `X-PolarBear-Key` or `?key=`)
   **or** a JWT — mirroring `/search`'s dual auth. Track is write-only,
   tenant-scoped, and low-risk; this lets merchant-site clicks appear in the
   Insights dashboard. (Admin keys also work, consistent with
   `resolve_search_tenant`'s superset semantics.)

CORS is already `allow_origins=["*"]` — merchant sites can call both routes.

## 4. Onboarding: Settings Page "Add to your website"

Below the API-keys cards, a new section:

- **Platform picker**: four tabs/buttons — Shopify, WordPress, Wix, Other.
  Selection is purely client-side state (no backend).
- Each platform shows a numbered 3-step guide in plain language with the
  exact click path in that platform's UI:
  - *Shopify*: Online Store → Themes → Edit code is NOT required — use
    Online Store → Themes → Customize → (page) → Add section → Custom Liquid,
    paste the snippet. (Wording keeps the merchant inside the theme editor.)
  - *WordPress*: Appearance → Widgets (or the page editor) → add a "Custom
    HTML" block → paste the snippet.
  - *Wix*: Settings → Custom Code → "+ Add Custom Code" → paste, set to load
    on all pages (or chosen pages) in the Body.
  - *Other*: paste the two lines into your page's HTML where the search box
    should appear.
- The snippet block shows the merchant's real search key and the deployment's
  real `PUBLIC_BACKEND_URL`, with a copy button (reuses the Settings page's
  existing copy pattern). The backend URL comes from a new lightweight
  endpoint `GET /tenant/snippet` returning `{snippet: "..."}` (server knows
  `PUBLIC_BACKEND_URL`; the frontend must not guess it from `NEXT_PUBLIC_API_URL`
  alone — hosted deployments may differ).
- A short "3 steps" framing at the top: 1) Upload your products, 2) Copy the
  code, 3) Paste it into your site — with links to /upload and the guide.
- Upload page: add optional `url` column to the instructions list.

UI style: existing PolarBear look (white/gray/indigo-600, Tailwind only, no
new UI libraries), consistent with the current Settings cards.

## 5. Error Handling & Testing

**Backend (pytest)**:
- `/analytics/track` with a valid search key → 200 and the event lands in the
  tenant's `ProductStat`; with an invalid key → 401; with no credentials →
  401; JWT keeps working (regression).
- `/widget.js` returns 200, JS content type, cache header (test tolerates the
  committed artifact's presence).
- `/tenant/snippet` requires JWT and embeds both the search key and
  `PUBLIC_BACKEND_URL`.

**Widget**:
- Build check: `node build.mjs` produces the artifact; CI-style test asserts
  the committed artifact is current (rebuild + diff, or size/hash guard).
- `widget/test/merchant-page.html`: a deliberately hostile fake merchant page
  (aggressive global CSS: `* { all: unset }`-adjacent rules, high z-indexes)
  loading the widget from a local backend. Used for the end-to-end browser
  test: type → results appear → style intact both ways → click tracked in
  Insights → Esc/backdrop close.
- Out-of-order response discard covered by a unit-ish test if cheap, else
  verified in the e2e pass.

**Acceptance test (manual, end of project)**: fresh account on the fake
merchant page — register → upload `sample_products.csv` (with url column
added to a sample) → copy snippet from Settings → paste into merchant-page →
search works, clicks appear in Insights. Target ≤ 10 minutes, zero code.

## Rollout Note

`widget.js` is served by the same backend as the API, so open-source users
get the widget automatically on upgrade. The committed artifact means
`git pull && docker build` is enough — no Node toolchain needed server-side.
