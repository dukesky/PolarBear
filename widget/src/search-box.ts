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
