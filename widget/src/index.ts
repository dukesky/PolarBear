import { css } from './styles';
import { mountSearchBox } from './search-box';
import { sendInstallPing } from './api';

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
    if (container.shadowRoot) {
      console.warn('[PolarBear] widget already mounted');
      return;
    }
    const shadow = container.attachShadow({ mode: 'open' });
    const style = document.createElement('style');
    style.textContent = css;
    shadow.appendChild(style);
    mountSearchBox(shadow, { api, key });
    sendInstallPing({ api, key });
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', mount);
  } else {
    mount();
  }
})();
