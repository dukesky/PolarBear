# App / API Integration Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop telling app-only merchants their working integration is broken — report the web widget and direct API channels separately — and document how to search from an iOS or Android app.

**Architecture:** The backend already records every signal needed (`load` pings carry a browser origin; non-browser clients are recorded with origin `"unknown"`). `GET /tenant/install-status` stops collapsing that into one website-shaped verdict and instead returns a `web` and an `api` channel object plus an extended verdict with a new `api_only` value. Settings renders one line per channel; docs gain a mobile-app section.

**Tech Stack:** FastAPI, SQLAlchemy 2 async, Next.js 16 + Tailwind 4, pytest.

**Spec:** `docs/superpowers/specs/2026-08-17-app-api-integration-design.md`

## Global Constraints

- Backend tests: `cd backend && poetry run pytest` (asyncio_mode=auto; existing `client` / `registered` conftest fixtures). Frontend: `cd frontend && npm run build`.
- `web.status` is exactly `"ok" | "wrong_domain" | "none"`; `api.status` is exactly `"active" | "none"`; `verdict` is exactly `"ok" | "api_only" | "wrong_domain" | "not_found" | "no_website"`.
- Verdict precedence, in this order: (1) a `load` ping matching `website_url` → `ok`; (2) an `unknown`-origin `search` ping exists → `api_only`; (3) `load` pings exist → `wrong_domain`; (4) `website_url` unset → `no_website`; (5) → `not_found`.
- The `"unknown"` origin must never satisfy an `ok` match (guard already present — keep it).
- `pings` and `website_url` keep their existing shape and semantics; adding fields only.
- A channel with nothing to report renders gray "Not detected", never a red error. The red troubleshooting checklist appears only when BOTH channels are empty.
- Frontend: Tailwind utilities only, no new npm packages, existing white / gray-border / `indigo-600` card style.
- YAGNI (out of scope): native SDKs, app-side identity headers, per-channel Insights reporting, Shopify App.

---

### Task 1: Channel-aware install status

**Files:**
- Modify: `backend/app/api/routes/tenant.py` (the `install_status` route)
- Test: `backend/tests/test_install_channels.py`

**Interfaces:**
- Consumes: `WidgetPing` (`tenant_id, origin, kind, first_seen, last_seen, count`; `kind` is `"load"` or `"search"`), `UNKNOWN` from `app.services.origins`, `get_current_tenant`, `get_async_session` — all already imported in this route file.
- Produces: `GET /tenant/install-status` → `{website_url, web: {status, origin, last_seen}, api: {status, search_count, last_seen}, verdict, pings}`.

- [ ] **Step 1: Write the failing test**

`backend/tests/test_install_channels.py`:

```python
async def _search_key(client, token):
    r = await client.get("/tenant/keys", headers={"Authorization": f"Bearer {token}"})
    return r.json()["search"]["key"]


async def _status(client, token):
    r = await client.get(
        "/tenant/install-status", headers={"Authorization": f"Bearer {token}"}
    )
    assert r.status_code == 200, r.text
    return r.json()


async def test_app_only_merchant_is_api_only_not_not_found(registered):
    """The bug this task fixes: an app-only merchant was told to paste a snippet."""
    client, token, _ = registered
    key = await _search_key(client, token)

    # A native app sends no Origin — recorded as the "unknown" origin.
    await client.post("/analytics/install-ping", headers={"X-PolarBear-Key": key})

    body = await _status(client, token)
    assert body["verdict"] == "api_only"
    assert body["api"]["status"] == "active"
    assert body["web"]["status"] == "none"
    assert body["web"]["origin"] is None


async def test_api_only_outranks_no_website(registered, monkeypatch):
    """No website configured must not hide a working app integration."""
    client, token, _ = registered
    key = await _search_key(client, token)

    from app.api.routes import search as search_route

    class StubSearcher:
        def __init__(self, tenant_id, storage=None, meili_client=None):
            pass

        def search(self, q, limit=20):
            return []

    monkeypatch.setattr(search_route, "HybridSearcher", StubSearcher)
    await client.get("/search/", params={"q": "mug", "key": key})

    body = await _status(client, token)
    assert body["website_url"] is None
    assert body["verdict"] == "api_only"
    assert body["api"]["search_count"] >= 1


async def test_both_channels_reported_together(registered, monkeypatch):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    key = await _search_key(client, token)
    await client.put("/tenant/website", json={"website_url": "mystore.com"}, headers=auth)

    from app.api.routes import search as search_route

    class StubSearcher:
        def __init__(self, tenant_id, storage=None, meili_client=None):
            pass

        def search(self, q, limit=20):
            return []

    monkeypatch.setattr(search_route, "HybridSearcher", StubSearcher)

    # Browser install
    await client.post(
        "/analytics/install-ping",
        headers={"X-PolarBear-Key": key, "Origin": "https://mystore.com"},
    )
    # App search (no Origin)
    await client.get("/search/", params={"q": "mug", "key": key})

    body = await _status(client, token)
    assert body["verdict"] == "ok"
    assert body["web"]["status"] == "ok"
    assert body["web"]["origin"] == "mystore.com"
    assert body["api"]["status"] == "active"


async def test_browser_search_is_never_reported_as_app_traffic(registered, monkeypatch):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    key = await _search_key(client, token)
    await client.put("/tenant/website", json={"website_url": "mystore.com"}, headers=auth)

    from app.api.routes import search as search_route

    class StubSearcher:
        def __init__(self, tenant_id, storage=None, meili_client=None):
            pass

        def search(self, q, limit=20):
            return []

    monkeypatch.setattr(search_route, "HybridSearcher", StubSearcher)

    await client.post(
        "/analytics/install-ping",
        headers={"X-PolarBear-Key": key, "Origin": "https://mystore.com"},
    )
    await client.get(
        "/search/", params={"q": "mug", "key": key}, headers={"Origin": "https://mystore.com"}
    )

    body = await _status(client, token)
    assert body["verdict"] == "ok"
    assert body["api"]["status"] == "none"
    assert body["api"]["search_count"] == 0


async def test_wrong_domain_still_reported(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}
    key = await _search_key(client, token)
    await client.put("/tenant/website", json={"website_url": "mystore.com"}, headers=auth)

    await client.post(
        "/analytics/install-ping",
        headers={"X-PolarBear-Key": key, "Origin": "https://staging.othersite.com"},
    )

    body = await _status(client, token)
    assert body["verdict"] == "wrong_domain"
    assert body["web"]["status"] == "wrong_domain"
    assert body["web"]["origin"] == "staging.othersite.com"
    assert body["api"]["status"] == "none"


async def test_nothing_at_all_is_no_website_then_not_found(registered):
    client, token, _ = registered
    auth = {"Authorization": f"Bearer {token}"}

    body = await _status(client, token)
    assert body["verdict"] == "no_website"
    assert body["web"]["status"] == "none"
    assert body["api"]["status"] == "none"

    await client.put("/tenant/website", json={"website_url": "mystore.com"}, headers=auth)
    assert (await _status(client, token))["verdict"] == "not_found"


async def test_search_count_accumulates(registered, monkeypatch):
    client, token, _ = registered
    key = await _search_key(client, token)

    from app.api.routes import search as search_route

    class StubSearcher:
        def __init__(self, tenant_id, storage=None, meili_client=None):
            pass

        def search(self, q, limit=20):
            return []

    monkeypatch.setattr(search_route, "HybridSearcher", StubSearcher)
    await client.get("/search/", params={"q": "a", "key": key})
    await client.get("/search/", params={"q": "b", "key": key})

    body = await _status(client, token)
    assert body["api"]["search_count"] == 2
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && poetry run pytest tests/test_install_channels.py -v`
Expected: FAIL — the response has no `web`/`api` keys and the app-only case returns `no_website`.

