# Embeddable Search Widget (C1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A self-contained `widget.js` that any merchant website can load with a two-line pasted snippet, giving shoppers a search-as-you-type overlay backed by the merchant's tenant-scoped PolarBear index — plus a platform-aware onboarding guide on the Settings page.

**Architecture:** New top-level `widget/` directory (vanilla TypeScript, esbuild, zero runtime deps) builds ONE IIFE file committed at `backend/app/widget/polarbear-widget.js` and served by FastAPI at `GET /widget.js`. The widget mounts into a merchant-provided container, renders all UI in a Shadow DOM, and talks to the existing `/search/` route with the public search key. Two small backend changes: `/analytics/track` gains search-key auth (mirroring `/search`), and `GET /tenant/snippet` generates the merchant's copy-ready snippet server-side.

**Tech Stack:** TypeScript + esbuild (widget only; Node ≥18 for building), FastAPI (existing), Next.js 16 + Tailwind 4 (existing), pytest + node:test.

**Spec:** `docs/superpowers/specs/2026-08-11-embeddable-widget-design.md`

## Global Constraints

- Widget: vanilla TypeScript, esbuild, **zero runtime dependencies, no framework**; single minified IIFE output ≤ ~15KB at `backend/app/widget/polarbear-widget.js`, **committed to git** (self-hosted deploys must not need Node).
- Merchant snippet shape exactly:
  `<div id="polarbear-search"></div>` + `<script src="{PUBLIC_BACKEND_URL}/widget.js" data-key="pb_search_..." async></script>`.
- Script attributes: `data-key` (required), `data-api` (optional API base override; default = script `src` origin), `data-container` (optional selector; default `#polarbear-search`).
- The widget must NEVER break or visibly error on a merchant page: missing container / failed requests → one `console.warn` max, silent empty state.
- All widget UI inside a Shadow DOM (`mode: "open"`); neutral style (white bg, `#d1d5db` gray borders, `#4f46e5` indigo accent).
- Search-as-you-type: 250ms debounce; queries < 2 chars clear results without a request; out-of-order responses discarded via a request sequence counter; result limit 8.
- Frontend (Next.js) changes: Tailwind utilities only, **no new npm packages**; match existing Settings-page card style.
- Backend tests: `cd backend && poetry run pytest` (asyncio_mode=auto; existing `client`/`registered` conftest fixtures). Widget tests: `cd widget && npm test`.
- Route paths with router prefixes need trailing slashes where the route is `@router.get("/")` (e.g. `/search/`); `/analytics/track`, `/tenant/snippet`, `/widget.js` are exact paths.

---

### Task 1: `/analytics/track` accepts the public search key

**Files:**
- Modify: `backend/app/api/routes/analytics.py` (the `/track` route only)
- Test: `backend/tests/test_track_auth.py`

**Interfaces:**
- Consumes: `app.core.tenancy.resolve_search_tenant` (existing FastAPI dependency: `X-PolarBear-Key` header or `?key=` or JWT → `uuid.UUID` tenant id; 401 otherwise), `app.services.analytics_db.track_product_event(tenant_id, event_type, product_id, title)`.
- Produces: `POST /analytics/track` authenticated by search key, admin key, or JWT. `/analytics/stats` unchanged (JWT only).

- [ ] **Step 1: Write the failing test**

`backend/tests/test_track_auth.py`:

```python
async def test_track_with_search_key(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    keys = (await client.get("/tenant/keys", headers=auth)).json()

    r = await client.post(
        "/analytics/track",
        json={"type": "click", "product_id": "p1", "title": "Widget Product"},
        headers={"X-PolarBear-Key": keys["search"]["key"]},
    )
    assert r.status_code == 200, r.text

    stats = (await client.get("/analytics/stats", headers=auth)).json()
    assert stats["product_stats"][0]["product_id"] == "p1"
    assert stats["product_stats"][0]["clicks"] == 1


async def test_track_rejects_missing_and_bad_key(client):
    body = {"type": "click", "product_id": "p1", "title": "X"}
    assert (await client.post("/analytics/track", json=body)).status_code == 401
    r = await client.post(
        "/analytics/track", json=body, headers={"X-PolarBear-Key": "pb_search_bogus"}
    )
    assert r.status_code == 401


async def test_track_still_works_with_jwt(registered):
    client, token, _ = registered
    r = await client.post(
        "/analytics/track",
        json={"type": "order", "product_id": "p2", "title": "Y"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_track_auth.py -v`
Expected: `test_track_with_search_key` FAILS with 401 (route currently requires JWT). The other two may already pass — that's fine.

- [ ] **Step 3: Rewire the route**

In `backend/app/api/routes/analytics.py`, change ONLY the `/track` route (leave `/stats` on `get_current_tenant`):

