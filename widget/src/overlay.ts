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
        empty.textContent = `No results for "${q}"`;
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
