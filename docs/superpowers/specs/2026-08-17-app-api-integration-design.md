# App / API Integration Support — Design Spec

**Date**: 2026-08-17
**Sub-project**: C1.6 — Honest install self-check for non-browser clients + mobile app docs
**Status**: Approved by user (brainstorming session 2026-08-17)
**Depends on**: Onboarding success pack (`a0e1031`, deployed 2026-08-17)

## Context & Motivation

A merchant asked whether PolarBear can power search inside a mobile app. It
already can — the search API is a plain HTTP GET and needs no changes. Verified
against production with a non-browser client (no `Origin`, no `Referer`, an iOS
user agent):

```
HTTP=200  time=0.74s
{"query":"cozy gift","total":3,"results":[...]}
```

Click tracking works from the same client (`/analytics/track` → 200).

But the installation self-check shipped yesterday assumes every merchant has a
website. It decides "is this working?" from the `Origin`/`Referer` header, and
native apps send neither, so their requests are recorded with origin
`"unknown"` and never produce a `load` ping. Verified in production for an
app-shaped client:

```
verdict: not_found
pings: [('unknown', 'search', 3)]
```

The merchant's integration is working perfectly and the dashboard tells them
"No sign of the search box yet — did you paste both lines?" That is actively
misleading, and it is a regression we introduced. This spec fixes it and
documents the app path.

## Goals

- A merchant whose only integration is an app or a server-side API call sees a
  positive confirmation, not a troubleshooting checklist.
- A merchant who uses both a website widget and an app sees both, separately.
- A merchant with only a website sees no change from today.
- An app developer can integrate from the docs alone, without reverse-
  engineering the widget.

## Non-Goals (YAGNI — explicitly deferred)

- Native SDKs (Swift/Kotlin/React Native packages). Most app developers call
  the REST API directly; an SDK is a nice-to-have, not a blocker.
- App-side identity reporting (a bundle id header). It would sharpen
  attribution but requires a protocol change and app-developer cooperation.
- Per-channel analytics reporting (splitting Insights by web vs app).
- Shopify App (C2 — next sub-project).

## 1. Install status reports channels, not one verdict

The backend already records everything needed; it just interprets it through a
website-shaped lens. The signals:

| Recorded ping | What it means |
|---|---|
| `load` with a real origin | The widget mounted in a browser |
| `search` with a real origin | A search happened in a browser |
| `search` with origin `"unknown"` | A **non-browser client** searched (app, server, script) |

`GET /tenant/install-status` gains two channel objects alongside the existing
fields:

```json
{
  "website_url": "mystore.com",
  "web":  {"status": "ok" | "wrong_domain" | "none", "origin": "mystore.com", "last_seen": "..."},
  "api":  {"status": "active" | "none", "search_count": 42, "last_seen": "..."},
  "verdict": "ok" | "api_only" | "wrong_domain" | "not_found" | "no_website",
  "pings": [...]
}
```

- `web.status` is `ok` when a `load` ping matches `website_url`,
  `wrong_domain` when `load` pings exist but none match (or `website_url` is
  unset), `none` when there are no `load` pings. `web.origin` is the matching
  load ping's origin when `ok`, otherwise the most recently seen load origin,
  otherwise `null`.
- `api.status` is `active` when at least one `search` ping has origin
  `"unknown"`, otherwise `none`. `search_count` is that ping's count (0 when
  none).
- `pings` and `website_url` keep their current shape — the Settings page and
  any existing consumer keep working.

**Verdict precedence** (the one behavioral change that fixes the bug):

1. a `load` ping matching `website_url` → `ok`
2. otherwise an `unknown`-origin search ping exists → **`api_only`**
3. otherwise `load` pings exist → `wrong_domain`
4. otherwise `website_url` is unset → `no_website`
5. otherwise → `not_found`

`api_only` sits above `no_website` deliberately: an app-only merchant must not
be nagged to enter a website they do not have. The `"unknown"` origin still
never satisfies `ok` (that guard, added in the previous sub-project, stays).

## 2. Settings shows two independent lines

```
Your website     [ mystore.com            ] [ Update ]
                 Only using an app or the API? Leave this empty.
                 ✅ Search box loaded on mystore.com (2 minutes ago), answered 5 searches

App / API
                 ✅ Received 42 searches from an app or server (last 3 minutes ago)
```

A channel with nothing to report shows a **gray "Not detected"**, not a red
error — for a merchant using one channel, the other one is legitimately
absent. The red troubleshooting checklist appears only when **both** channels
are empty (`not_found` / `no_website` with no activity at all).

The home-page status line follows the same rule: `api_only` renders
"Search live · App / API integration".

## 3. Documentation

**`docs/INTEGRATION.md`** gains a "Use PolarBear in a mobile app" section
after the existing "For developers: use the API directly":

- One-line framing: the embeddable widget is web-only; apps call the REST API
  directly, in a few dozen lines.
- Complete, runnable **Swift (iOS)** and **Kotlin (Android)** examples covering
  the request, decoding, and error handling.
- **Key safety**: the public search key is safe to ship inside an app binary —
  read-only and tenant-scoped, the same threat model as putting it in page
  source. The admin key must never go into an app.
- Practical notes: debounce ~250ms, use `limit`, click tracking via
  `/analytics/track` works from apps too, and the first request after an idle
  period can be slow (scale-to-zero cold start).
- How the self-check reports app integrations, and that leaving the website
  field empty is correct for app-only merchants.

**`README.md`**: one Features bullet noting the REST API can be called directly
from iOS/Android apps.

## 4. Error Handling & Testing

**Backend (pytest)** — extending `backend/tests/test_install_status.py`:

- App-only merchant (no `website_url`, one `unknown`-origin search ping) →
  `verdict == "api_only"`, `api.status == "active"`, `web.status == "none"`
- `api_only` outranks `no_website`: same as above but asserting the verdict is
  not `no_website`
- Both channels: a matching `load` ping plus an `unknown` search ping →
  `verdict == "ok"`, `web.status == "ok"`, `api.status == "active"`
- Web-only merchant (matching `load` ping, browser-origin search ping only) →
  `api.status == "none"` — a browser search must never be misreported as an
  app integration
- `wrong_domain` behavior unchanged when only mismatched `load` pings exist
- `search_count` reflects the `unknown` ping's count after repeated searches

**Frontend**: the three combinations (web only / app only / both) render their
respective lines; the red checklist appears only when both are empty; build
passes.

**Manual**: against the deployed backend, run a search with `curl` (no Origin)
using a tenant's search key, then confirm Settings shows the App / API line as
active.

## Acceptance Criteria

1. A merchant whose only traffic comes from a non-browser client sees a
   positive "App / API" confirmation and is never shown the paste-the-snippet
   checklist.
2. A website-only merchant's experience is unchanged, and their browser
   searches are never labelled as app traffic.
3. An app developer can build a working integration from `docs/INTEGRATION.md`
   alone.