```python
import uuid

from app.core.tenancy import get_current_tenant, resolve_search_tenant


@router.post("/track")
async def track_event(
    event: TrackEvent, tenant_id: uuid.UUID = Depends(resolve_search_tenant)
):
    """Track a click/order. Auth: public search key, admin key, or JWT —
    callable from merchant sites (write-only, tenant-scoped)."""
    if event.type not in ("click", "order"):
        raise HTTPException(status_code=400, detail="Invalid event type")
    await track_product_event(tenant_id, event.type, event.product_id, event.title)
    return {"status": "success"}
```

(`track_product_event` already takes a bare tenant id — the previous code passed `tenant.id`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_track_auth.py tests/test_admin_routes.py -v`
Expected: all PASS (test_admin_routes exercises the JWT path — regression guard).

- [ ] **Step 5: Commit**

```bash
git add backend/app/api/routes/analytics.py backend/tests/test_track_auth.py
git commit -m "feat: allow click tracking with public search key for merchant sites"
```

---

### Task 2: `GET /tenant/snippet` — server-generated embed snippet

**Files:**
- Modify: `backend/app/api/routes/tenant.py`
- Test: `backend/tests/test_snippet.py`

**Interfaces:**
- Consumes: `get_current_tenant`, `get_async_session`, `APIKey` model (kind `"search"`, `plaintext` stored), `settings.PUBLIC_BACKEND_URL`.
- Produces: `GET /tenant/snippet` (JWT) → `{"snippet": "<div id=\"polarbear-search\"></div>\n<script src=\"{PUBLIC_BACKEND_URL}/widget.js\" data-key=\"pb_search_...\" async></script>"}`. Task 7's Settings section consumes this verbatim.

- [ ] **Step 1: Write the failing test**

`backend/tests/test_snippet.py`:

```python
async def test_snippet_requires_auth(client):
    assert (await client.get("/tenant/snippet")).status_code == 401


async def test_snippet_contains_key_and_backend_url(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    keys = (await client.get("/tenant/keys", headers=auth)).json()

    r = await client.get("/tenant/snippet", headers=auth)
    assert r.status_code == 200
    snippet = r.json()["snippet"]
    assert '<div id="polarbear-search"></div>' in snippet
    assert keys["search"]["key"] in snippet
    assert "/widget.js" in snippet
    assert "async" in snippet
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_snippet.py -v`
Expected: FAIL — 404 (route missing; note fastapi-users returns 401 only for mounted-but-unauthed routes, so the first test fails with 404 too at this point).

- [ ] **Step 3: Implement the route**

Append to `backend/app/api/routes/tenant.py`:

```python
from app.core.config import settings


@router.get("/snippet")
async def get_snippet(
    tenant: Tenant = Depends(get_current_tenant),
    session: AsyncSession = Depends(get_async_session),
):
    """Copy-ready embed snippet with the tenant's public search key."""
    key = (
        await session.execute(
            select(APIKey).where(APIKey.tenant_id == tenant.id, APIKey.kind == "search")
        )
    ).scalar_one_or_none()
    if key is None or key.plaintext is None:
        raise HTTPException(status_code=404, detail="Search key missing — reset it first")
    snippet = (
        '<div id="polarbear-search"></div>\n'
        f'<script src="{settings.PUBLIC_BACKEND_URL}/widget.js" '
        f'data-key="{key.plaintext}" async></script>'
    )
    return {"snippet": snippet}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_snippet.py -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/app/api/routes/tenant.py backend/tests/test_snippet.py
git commit -m "feat: /tenant/snippet endpoint generating the embed code server-side"
```

---

### Task 3: Widget scaffold — build pipeline + bootstrap + inline search box

**Files:**
- Create: `widget/package.json`, `widget/tsconfig.json`, `widget/build.mjs`, `widget/.gitignore`, `widget/src/index.ts`, `widget/src/styles.ts`, `widget/src/search-box.ts`
- Create (generated, committed): `backend/app/widget/polarbear-widget.js`

**Interfaces:**
- Produces: `mountSearchBox(shadow: ShadowRoot, cfg: WidgetConfig)` and `interface WidgetConfig { api: string; key: string }` in `search-box.ts` (Task 4 rewires its focus handler); `css` string in `styles.ts`; bootstrap in `index.ts` reading `data-key`/`data-api`/`data-container`. Build command `npm run build` → `backend/app/widget/polarbear-widget.js`.

- [ ] **Step 1: Create the package scaffolding**

`widget/package.json`:

```json
{
  "name": "polarbear-widget",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "node build.mjs",
    "check": "node build.mjs && git diff --exit-code ../backend/app/widget/polarbear-widget.js",
    "test": "node build-test.mjs && node --test test/"
  },
  "devDependencies": {
    "esbuild": "^0.24.0",
    "typescript": "^5.6.0"
  }
}
```

`widget/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2019",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "noEmit": true,
    "lib": ["ES2019", "DOM"]
  },
  "include": ["src"]
}
```

`widget/build.mjs`:

```javascript
import { build } from 'esbuild';
import { mkdirSync } from 'node:fs';