- [ ] **Step 3: Rewrite the route's body**

In `backend/app/api/routes/tenant.py`, replace everything in `install_status` after the `rows = (...)` query — that is, the `pings = [...]` list build, the verdict `if/elif` chain, and the `return` — with:

```python
    def _iso(value):
        return value.isoformat() if value else None

    pings = [
        {
            "origin": p.origin,
            "kind": p.kind,
            "count": p.count,
            "last_seen": _iso(p.last_seen),
        }
        for p in rows
    ]

    # A browser always sends an Origin; a native app or a server-side caller
    # does not, and is recorded under the UNKNOWN sentinel. That difference is
    # what lets us report the two integration channels apart.
    loads = [p for p in rows if p.kind == "load" and p.origin != UNKNOWN]
    # (tenant_id, origin, kind) is unique, so at most one row can match.
    match = next(
        (p for p in loads if tenant.website_url and p.origin == tenant.website_url), None
    )
    api_ping = next((p for p in rows if p.kind == "search" and p.origin == UNKNOWN), None)

    if match:
        web = {"status": "ok", "origin": match.origin, "last_seen": _iso(match.last_seen)}
    elif loads:
        latest = max(loads, key=lambda p: p.last_seen or p.first_seen)
        web = {
            "status": "wrong_domain",
            "origin": latest.origin,
            "last_seen": _iso(latest.last_seen),
        }
    else:
        web = {"status": "none", "origin": None, "last_seen": None}

    if api_ping:
        api = {
            "status": "active",
            "search_count": api_ping.count,
            "last_seen": _iso(api_ping.last_seen),
        }
    else:
        api = {"status": "none", "search_count": 0, "last_seen": None}

    # api_only deliberately outranks no_website: an app-only merchant must not
    # be nagged for a website they do not have.
    if web["status"] == "ok":
        verdict = "ok"
    elif api["status"] == "active":
        verdict = "api_only"
    elif loads:
        verdict = "wrong_domain"
    elif not tenant.website_url:
        verdict = "no_website"
    else:
        verdict = "not_found"

    return {
        "website_url": tenant.website_url,
        "web": web,
        "api": api,
        "verdict": verdict,
        "pings": pings,
    }
```

Also update the route's docstring to `"""Which integration channels are actually live: the web widget, a direct API/app integration, or neither."""`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && poetry run pytest tests/test_install_channels.py tests/test_install_status.py -v`
Expected: all PASS — the new channel tests and the existing install-status tests (which assert `verdict` and `pings`, both preserved).

- [ ] **Step 5: Run the full suite**

