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

/** Returns the url only when it parses to http(s); undefined otherwise. */
export function safeUrl(u: string | undefined): string | undefined {
  if (!u) return undefined;
  try {
    const base = typeof window !== 'undefined' ? window.location.href : 'http://localhost/';
    const parsed = new URL(u, base);
    if (parsed.protocol === 'http:' || parsed.protocol === 'https:') return u;
  } catch { /* unparseable */ }
  return undefined;
}

export function debounce<A extends unknown[]>(fn: (...args: A) => void, ms: number) {
  let t: ReturnType<typeof setTimeout> | undefined;
  return (...args: A) => {
    clearTimeout(t);
    t = setTimeout(() => fn(...args), ms);
  };
}

/** Tell the backend the widget mounted, so the merchant can verify the install
 *  before any shopper has searched. Fire-and-forget: never throws. */
export function sendInstallPing(
  cfg: WidgetConfig,
  fetchFn: typeof fetch = fetch.bind(globalThis)
): void {
  try {
    const p = fetchFn(`${cfg.api}/analytics/install-ping`, {
      method: 'POST',
      keepalive: true,
      headers: { 'X-PolarBear-Key': cfg.key },
    });
    if (p && typeof (p as Promise<unknown>).catch === 'function') {
      (p as Promise<unknown>).catch(() => {});
    }
  } catch {
    /* never break the merchant page */
  }
}