mkdirSync('../backend/app/widget', { recursive: true });
await build({
  entryPoints: ['src/index.ts'],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['es2019'],
  outfile: '../backend/app/widget/polarbear-widget.js',
  logLevel: 'info',
});
```

`widget/.gitignore`:

```
node_modules/
test/.api.build.mjs
```

- [ ] **Step 2: Write the styles**

`widget/src/styles.ts`:

```typescript
export const css = `
:host { all: initial; display: block; }
* { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif; }
.pb-input { width: 100%; padding: 10px 14px; font-size: 15px; color: #111827; background: #fff; border: 1px solid #d1d5db; border-radius: 8px; outline: none; }
.pb-input:focus { border-color: #4f46e5; box-shadow: 0 0 0 2px rgba(79,70,229,.15); }
.pb-backdrop { position: fixed; inset: 0; background: rgba(17,24,39,.45); z-index: 2147483000; display: flex; align-items: flex-start; justify-content: center; padding: 8vh 16px 16px; }
.pb-panel { width: 100%; max-width: 640px; background: #fff; border-radius: 12px; box-shadow: 0 20px 50px rgba(0,0,0,.25); display: flex; flex-direction: column; max-height: 80vh; overflow: hidden; }
.pb-panel-input { padding: 14px 16px; font-size: 16px; border: none; border-bottom: 1px solid #e5e7eb; outline: none; color: #111827; }
.pb-results { overflow-y: auto; }
.pb-card { display: flex; align-items: center; gap: 12px; padding: 12px 16px; border-bottom: 1px solid #f3f4f6; color: inherit; text-decoration: none; }
a.pb-card { cursor: pointer; }
.pb-card.pb-selected, .pb-card:hover { background: #eef2ff; }
.pb-thumb { width: 48px; height: 48px; border-radius: 6px; object-fit: cover; background: #f3f4f6; flex: none; }
.pb-text { min-width: 0; }
.pb-title { font-size: 14px; font-weight: 600; color: #111827; }
.pb-desc { font-size: 12px; color: #6b7280; margin-top: 2px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.pb-price { margin-left: auto; font-size: 14px; font-weight: 600; color: #4f46e5; white-space: nowrap; }
.pb-empty { padding: 24px 16px; text-align: center; font-size: 14px; color: #6b7280; }
.pb-footer { padding: 8px 16px; font-size: 11px; color: #9ca3af; text-align: right; border-top: 1px solid #f3f4f6; }
.pb-footer a { color: #6b7280; text-decoration: none; }
`;
```

- [ ] **Step 3: Write the inline search box (scaffold version)**

`widget/src/search-box.ts`:

```typescript
export interface WidgetConfig {
  api: string;
  key: string;
}

export function mountSearchBox(shadow: ShadowRoot, cfg: WidgetConfig): void {
  const input = document.createElement('input');
  input.className = 'pb-input';
  input.type = 'search';
  input.placeholder = 'Search products…';
  shadow.appendChild(input);
}
```

(Task 4 adds the focus → overlay wiring; `cfg` is unused until then.)

- [ ] **Step 4: Write the bootstrap**

`widget/src/index.ts`:

```typescript
import { css } from './styles';
import { mountSearchBox } from './search-box';