Run: `cd backend && poetry run pytest`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add backend/app/api/routes/tenant.py backend/tests/test_install_channels.py
git commit -m "feat: report web and app/API integration channels separately"
```

---

### Task 2: Settings shows one line per channel

**Files:**
- Modify: `frontend/src/app/settings/page.tsx` (the `StatusResponse` interface and the `InstallCheck` component)

**Interfaces:**
- Consumes: `GET /tenant/install-status` with the `web` / `api` objects and the extended verdict (Task 1).

- [ ] **Step 1: Extend the response type**

In `frontend/src/app/settings/page.tsx`, replace the `StatusResponse` interface with:

```tsx
interface StatusResponse {
  website_url: string | null;
  pings: { origin: string; kind: string; count: number; last_seen: string | null }[];
  web: { status: 'ok' | 'wrong_domain' | 'none'; origin: string | null; last_seen: string | null };
  api: { status: 'active' | 'none'; search_count: number; last_seen: string | null };
  verdict: 'ok' | 'api_only' | 'wrong_domain' | 'not_found' | 'no_website';
}
```

- [ ] **Step 2: Replace the result panels with per-channel lines**

In the same file, inside `InstallCheck`:

1. Delete the two consts `const loadPing = ...` and `const searchPing = ...` — the new markup reads `status.web` / `status.api` instead.
2. Replace everything from the website `</form>` closing tag through the end of the component (the "Check my installation" `<button>` and all four `{status?.verdict === '...' && (...)}` panels) with the block below. It reproduces the form's closing tag and the button so you can match the region exactly.

```tsx
      </form>
      <p className="-mt-1 mb-3 text-xs text-gray-500">
        Only using an app or the API? Leave this empty.
      </p>

      <button
        onClick={check}
        disabled={checking}
        className={`text-sm font-medium px-4 py-2 rounded-md text-white ${
          checking ? 'bg-gray-400' : 'bg-indigo-600 hover:bg-indigo-700'
        }`}
      >
        {checking ? 'Checking…' : 'Check my installation'}
      </button>

      {status && (
        <div className="mt-4 space-y-3">
          <div>
            <div className="text-xs font-semibold text-gray-700 mb-1">Website</div>
            {status.web.status === 'ok' && (
              <div className="p-3 rounded bg-green-50 text-green-800 text-sm">
                Search box loaded on <strong>{status.web.origin}</strong>.
              </div>
            )}
            {status.web.status === 'wrong_domain' && (
              <div className="p-3 rounded bg-amber-50 text-amber-800 text-sm">
                Found the search box on <strong>{status.web.origin}</strong>, but not on{' '}
                <strong>{saved ?? 'your website'}</strong>. If that&apos;s a staging site
                you&apos;re fine — otherwise update the address above.
              </div>
            )}
            {status.web.status === 'none' && (
              <div className="p-3 rounded bg-gray-50 text-gray-500 text-sm">Not detected</div>
            )}
          </div>

          <div>
            <div className="text-xs font-semibold text-gray-700 mb-1">App / API</div>
            {status.api.status === 'active' ? (
              <div className="p-3 rounded bg-green-50 text-green-800 text-sm">
                Received <strong>{status.api.search_count}</strong> searches from an app or
                server.
              </div>
            ) : (
              <div className="p-3 rounded bg-gray-50 text-gray-500 text-sm">Not detected</div>
            )}
          </div>

          {status.web.status === 'none' && status.api.status === 'none' && (
            <div className="p-3 rounded bg-red-50 text-red-700 text-sm">
              <p className="font-medium mb-1">Nothing has reached us yet.</p>
              <ul className="list-disc list-inside space-y-0.5 text-xs">
                <li>Did you save and publish the page after pasting?</li>
                <li>Is the code on a live page rather than a draft?</li>
                <li>Did you paste both lines, including the one starting with &lt;div&gt;?</li>
                <li>Open your site once — the check only sees pages that have loaded.</li>
                <li>Integrating from an app? Run one search from it, then check again.</li>
              </ul>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 3: Verify build**

Run: `cd frontend && npm run build`
Expected: clean build, no TypeScript errors.

This project has no frontend test framework, so the build plus the two manual
acceptance gates in Final Verification are the check for this task — there is
no unit test to write here.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/app/settings/page.tsx
git commit -m "feat(frontend): report website and app/API integration channels separately"
```

---

### Task 3: Home status line understands `api_only`

**Files:**
- Modify: `frontend/src/components/InstallStatusLine.tsx`

**Interfaces:**
- Consumes: `GET /tenant/install-status` `verdict` including `api_only` (Task 1).

- [ ] **Step 1: Read the channel fields and treat `api_only` as live**

In `frontend/src/components/InstallStatusLine.tsx`, first change the origin lookup inside the `.then((d) => {...})` callback to use the new `web.origin` field instead of digging through `pings`:

```tsx
        setOrigin(d.web?.origin ?? null);
```

Then replace the `const live = verdict === 'ok';` line and the JSX that follows it with:

```tsx
  const live = verdict === 'ok' || verdict === 'api_only';
  const label =
    verdict === 'api_only' ? 'App / API integration' : origin;

  return (
    <p className="mt-6 text-sm text-gray-500">
      <span
        className={`inline-block w-2 h-2 rounded-full mr-2 align-middle ${
          live ? 'bg-green-500' : 'bg-gray-300'
        }`}
      />
      {live ? (
        <>Search live on <span className="font-medium text-gray-700">{label}</span></>
      ) : (
        <>
          Search not installed yet ·{' '}
          <a href="/settings" className="text-indigo-600 hover:underline">
            finish setup
          </a>
        </>
      )}
    </p>
  );
```

- [ ] **Step 2: Verify build**

Run: `cd frontend && npm run build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/components/InstallStatusLine.tsx
git commit -m "feat(frontend): home status line recognises app/API integrations"
```

---

### Task 4: Mobile app documentation

**Files:**
- Modify: `docs/INTEGRATION.md`, `README.md`

- [ ] **Step 1: Add the mobile app section to INTEGRATION.md**

In `docs/INTEGRATION.md`, immediately after the "For developers: use the API directly" section's click-tracking `curl` example and before the `---` that precedes "## Running PolarBear yourself", insert:

````markdown
## Use PolarBear in a mobile app

The embeddable widget is web-only — it renders into a web page. Native apps
call the same REST API directly, which takes a few dozen lines.

**iOS (Swift)**

```swift
struct Product: Decodable {
    let id: String
    let title: String
    let description: String?
    let price: Double?
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
    val price: Double? = null,
    val url: String? = null,
    val image_url: String? = null,
)

@Serializable
data class SearchResponse(val query: String, val total: Int, val results: List<Product>)

suspend fun search(query: String): List<Product> = withContext(Dispatchers.IO) {
    val url = "https://YOUR-SERVER/search/?q=${URLEncoder.encode(query, "UTF-8")}" +
        "&key=pb_search_...&limit=8"
    val conn = (URL(url).openConnection() as HttpURLConnection)
    try {
        if (conn.responseCode != 200) return@withContext emptyList()
        val body = conn.inputStream.bufferedReader().readText()
        Json { ignoreUnknownKeys = true }.decodeFromString<SearchResponse>(body).results
    } catch (e: Exception) {
        emptyList()   // never let search break the screen
    } finally {
        conn.disconnect()
    }
}
```

**Is it safe to ship the key inside an app?**

Yes, for the **public search key** (`pb_search_`). It is read-only and scoped
to your catalog — the same threat model as putting it in a web page's source,
which is exactly what the widget does. Someone who extracts it can search your
public products and nothing else.

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
````

- [ ] **Step 2: Add the README feature bullet**

In `README.md`, in the Features list, directly after the Embeddable Widget bullet, add:

```markdown
- **📱 Works in apps too**: the search API is a plain HTTP call — integrate iOS, Android, or any backend in a few dozen lines. See the [integration guide](docs/INTEGRATION.md#use-polarbear-in-a-mobile-app).
```

- [ ] **Step 3: Verify the docs render and links resolve**

Run: `grep -n "Use PolarBear in a mobile app" docs/INTEGRATION.md && grep -n "use-polarbear-in-a-mobile-app" README.md`
Expected: both print a match — the README anchor matches the new heading.

- [ ] **Step 4: Commit**

```bash
git add docs/INTEGRATION.md README.md
git commit -m "docs: how to search from an iOS or Android app"
```

---

## Final Verification (whole plan)

- [ ] `cd backend && poetry run pytest` — all green including the seven new channel tests
- [ ] `cd frontend && npm run build` — clean
- [ ] **Acceptance gate**: with the backend running, register a merchant, run one search with `curl` using their search key and no `Origin` header, then open Settings → Check my installation: the **App / API** line reads "Received 1 searches from an app or server" and the **Website** line reads "Not detected" in gray, with no red checklist
- [ ] **Acceptance gate**: a website-only merchant (widget load ping + browser-origin search) shows Website ✅ and App / API "Not detected"
- [ ] `git log --oneline` shows one commit per task