(() => {
  const script = document.currentScript as HTMLScriptElement | null;
  if (!script) return;

  const key = script.dataset.key || '';
  if (!key) {
    console.warn('[PolarBear] missing data-key attribute on the widget script tag');
    return;
  }
  const api = script.dataset.api || new URL(script.src).origin;
  const selector = script.dataset.container || '#polarbear-search';

  const mount = () => {
    const container = document.querySelector(selector);
    if (!container) {
      console.warn(`[PolarBear] container "${selector}" not found — widget not mounted`);
      return;
    }
    const shadow = container.attachShadow({ mode: 'open' });
    const style = document.createElement('style');
    style.textContent = css;
    shadow.appendChild(style);
    mountSearchBox(shadow, { api, key });
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', mount);
  } else {
    mount();
  }
})();
```

- [ ] **Step 5: Build and verify**

Run: `cd widget && npm install && npm run build`
Expected: esbuild reports the output file; verify:

```bash
ls -la ../backend/app/widget/polarbear-widget.js
node -e "const s=require('fs').statSync('../backend/app/widget/polarbear-widget.js').size; console.log(s); process.exit(s>200 && s<20000 ? 0 : 1)"
```

Expected: file exists, size between 200 bytes and 20KB.

- [ ] **Step 6: Commit (including the built artifact)**

```bash
git add widget/ backend/app/widget/polarbear-widget.js
git commit -m "feat(widget): scaffold — esbuild pipeline, bootstrap, inline search box"
```

(If `git status` shows the artifact as ignored (root `.gitignore` patterns), add with `git add -f backend/app/widget/polarbear-widget.js` and note it; the root `.gitignore` currently ignores `*.bin/*.pkl/*.db` only, so `.js` should be fine.)

---

### Task 4: Widget behavior — API client, overlay, keyboard nav, node tests

**Files:**
- Create: `widget/src/api.ts`, `widget/src/overlay.ts`, `widget/build-test.mjs`, `widget/test/api.test.mjs`
- Modify: `widget/src/search-box.ts` (wire focus → overlay)
- Regenerate + commit: `backend/app/widget/polarbear-widget.js`

**Interfaces:**
- Consumes: `WidgetConfig` (Task 3), `/search/?q=&key=&limit=` and `/analytics/track` (Tasks 1, existing).
- Produces: `createSearchClient(cfg, fetchFn?)` → `{ search(q, limit?): Promise<Product[] | null>, track(product): void }` (null = superseded by a newer request); `debounce(fn, ms)`; `openOverlay(shadow, cfg, initial)`.

- [ ] **Step 1: Write the API client**

`widget/src/api.ts`:

```typescript
import type { WidgetConfig } from './search-box';

export interface Product {
  id: string | number;
  title: string;
  description?: string;
  price?: number | string;
  image_url?: string;
  url?: string;
}

export function createSearchClient(cfg: WidgetConfig, fetchFn: typeof fetch = fetch.bind(globalThis)) {
  let seq = 0;
  return {
    /** Resolves with results; [] on failure; null if superseded by a newer call. */
    async search(q: string, limit = 8): Promise<Product[] | null> {
      const mySeq = ++seq;
      try {
        const res = await fetchFn(
          `${cfg.api}/search/?q=${encodeURIComponent(q)}&key=${encodeURIComponent(cfg.key)}&limit=${limit}`
        );
        if (mySeq !== seq) return null;
        if (!res.ok) {
          console.warn('[PolarBear] search failed:', res.status);
          return [];
        }
        const data = await res.json();
        if (mySeq !== seq) return null;
        return (data.results || []) as Product[];
      } catch (e) {
        if (mySeq !== seq) return null;
        console.warn('[PolarBear] search failed:', e);
        return [];
      }
    },

    /** Fire-and-forget click tracking; must never throw or block navigation. */
    track(product: Product): void {
      try {
        fetchFn(`${cfg.api}/analytics/track`, {
          method: 'POST',
          keepalive: true,
          headers: { 'Content-Type': 'application/json', 'X-PolarBear-Key': cfg.key },
          body: JSON.stringify({
            type: 'click',
            product_id: String(product.id),
            title: product.title,
          }),
        }).catch(() => {});
      } catch {
        /* never break the merchant page */
      }
    },
  };
}

export function debounce<A extends unknown[]>(fn: (...args: A) => void, ms: number) {
  let t: ReturnType<typeof setTimeout> | undefined;
  return (...args: A) => {
    clearTimeout(t);
    t = setTimeout(() => fn(...args), ms);
  };
}
```

- [ ] **Step 2: Write the node tests (failing until build-test exists)**

`widget/build-test.mjs`:

```javascript
import { build } from 'esbuild';

await build({
  entryPoints: ['src/api.ts'],
  bundle: true,
  format: 'esm',
  outfile: 'test/.api.build.mjs',
});
```

`widget/test/api.test.mjs`:

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createSearchClient, debounce } from './.api.build.mjs';

test('out-of-order responses are discarded', async () => {
  const resolvers = [];
  const fakeFetch = () => new Promise((resolve) => resolvers.push(resolve));
  const client = createSearchClient({ api: 'http://x', key: 'k' }, fakeFetch);

  const first = client.search('a');
  const second = client.search('ab');

  resolvers[0]({ ok: true, json: async () => ({ results: [{ id: '1', title: 'stale' }] }) });
  resolvers[1]({ ok: true, json: async () => ({ results: [{ id: '2', title: 'fresh' }] }) });

  assert.equal(await first, null); // superseded
  assert.equal((await second)[0].id, '2');
});

test('failed search returns empty list, never throws', async () => {
  const client = createSearchClient(
    { api: 'http://x', key: 'k' },
    () => Promise.reject(new Error('down'))
  );
  assert.deepEqual(await client.search('ab'), []);
});

test('non-ok response returns empty list', async () => {
  const client = createSearchClient(
    { api: 'http://x', key: 'k' },
    async () => ({ ok: false, status: 401, json: async () => ({}) })
  );
  assert.deepEqual(await client.search('ab'), []);
});

test('debounce fires once with the last args', async () => {
  const calls = [];
  const d = debounce((v) => calls.push(v), 10);
  d('a'); d('ab'); d('abc');
  await new Promise((r) => setTimeout(r, 40));
  assert.deepEqual(calls, ['abc']);
});

test('track never throws even when fetch is broken', () => {
  const client = createSearchClient(
    { api: 'http://x', key: 'k' },
    () => { throw new Error('boom'); }
  );
  client.track({ id: 1, title: 'X' }); // must not throw
});
```

- [ ] **Step 3: Run widget tests to verify they pass**

Run: `cd widget && npm test`
Expected: 5 tests pass.

- [ ] **Step 4: Write the overlay**

`widget/src/overlay.ts`:

```typescript
import { createSearchClient, debounce, Product } from './api';
import type { WidgetConfig } from './search-box';

export function openOverlay(shadow: ShadowRoot, cfg: WidgetConfig, initial: string): void {
  if (shadow.querySelector('.pb-backdrop')) return;
  const client = createSearchClient(cfg);

  const backdrop = document.createElement('div');
  backdrop.className = 'pb-backdrop';
  const panel = document.createElement('div');
  panel.className = 'pb-panel';
  const input = document.createElement('input');
  input.className = 'pb-panel-input';
  input.placeholder = 'Search products…';
  input.value = initial;
  const results = document.createElement('div');
  results.className = 'pb-results';
  const footer = document.createElement('div');
  footer.className = 'pb-footer';
  const footerLink = document.createElement('a');
  footerLink.href = 'https://github.com/dukesky/PolarBear';
  footerLink.target = '_blank';
  footerLink.rel = 'noopener';
  footerLink.textContent = 'PolarBear 🐻‍❄️';
  footer.append('Search by ', footerLink);
  panel.append(input, results, footer);
  backdrop.appendChild(panel);
  shadow.appendChild(backdrop);
  input.focus();

  let items: Product[] = [];
  let selected = -1;

  const render = (q: string) => {
    results.textContent = '';
    if (!items.length) {
      if (q.trim().length >= 2) {
        const empty = document.createElement('div');
        empty.className = 'pb-empty';
        empty.textContent = `No results for “${q}”`;
        results.appendChild(empty);
      }
      return;
    }
    items.forEach((p, i) => {
      const card = document.createElement(p.url ? 'a' : 'div');
      card.className = 'pb-card' + (i === selected ? ' pb-selected' : '');
      if (p.url && card instanceof HTMLAnchorElement) {
        card.href = p.url;
        card.target = '_top';
      }
      if (p.image_url) {
        const img = document.createElement('img');
        img.className = 'pb-thumb';
        img.src = p.image_url;
        img.alt = '';
        card.appendChild(img);
      } else {
        const ph = document.createElement('div');
        ph.className = 'pb-thumb';
        card.appendChild(ph);
      }
      const text = document.createElement('div');
      text.className = 'pb-text';
      const title = document.createElement('div');
      title.className = 'pb-title';
      title.textContent = p.title;
      text.appendChild(title);
      if (p.description) {
        const desc = document.createElement('div');
        desc.className = 'pb-desc';
        desc.textContent = p.description.slice(0, 80);
        text.appendChild(desc);
      }
      card.appendChild(text);
      if (p.price !== undefined && p.price !== null && p.price !== '') {
        const price = document.createElement('div');
        price.className = 'pb-price';
        price.textContent = `$${p.price}`;
        card.appendChild(price);
      }
      card.addEventListener('click', () => client.track(p));
      results.appendChild(card);
    });
  };

  const run = debounce(async (q: string) => {
    if (q.trim().length < 2) {
      items = [];
      selected = -1;
      render(q);
      return;
    }
    const out = await client.search(q);
    if (out === null) return; // superseded by a newer request
    items = out;
    selected = -1;
    render(q);
  }, 250);

  input.addEventListener('input', () => run(input.value));

  const close = () => backdrop.remove();
  backdrop.addEventListener('click', (e) => {
    if (e.target === backdrop) close();
  });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      close();
    } else if (e.key === 'ArrowDown') {
      selected = Math.min(selected + 1, items.length - 1);
      render(input.value);
      e.preventDefault();
    } else if (e.key === 'ArrowUp') {
      selected = Math.max(selected - 1, 0);
      render(input.value);
      e.preventDefault();
    } else if (e.key === 'Enter' && selected >= 0) {
      const p = items[selected];
      if (p) {
        client.track(p);
        if (p.url) window.top?.location.assign(p.url);
      }
    }
  });

  if (initial.trim().length >= 2) run(initial);
}
```

- [ ] **Step 5: Wire the search box to the overlay**

Replace `widget/src/search-box.ts`:

```typescript
import { openOverlay } from './overlay';

export interface WidgetConfig {
  api: string;
  key: string;
}

export function mountSearchBox(shadow: ShadowRoot, cfg: WidgetConfig): void {
  const input = document.createElement('input');
  input.className = 'pb-input';
  input.type = 'search';
  input.placeholder = 'Search products…';
  input.addEventListener('focus', () => {
    openOverlay(shadow, cfg, input.value);
    input.blur();
  });
  shadow.appendChild(input);
}
```

- [ ] **Step 6: Rebuild, size check, run all widget tests**

Run: `cd widget && npm run build && npm test`
Expected: build succeeds; check size ≤ 15KB:

```bash
node -e "const s=require('fs').statSync('../backend/app/widget/polarbear-widget.js').size; console.log(s+' bytes'); process.exit(s<=15000?0:1)"
```

- [ ] **Step 7: Commit (including regenerated artifact)**

```bash
git add widget/ backend/app/widget/polarbear-widget.js
git commit -m "feat(widget): search-as-you-type overlay with keyboard nav and click tracking"
```

---

### Task 5: Backend serves `GET /widget.js`

**Files:**
- Modify: `backend/app/main.py`
- Test: `backend/tests/test_widget_route.py`

**Interfaces:**
- Consumes: the committed artifact `backend/app/widget/polarbear-widget.js` (Tasks 3–4).
- Produces: `GET /widget.js` → 200, `application/javascript`, `Cache-Control: public, max-age=3600`.

- [ ] **Step 1: Write the failing test**

`backend/tests/test_widget_route.py`:

```python
async def test_widget_js_served_with_cache_headers(client):
    r = await client.get("/widget.js")
    assert r.status_code == 200
    assert "javascript" in r.headers["content-type"]
    assert r.headers["cache-control"] == "public, max-age=3600"
    assert len(r.content) > 200  # real artifact, not a stub
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_widget_route.py -v`
Expected: FAIL — 404 (route not defined).

- [ ] **Step 3: Implement the route**

In `backend/app/main.py` add (near the `/health` route; `HTTPException` needs importing from fastapi):

```python
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse

WIDGET_FILE = os.path.join(os.path.dirname(__file__), "widget", "polarbear-widget.js")


@app.get("/widget.js", include_in_schema=False)
def widget_js():
    if not os.path.exists(WIDGET_FILE):
        raise HTTPException(status_code=404, detail="Widget artifact missing")
    return FileResponse(
        WIDGET_FILE,
        media_type="application/javascript",
        headers={"Cache-Control": "public, max-age=3600"},
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_widget_route.py -v` then `poetry run pytest`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/main.py backend/tests/test_widget_route.py
git commit -m "feat: serve the embeddable widget at /widget.js with cache headers"
```

---

### Task 6: Hostile merchant test page + end-to-end browser verification

**Files:**
- Create: `widget/test/merchant-page.html`, `widget/test/sample_products_urls.csv`

**Interfaces:**
- Consumes: running backend (`/widget.js`, `/search/`, `/analytics/track`), a registered tenant's search key (passed via `?key=` URL param).

- [ ] **Step 1: Write the hostile merchant page**

`widget/test/merchant-page.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Ye Olde Candle Shoppe — fake merchant page</title>
  <style>
    /* Deliberately hostile global CSS to prove Shadow DOM isolation */
    * { box-sizing: content-box !important; font-family: "Comic Sans MS", cursive !important; }
    div { border: 3px dashed red; background: #fffbe6; padding: 4px; }
    input { background: hotpink !important; border: 5px double lime !important; font-size: 30px !important; }
    a { color: red; text-decoration: wavy underline; }
    body { margin: 0; background: repeating-linear-gradient(45deg, #fdf6e3, #fdf6e3 20px, #f5e6c8 20px, #f5e6c8 40px); }
    header { background: #7b3f00; color: #fff; padding: 24px; text-align: center; border: none; }
  </style>
</head>
<body>
  <header><h1>🕯️ Ye Olde Candle Shoppe</h1><p>Finest fake products since 2026</p></header>

  <main style="max-width: 720px; margin: 24px auto;">
    <p>This is a deliberately ugly third-party page. The PolarBear search box below
       must look clean despite the hostile CSS above, and the page's own inputs
       (like this one: <input placeholder="merchant's own ugly input">) must stay ugly.</p>

    <div id="polarbear-search"></div>

    <p>Lorem ipsum merchant content continues below the search box…</p>
  </main>

  <script>
    // Key and API base come from the URL so this file needs no editing:
    //   merchant-page.html?key=pb_search_...&api=http://localhost:8000
    const params = new URLSearchParams(location.search);
    const s = document.createElement('script');
    const api = params.get('api') || 'http://localhost:8000';
    s.src = api + '/widget.js';
    s.dataset.key = params.get('key') || '';
    if (params.get('api')) s.dataset.api = params.get('api');
    s.async = true;
    document.body.appendChild(s);
  </script>
</body>
</html>
```

- [ ] **Step 2: Write the sample CSV with url column**

`widget/test/sample_products_urls.csv`:

```csv
id,title,description,price,category,brand,tags,url
w1,Beeswax Pillar Candle,Slow-burning natural beeswax pillar with honey scent,18,Candles,Shoppe,"natural,beeswax",https://example.com/products/beeswax-pillar
w2,Lavender Soy Candle,Calming lavender soy wax candle for relaxing evenings,14,Candles,Shoppe,"soy,lavender,relax",https://example.com/products/lavender-soy
w3,Citronella Outdoor Candle,Keeps mosquitoes away on warm summer nights,11,Outdoor,Shoppe,"outdoor,summer",https://example.com/products/citronella
w4,Wooden Wick Candle,Crackling wooden wick in a glass jar,22,Candles,Shoppe,"wood,cozy",https://example.com/products/wooden-wick
```

- [ ] **Step 3: End-to-end verification (requires Meilisearch + backend running)**

```bash
cd infrastructure && docker compose up -d meilisearch && cd ..
cd backend && poetry run uvicorn app.main:app --port 8000 &
```

Then:

```bash
# register a widget-test tenant and capture token + search key
curl -s -X POST http://localhost:8000/auth/register -H "Content-Type: application/json" -d '{"email":"widget-e2e@test.dev","password":"widgettest1"}'
TOKEN=$(curl -s -X POST http://localhost:8000/auth/jwt/login -H "Content-Type: application/x-www-form-urlencoded" -d "username=widget-e2e@test.dev&password=widgettest1" | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
curl -s -X POST http://localhost:8000/ingest/upload -H "Authorization: Bearer $TOKEN" -F "file=@widget/test/sample_products_urls.csv"
KEY=$(curl -s http://localhost:8000/tenant/keys -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json;print(json.load(sys.stdin)['search']['key'])")
open "file://$PWD/widget/test/merchant-page.html?key=$KEY"
```

Browser checklist (perform in the opened page):
- The PolarBear input looks clean (white, gray border) amid the hostile CSS; the merchant's own input stays hotpink.
- Focus the input → overlay opens; type `relaxing` → Lavender Soy Candle appears within ~1s (semantic match).
- ↑/↓ move the highlight; Esc closes; backdrop click closes.
- Click a result → new tab/navigation to example.com AND
  `curl -s http://localhost:8000/analytics/stats -H "Authorization: Bearer $TOKEN"` shows the click.
- Browser console: no errors (warnings allowed only if provoked, e.g. missing container).

- [ ] **Step 4: Commit**

```bash
git add widget/test/merchant-page.html widget/test/sample_products_urls.csv
git commit -m "test(widget): hostile merchant page and url-column sample for e2e verification"
```

---

### Task 7: Settings "Add to your website" + Upload url column + README

**Files:**
- Modify: `frontend/src/app/settings/page.tsx` (append a new section component)
- Modify: `frontend/src/app/upload/page.tsx` (CSV instructions list)
- Modify: `README.md` (feature bullet + quick-start step)

**Interfaces:**
- Consumes: `GET /tenant/snippet` → `{snippet}` (Task 2), `authFetch` from `frontend/src/lib/api.ts`.

- [ ] **Step 1: Add the EmbedSection to the Settings page**

In `frontend/src/app/settings/page.tsx`, render `<EmbedSection />` inside the existing card container, after the Admin Key block, and add at the bottom of the file:

```tsx
const PLATFORMS = [
  {
    id: 'shopify',
    label: 'Shopify',
    steps: [
      'In your Shopify admin, go to Online Store → Themes → Customize.',
      'On the page where you want search, click Add section → Custom Liquid.',
      'Paste the code below into the Custom Liquid box and click Save.',
    ],
  },
  {
    id: 'wordpress',
    label: 'WordPress',
    steps: [
      'In WP Admin, go to Appearance → Widgets, or edit the page in the block editor.',
      'Add a "Custom HTML" block where you want the search box.',
      'Paste the code below into the block and click Update.',
    ],
  },
  {
    id: 'wix',
    label: 'Wix',
    steps: [
      'In your Wix dashboard, go to Settings → Custom Code.',
      'Click "+ Add Custom Code" and paste the code below.',
      'Choose the pages it loads on, place it in Body, and click Apply.',
    ],
  },
  {
    id: 'other',
    label: 'Other website',
    steps: [
      'Open the HTML of the page where you want the search box.',
      'Paste the code below where the box should appear.',
      'Save and reload your site.',
    ],
  },
];

function EmbedSection() {
  const [snippet, setSnippet] = useState('');
  const [platform, setPlatform] = useState('shopify');
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    authFetch('/tenant/snippet')
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => d && setSnippet(d.snippet))
      .catch(() => {});
  }, []);

  const copy = async () => {
    await navigator.clipboard.writeText(snippet);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };

  const active = PLATFORMS.find((p) => p.id === platform) ?? PLATFORMS[0];

  return (
    <div className="mt-6 p-4 border border-gray-200 rounded-lg">
      <h2 className="text-sm font-semibold text-gray-900 mb-1">Add search to your website</h2>
      <p className="text-xs text-gray-500 mb-3">
        Three steps: 1) upload your products, 2) copy the code, 3) paste it into your site.
        No coding needed — every platform below has a paste box in its settings.
      </p>

      <div className="flex gap-2 mb-3">
        {PLATFORMS.map((p) => (
          <button
            key={p.id}
            onClick={() => setPlatform(p.id)}
            className={`px-3 py-1.5 text-xs font-medium rounded-full border ${
              platform === p.id
                ? 'bg-indigo-50 border-indigo-300 text-indigo-700'
                : 'bg-white border-gray-300 text-gray-600 hover:bg-gray-50'
            }`}
          >
            {p.label}
          </button>
        ))}
      </div>

      <ol className="list-decimal list-inside space-y-1 text-xs text-gray-700 mb-3">
        {active.steps.map((s, i) => (
          <li key={i}>{s}</li>
        ))}
      </ol>

      <div className="flex items-start gap-2">
        <pre className="flex-1 text-xs bg-gray-50 border border-gray-200 rounded px-3 py-2 overflow-x-auto whitespace-pre">
          {snippet || 'Loading your embed code…'}
        </pre>
        {snippet && (
          <button
            onClick={copy}
            className="text-xs font-medium px-3 py-2 rounded bg-indigo-50 text-indigo-700 hover:bg-indigo-100"
          >
            {copied ? 'Copied!' : 'Copy'}
          </button>
        )}
      </div>
    </div>
  );
}
```

(`useState`/`useEffect`/`authFetch` are already imported at the top of the file.)

- [ ] **Step 2: Update the Upload page CSV instructions**

In `frontend/src/app/upload/page.tsx`, in the "Required CSV Columns" list, change the intro text to "CSV Columns:" and extend the list items:

```tsx
<li><code>id</code> (Required — unique ID)</li>
<li><code>title</code> (Required — product name)</li>
<li><code>description</code>, <code>price</code>, <code>category</code>, <code>brand</code>, <code>tags</code> (Recommended)</li>
<li><code>image_url</code> (Optional — product image shown in results)</li>
<li><code>url</code> (Optional — link to the product page; makes results clickable in the embedded widget)</li>
```

- [ ] **Step 3: Update the README**

In `README.md`:
1. Features list, add: `- **🧩 Embeddable Widget**: paste two lines into any website (Shopify, WordPress, Wix, custom) and get an AI search box for your catalog.`
2. In the Quick Start "Experience PolarBear" step, add after the API Keys line: `- **Embed**: In Settings → "Add search to your website", copy the snippet into any web page — the widget talks to your backend.`

- [ ] **Step 4: Verify build**

Run: `cd frontend && npm run build`
Expected: clean build.

- [ ] **Step 5: Manual check**

With backend + frontend running, signed in: Settings shows the embed section; switching platform tabs swaps the 3-step guide; the snippet contains the real key; Copy works.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/app/settings/page.tsx frontend/src/app/upload/page.tsx README.md
git commit -m "feat(frontend): platform-aware embed onboarding in Settings, url column docs"
```

---

## Final Verification (whole plan)

- [ ] `cd backend && poetry run pytest` — all green (including new track-auth, snippet, widget-route tests)
- [ ] `cd widget && npm run build && npm test` — build + 5 node tests green; artifact ≤ 15KB and committed
- [ ] `cd widget && npm run check` — committed artifact matches a fresh rebuild (freshness guard from the spec)
- [ ] `cd frontend && npm run build` — clean
- [ ] Task 6's browser checklist passes on the hostile merchant page (style isolation both ways, search-as-you-type, click tracking lands in Insights)
- [ ] Acceptance run: fresh account → upload `widget/test/sample_products_urls.csv` → copy snippet from Settings → paste key into merchant-page URL → working search, ≤ 10 minutes, zero code
